import 'dart:math';

import 'package:h3_flutter/h3_flutter.dart' as h3lib;

import 'launch_corridor.dart';
import 'seattle_trails.dart';

/// Provides a strict-but-continuous set of Burke-Gilman hex IDs valid for
/// recommendation / playable-target selection.
///
/// Built in two phases:
/// 1. **Polyline core**: densely sample the trail polyline and convert each
///    point to its H3 cell.  These hexes the trail physically passes through.
/// 2. **Corridor expansion**: add any corridor hex that is an H3 neighbor of
///    a core hex.  This closes small gaps the polyline sampling may miss at
///    curves, without admitting off-corridor water hexes.
///
/// The blacklist always wins: blacklisted hexes are excluded regardless.
///
/// Usage mirrors [LaunchCorridor]: call-site checks
/// `ValidTrailHexes.isValid(hexLower)`.
class ValidTrailHexes {
  ValidTrailHexes._();

  static const int _h3Resolution = 9;

  /// Number of interpolation samples per waypoint segment.
  static const int _samplesPerSegment = 40;

  /// Manual blacklist for known bad hexes (water, inaccessible shoreline).
  /// Add lowercase hex strings here to force-exclude them.
  static const Set<String> _blacklist = {};

  static late final Set<String> _validIds;

  /// Maps each valid hex to the nearest point on the trail polyline.
  /// Used for snapped guidance (direction arrows, distance copy).
  static late final Map<String, ({double lat, double lng})> _guidancePoints;

  /// Debug: maps each hex to the sample point that first placed it in set.
  static late final Map<String, ({double lat, double lng})> _debugSamplePoints;

  static bool _ready = false;
  static final h3lib.H3 _h3 = const h3lib.H3Factory().load();

  static void ensureInitialized() {
    if (_ready) return;
    _build();
    _ready = true;
  }

  /// Set of hex IDs valid for recommendation.
  static Set<String> get validHexIds {
    ensureInitialized();
    return _validIds;
  }

  /// Whether [hexLower] is a valid recommendation target.
  static bool isValid(String hexLower) {
    ensureInitialized();
    return _validIds.contains(hexLower);
  }

  /// Whether [hexLower] is manually blacklisted (water / inaccessible).
  static bool isBlacklisted(String hexLower) => _blacklist.contains(hexLower);

  /// Snapped guidance point on the trail polyline for [hexLower].
  /// Returns null if hex is not valid.
  static ({double lat, double lng})? guidancePointForHex(String hexLower) {
    ensureInitialized();
    return _guidancePoints[hexLower];
  }

  /// Debug: the polyline sample point that first placed this hex in the set.
  static ({double lat, double lng})? debugSamplePointForHex(String hexLower) {
    ensureInitialized();
    return _debugSamplePoints[hexLower];
  }

  /// Debug: distance from hex centroid to its guidance point.
  static double? debugDistanceForHex(String hexLower) {
    ensureInitialized();
    final gp = _guidancePoints[hexLower];
    if (gp == null) return null;
    final cell = BigInt.parse(hexLower, radix: 16);
    final boundary = _h3.cellToBoundary(cell);
    if (boundary.isEmpty) return null;
    final centLat = boundary.fold(0.0, (s, p) => s + p.lat) / boundary.length;
    final centLng = boundary.fold(0.0, (s, p) => s + p.lon) / boundary.length;
    return _haversineMeters(centLat, centLng, gp.lat, gp.lng);
  }

  /// Number of corridor hexes NOT in the valid set.
  static int get debugRejectedCount {
    ensureInitialized();
    final trail = SeattleTrailDefinitions.trails.firstWhere(
      (t) => t.id == 'burke_gilman',
    );
    return trail.orderedH3Indexes.length - _validIds.length;
  }

  // ── Build ──

