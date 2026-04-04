import 'dart:math';

import 'package:h3_flutter/h3_flutter.dart' as h3lib;

import 'seattle_trails.dart';
import 'valid_trail_hexes.dart';

/// Exposes the active launch corridor (Burke-Gilman) hex data.
///
/// HexTrail launches on a single trail first.  This helper lets the map
/// screen and render service answer "is this hex on the active trail?" and
/// "where is the nearest entry point?" without re-deriving the hex list.
class LaunchCorridor {
  LaunchCorridor._();

  static const String activeTrailId = 'burke_gilman';
  static const String activeTrailName = 'Burke-Gilman';

  static late final Set<String> _hexes;
  static late final List<String> _ordered;
  static Set<String>? _displayHexes;
  static bool _ready = false;

  static final h3lib.H3 _h3 = const h3lib.H3Factory().load();

  static void ensureInitialized() {
    if (_ready) return;
    final trail = SeattleTrailDefinitions.trails.firstWhere(
      (t) => t.id == activeTrailId,
    );
    _ordered = trail.orderedH3Indexes;
    _hexes = _ordered.toSet();
    _ready = true;
  }

  /// Maximum distance (meters) from the trail polyline for a neighbor hex
  /// centroid to be included in the visual display set. Keeps fringe/water
  /// hexes out while closing legitimate gaps.
  static const double _displayMaxDistanceMeters = 250;

  /// Known water zones along Burke-Gilman (lat-min, lat-max, lng-min, lng-max).
  /// Expansion hexes whose centroids fall inside these boxes are excluded
  /// from the visual display set.  Core trail hexes are never affected since
  /// they are added unconditionally before expansion.
  ///
  /// Coordinates are conservative: they cover **open water** areas, not the
  /// shoreline the trail runs along.  The trail itself is on land just
  /// outside these boxes.
  static const List<(double, double, double, double)> _waterZones = [
    // Ship Canal / Fremont Cut — water south of the trail
    // Trail runs along the north bank (~47.652–47.656).
    // Water body is south of ~47.650 in this stretch.
    (47.6450, 47.6510, -122.3850, -122.3300),
    // Lake Union open water (trail skirts the north shore at Gasworks ~47.646)
    (47.6220, 47.6400, -122.3450, -122.3200),
    // Portage Bay open water (trail crosses at ~47.650 on the north shore)
    (47.6380, 47.6470, -122.3250, -122.3100),
    // Union Bay / Montlake — open water south of the trail
    (47.6380, 47.6480, -122.3100, -122.2900),
    // Lake Washington open water east/south of Sand Point / Magnuson Park
    // Trail is on the west shore at ~-122.263.
    (47.6750, 47.6950, -122.2580, -122.2300),
    // Lake Washington open water near Matthews Beach/Kenmore
    (47.7150, 47.7700, -122.2650, -122.2350),
  ];

  /// Whether a lat/lng point falls in a known water zone.
  ///
  /// Public so [ValidTrailHexes] can reuse it for the Kenmore north-side
  /// correction without duplicating the water-zone table.
  static bool isInWaterZone(double lat, double lng) {
    for (final (latMin, latMax, lngMin, lngMax) in _waterZones) {
      if (lat >= latMin && lat <= latMax && lng >= lngMin && lng <= lngMax) {
        return true;
      }
    }
    return false;
  }

  // ── Kenmore / Lake Forest Park north-side correction ──
  //
  // In this segment the Burke-Gilman hugs Lake Washington's north shore.
  // The water-zone bounding box necessarily overlaps *both* the land
  // (north) and water (south) sides of the trail corridor, which caused
  // legitimate north-side on-trail hexes to be excluded.  We define a
  // segment bounding box and a tight proximity buffer: expansion hexes
  // whose centroids are inside the water zone BUT within the buffer
  // distance of the nearest trail waypoint are kept, restoring the
  // missing north-side hexes while still filtering open-water hexes
  // further from shore.
  //
  // 350 m covers all legitimate 1-ring neighbors including spots where
  // the trail curves tightly along the shoreline (e.g. near Kenmore Air
  // Harbor), pushing north-side hex centroids slightly beyond one full
  // center-to-center distance (~301 m) from the nearest waypoint.
  // Open-water hexes are 600 m+ from the trail so this is still safe.

  /// Trail-proximity buffer for the Kenmore segment override (meters).
  static const double _kenmoreTrailBufferMeters = 350;

  /// Bounding box enclosing the Kenmore / Lake Forest Park correction area.
  static const double _kenmoreLatMin = 47.7100;
  static const double _kenmoreLatMax = 47.7700;
  static const double _kenmoreLngMin = -122.2700;
  static const double _kenmoreLngMax = -122.2300;

  static bool _isInKenmoreSegment(double lat, double lng) {
    return lat >= _kenmoreLatMin &&
        lat <= _kenmoreLatMax &&
        lng >= _kenmoreLngMin &&
        lng <= _kenmoreLngMax;
  }

