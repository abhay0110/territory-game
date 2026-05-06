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
  ///
  /// Kenmore Air Harbor / north-shore lakefront cluster: 11 hexes added by
  /// the Phase 2.5 waypoint-proximity expansion that fall 214–558m off the
  /// actual Burke-Gilman polyline (verified against OSM relation 2183654 in
  /// tool/diff_hex_sets.dart).  Several sit inside LaunchCorridor's water
  /// bbox.  These are visible on the map south of the trail over Lake
  /// Washington / the seaplane apron and are not reachable on foot.
  ///
  /// Visual-audit batch (10 hexes): identified via in-app tap-to-log
  /// against the live OSM polyline overlay.  Spread across Bothell,
  /// Kenmore, UW/Sand Point, Lake Union and Ballard — Phase 2 / 2.5
  /// false positives that drift from the actual trail.
  static const Set<String> _blacklist = {
    // Kenmore Air Harbor / lakefront (Phase 2.5 false positives)
    '8928d54e20bffff', // 47.75329, -122.25585  (558m off-trail, in water)
    '8928d54e20fffff', // 47.75438, -122.25984  (406m off-trail, in water)
    '8928d54e233ffff', // 47.75369, -122.26763  (389m off-trail)
    '8928d54e23bffff', // 47.75546, -122.26384  (283m off-trail, in water)
    '8928d54e243ffff', // 47.75397, -122.24806  (429m off-trail)
    '8928d54e247ffff', // 47.75506, -122.25206  (367m off-trail)
    '8928d54e25bffff', // 47.75289, -122.24407  (474m off-trail)
    '8928d54e273ffff', // 47.75614, -122.25605  (241m off-trail, in water)
    '8928d54f013ffff', // 47.75343, -122.20492  (276m off-trail)
    '8928d54f193ffff', // 47.75357, -122.23628  (264m off-trail)
    '8928d54f197ffff', // 47.75465, -122.24027  (214m off-trail)
    // Visual-audit batch — user-tapped, off-trail
    '8928d54f083ffff', // 47.74924, -122.20836  Wayne / Bothell
    '8928d54f0a3ffff', // 47.75397, -122.21637  Bothell
    '8928d54f563ffff', // 47.75076, -122.22866  Bothell west
    '8928d54e3cbffff', // 47.75627, -122.27616  Kenmore
    '8928d54e4d7ffff', // 47.71208, -122.28039  Lake Forest Park
    '8928d541db7ffff', // 47.68742, -122.27096  UW / Sand Point
    '8928d547613ffff', // 47.66022, -122.36180  Lake Union
    '8928d5473abffff', // 47.68871, -122.39914  Ballard
    '8928d5473bbffff', // 47.68558, -122.40010  Ballard
    '8928d547387ffff', // 47.68268, -122.39943  Ballard
    // Visual-audit batch 2 — user-tapped, off-trail
    '8928d54e0c7ffff', // 47.73518, -122.28212  Lake Forest Park N
    '8928d54e09bffff', // 47.73047, -122.28566  Lake Forest Park
    '8928d54e457ffff', // 47.71968, -122.27626  Lake Forest Park S
    '8928d540a4fffff', // 47.70449, -122.27169  Sheridan Beach
    '8928d540a1bffff', // 47.69848, -122.27988  Matthews Beach N
    '8928d540ad3ffff', // 47.69146, -122.27509  Matthews Beach
    '8928d54032fffff', // 47.67926, -122.26161  Sand Point N
    '8928d540163ffff', // 47.66619, -122.27735  UW / Husky Stadium area
    '8928d5401afffff', // 47.65956, -122.29259  Montlake
    '8928d540123ffff', // 47.66427, -122.28848  UW (was core — confirmed off-trail)
    '8928d540127ffff', // 47.66548, -122.29266  UW
    '8928d542a23ffff', // 47.65180, -122.31544  Eastlake / Portage Bay
    '8928d542a27ffff', // 47.65280, -122.31927  Eastlake
    '8928d542b43ffff', // 47.65709, -122.32381  Wallingford
    '8928d5470cfffff', // 47.66844, -122.38286  Ballard / Fremont
    // Visual-audit batch 3 — user-tapped, off-trail
    '8928d54e3c3ffff', // 47.75369, -122.27929  Kenmore
    '8928d54e3d7ffff', // 47.75207, -122.28308  Kenmore W
    '8928d54294bffff', // 47.64622, -122.34557  Eastlake (was core — confirmed off-trail)
    '8928d547013ffff', // 47.66669, -122.39049  Ballard
    '8928d547037ffff', // 47.67288, -122.40245  Ballard
    '8928d547027ffff', // 47.67551, -122.40293  Ballard
    '8928d5470a7ffff', // 47.66794, -122.40696  Ballard
  };

  /// Manually-confirmed on-trail hexes that the polyline-sampling +
  /// neighbor-expansion phases miss (e.g. when the trail rides a hex
  /// boundary or our reference polyline has a small gap).  Each entry is
  /// added to both `_validIds` and `_coreIds` and surfaced visually via
  /// `LaunchCorridor.displayHexes`.  Identified via in-app tap-to-log.
  static const Set<String> _whitelist = {
    '8928d54e263ffff', // 47.75828, -122.25588  Kenmore on-trail (north shore)
  };

  static late final Set<String> _validIds;

  /// Strict polyline-core hexes only (Phase 1 — hexes the trail polyline
  /// physically passes through). Excludes 1-ring corridor expansion and
  /// the Kenmore north-side correction set.
  ///
  /// Used to bias glow target selection toward hexes that visually sit
  /// on the trail line, while leaving capture eligibility and
  /// section/streak math on the broader [validHexIds] set.
  static late final Set<String> _coreIds;

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

  /// Strict polyline-core hex IDs (no 1-ring or Kenmore expansion).
  /// Prefer these for glow target selection so the recommendation visually
  /// hugs the trail line.
  static Set<String> get coreHexIds {
    ensureInitialized();
    return _coreIds;
  }

  /// Whether [hexLower] is a polyline-core hex (Phase 1 only).
  static bool isCore(String hexLower) {
    ensureInitialized();
    return _coreIds.contains(hexLower);
  }

  /// Whether [hexLower] is a valid recommendation target.
  static bool isValid(String hexLower) {
    ensureInitialized();
    return _validIds.contains(hexLower);
  }

  /// Whether [hexLower] is manually blacklisted (water / inaccessible).
  static bool isBlacklisted(String hexLower) => _blacklist.contains(hexLower);

  /// Hexes manually whitelisted as on-trail (added to valid + core + display).
  static Set<String> get whitelistedHexIds => _whitelist;

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
    _coreIds = {};
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
    _coreIds.addAll(coreHexes);

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
      final coreLat = coreBnd.fold(0.0, (s, p) => s + p.lat) / coreBnd.length;
      final coreLng = coreBnd.fold(0.0, (s, p) => s + p.lon) / coreBnd.length;

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

    // Phase 3: Manual whitelist — hexes the polyline + neighbor passes
    // miss but the user has confirmed via tap-to-log are on the trail.
    // Whitelist takes precedence over blacklist (defensive: a hex should
    // never be in both, but whitelist wins to surface user intent).
    for (final hex in _whitelist) {
      _validIds.add(hex);
      _coreIds.add(hex);
      // Use the H3 cell centroid as the guidance point.
      final cell = BigInt.parse(hex, radix: 16);
      final boundary = _h3.cellToBoundary(cell);
      if (boundary.isNotEmpty) {
        final cLat = boundary.fold(0.0, (s, p) => s + p.lat) / boundary.length;
        final cLng = boundary.fold(0.0, (s, p) => s + p.lon) / boundary.length;
        _guidancePoints[hex] = (lat: cLat, lng: cLng);
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