  static void _build() {
    final waypoints = SeattleTrailDefinitions.burkeGilmanWaypoints;

    _validIds = {};
    _guidancePoints = {};
    _debugSamplePoints = {};

    // Phase 1: Polyline core — densely sample the trail and collect the
    // H3 cells the polyline actually passes through.
    final coreHexes = <String>{};

    for (var i = 0; i < waypoints.length - 1; i++) {
      final a = waypoints[i];
      final b = waypoints[i + 1];

      for (var s = 0; s <= _samplesPerSegment; s++) {
        final t = s / _samplesPerSegment;
        final lat = a.lat + (b.lat - a.lat) * t;
        final lng = a.lng + (b.lng - a.lng) * t;

        final cell = _h3.geoToCell(
          h3lib.GeoCoord(lat: lat, lon: lng),
          _h3Resolution,
        );
        final hex = cell.toRadixString(16).toLowerCase();

        if (_blacklist.contains(hex)) continue;

        if (coreHexes.add(hex)) {
          _guidancePoints[hex] = (lat: lat, lng: lng);
          _debugSamplePoints[hex] = (lat: lat, lng: lng);
        } else {
          // Update guidance point if this sample is closer to centroid.
          final boundary = _h3.cellToBoundary(cell);
          if (boundary.isNotEmpty) {
            final centLat =
                boundary.fold(0.0, (s, p) => s + p.lat) / boundary.length;
            final centLng =
                boundary.fold(0.0, (s, p) => s + p.lon) / boundary.length;
            final existing = _guidancePoints[hex]!;
            final oldD = _haversineMeters(
              centLat,
              centLng,
              existing.lat,
              existing.lng,
            );
            final newD = _haversineMeters(centLat, centLng, lat, lng);
            if (newD < oldD) {
              _guidancePoints[hex] = (lat: lat, lng: lng);
            }
          }
        }
      }
    }

    // Start with all core hexes.
    _validIds.addAll(coreHexes);

    // Phase 2: Corridor expansion — add corridor hexes that are H3
    // neighbors of a core hex.  This closes continuity gaps at curves
    // without admitting off-corridor water hexes.
    LaunchCorridor.ensureInitialized();
    final corridorSet = LaunchCorridor.hexes;

    for (final coreHex in coreHexes) {
      final cell = BigInt.parse(coreHex, radix: 16);
      final ring = _h3.gridDisk(cell, 1);
      for (final neighbor in ring) {
        final nHex = neighbor.toRadixString(16).toLowerCase();
        if (_blacklist.contains(nHex)) continue;
        if (_validIds.contains(nHex)) continue;
        if (!corridorSet.contains(nHex)) continue;

        _validIds.add(nHex);

        // Derive a guidance point: use the nearest core hex's guidance
        // point since the neighbor has no direct polyline sample.
        final coreGp = _guidancePoints[coreHex];
        if (coreGp != null) {
          _guidancePoints[nHex] = coreGp;
        }
      }
    }

    // ── Phase 2.5: Kenmore / Lake Forest Park north-side correction ──
    //
    // In this segment the Burke-Gilman hugs Lake Washington's north shore.
    // The polyline can run near hex-row boundaries so legitimate north-side
    // on-trail hexes may appear in neither the polyline core nor the
    // corridor chain.  We explicitly include 1-ring neighbors of
    // Kenmore-segment core hexes whose centroids are:
    //   • within a tight buffer (180 m) of the trail polyline, AND
    //   • NOT in a known open-water zone.
    // This restores the missing north-side hexes without broadening the
    // corridor elsewhere.
    //
    // Note: we do NOT use the water-zone check here because the Kenmore
    // water-zone bounding box unavoidably covers land hexes north of the
    // trail (the box can't follow the diagonal shoreline).  The 350 m
    // proximity buffer is tight enough on its own — open-water hexes are
    // 600 m+ from the trail and will never pass.
    const double kenmoreLatMin = 47.7100;
    const double kenmoreLatMax = 47.7700;
    const double kenmoreLngMin = -122.2700;
    const double kenmoreLngMax = -122.2300;
    const double kenmoreBuffer = 350; // meters — covers tight-curve hexes

    for (final coreHex in coreHexes) {
      final coreCell = BigInt.parse(coreHex, radix: 16);
      final coreBnd = _h3.cellToBoundary(coreCell);
      if (coreBnd.isEmpty) continue;
      final coreLat =
          coreBnd.fold(0.0, (s, p) => s + p.lat) / coreBnd.length;
      final coreLng =
          coreBnd.fold(0.0, (s, p) => s + p.lon) / coreBnd.length;

      // Only process core hexes inside the Kenmore segment.
      if (coreLat < kenmoreLatMin ||
          coreLat > kenmoreLatMax ||
          coreLng < kenmoreLngMin ||
          coreLng > kenmoreLngMax) {
        continue;
      }

      final ring = _h3.gridDisk(coreCell, 1);
      for (final neighbor in ring) {
        final nHex = neighbor.toRadixString(16).toLowerCase();
        if (_blacklist.contains(nHex)) continue;
        if (_validIds.contains(nHex)) continue;

        final nBnd = _h3.cellToBoundary(neighbor);
        if (nBnd.isEmpty) continue;
        final nLat = nBnd.fold(0.0, (s, p) => s + p.lat) / nBnd.length;
        final nLng = nBnd.fold(0.0, (s, p) => s + p.lon) / nBnd.length;

        // Must be within trail-proximity buffer (water-zone check
        // intentionally omitted — see note above).
        var nearTrail = false;
        for (final wp in waypoints) {
          if (_haversineMeters(nLat, nLng, wp.lat, wp.lng) <= kenmoreBuffer) {
            nearTrail = true;
            break;
          }
        }
        if (!nearTrail) continue;

        _validIds.add(nHex);

        final coreGp = _guidancePoints[coreHex];
        if (coreGp != null) {
          _guidancePoints[nHex] = coreGp;
        }
      }
    }
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