  /// Visual-only expanded corridor: one-ring neighbors of trail hexes that
  /// are not blacklisted, whose centroid is within [_displayMaxDistanceMeters]
  /// of the nearest trail waypoint, and not in a known water zone.  This makes
  /// the highlighted lane feel continuous without broadening the
  /// playable/recommendable set.
  static Set<String> get displayHexes {
    ensureInitialized();
    if (_displayHexes != null) return _displayHexes!;
    ValidTrailHexes.ensureInitialized();

    // Cache waypoints for distance checks.
    final waypoints = SeattleTrailDefinitions.burkeGilmanWaypoints;

    final expanded = <String>{..._hexes};
    for (final hex in _hexes) {
      final cell = BigInt.parse(hex, radix: 16);
      final ring = _h3.gridDisk(cell, 1);
      for (final neighbor in ring) {
        final nHex = neighbor.toRadixString(16).toLowerCase();
        if (expanded.contains(nHex)) continue;
        if (ValidTrailHexes.isBlacklisted(nHex)) continue;

        // Compute neighbor centroid for spatial checks.
        final nBoundary = _h3.cellToBoundary(neighbor);
        if (nBoundary.isEmpty) continue;
        final cLat =
            nBoundary.fold(0.0, (s, p) => s + p.lat) / nBoundary.length;
        final cLng =
            nBoundary.fold(0.0, (s, p) => s + p.lon) / nBoundary.length;

        // Skip if centroid falls in a known water zone — unless in the
        // Kenmore / Lake Forest Park segment within trail-proximity buffer.
        // See _kenmoreTrailBufferMeters for rationale.
        //
        // When the Kenmore override fires the proximity buffer already
        // guarantees the hex is near the trail, so we skip the global
        // distance cap below (which would otherwise double-filter and
        // reject legitimate north-side hexes whose centroids are > 250 m
        // from the nearest waypoint due to hex geometry).
        var passedKenmoreOverride = false;
        if (isInWaterZone(cLat, cLng)) {
          if (_isInKenmoreSegment(cLat, cLng)) {
            var nearTrail = false;
            for (final wp in waypoints) {
              if (_haversineMeters(cLat, cLng, wp.lat, wp.lng) <=
                  _kenmoreTrailBufferMeters) {
                nearTrail = true;
                break;
              }
            }
            if (!nearTrail) continue;
            passedKenmoreOverride = true;
          } else {
            continue;
          }
        }

        // Distance-cap: skip if too far from nearest trail waypoint.
        // Skipped for Kenmore-overridden hexes (proximity already checked).
        if (!passedKenmoreOverride) {
          var minDist = double.infinity;
          for (final wp in waypoints) {
            final d = _haversineMeters(cLat, cLng, wp.lat, wp.lng);
            if (d < minDist) {
              minDist = d;
              if (d <= _displayMaxDistanceMeters) break; // early exit
            }
          }
          if (minDist > _displayMaxDistanceMeters) continue;
        }

        expanded.add(nHex);
      }
    }
    _displayHexes = expanded;
    return _displayHexes!;
  }

  /// All corridor hex strings (lowercase).
  static Set<String> get hexes {
    ensureInitialized();
    return _hexes;
  }

  /// Ordered corridor hex list (for lane drawing).
  static List<String> get orderedHexes {
    ensureInitialized();
    return _ordered;
  }

  /// Whether [hexLower] is part of the active corridor.
  static bool isOnCorridor(String hexLower) {
    ensureInitialized();
    return _hexes.contains(hexLower);
  }

  /// Find the nearest corridor hex to a position.
  ///
  /// [haversine] and [cellCentroid] are injected so this class stays
  /// independent of MapRenderService.
  static ({String hex, double distanceMeters})? nearestEntry(
    double lat,
    double lng, {
    required double Function(double, double, double, double) haversine,
    required ({double lat, double lng}) Function(BigInt, String) cellCentroid,
  }) {
    ensureInitialized();
    String? best;
    double bestD = double.infinity;
    for (final hex in _ordered) {
      final cell = BigInt.parse(hex, radix: 16);
      final c = cellCentroid(cell, hex);
      final d = haversine(lat, lng, c.lat, c.lng);
      if (d < bestD) {
        bestD = d;
        best = hex;
      }
    }
    if (best == null) return null;
    return (hex: best, distanceMeters: bestD);
  }

  /// Approximate center of the corridor (midpoint hex centroid).
  static ({double lat, double lng}) corridorCenter({
    required ({double lat, double lng}) Function(BigInt, String) cellCentroid,
  }) {
    ensureInitialized();
    final mid = _ordered[_ordered.length ~/ 2];
    return cellCentroid(BigInt.parse(mid, radix: 16), mid);
  }

  // ── Haversine ──

  static double _haversineMeters(
    double lat1,
    double lng1,
    double lat2,
    double lng2,
  ) {
    const r = 6371000.0;
    final dLat = _toRad(lat2 - lat1);
    final dLng = _toRad(lng2 - lng1);
    final a =
        sin(dLat / 2) * sin(dLat / 2) +
        cos(_toRad(lat1)) * cos(_toRad(lat2)) * sin(dLng / 2) * sin(dLng / 2);
    return r * 2 * atan2(sqrt(a), sqrt(1 - a));
  }

  static double _toRad(double deg) => deg * pi / 180;
}
