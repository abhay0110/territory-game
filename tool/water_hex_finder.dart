import 'dart:math';
import 'package:h3_flutter/h3_flutter.dart' as h3lib;
import 'package:HexTrail/core/constants/seattle_trails.dart';
import 'package:HexTrail/core/constants/launch_corridor.dart';
import 'package:HexTrail/core/constants/valid_trail_hexes.dart';

/// Identifies candidate water/inaccessible hexes in the visual display
/// expansion that should be blacklisted.
///
/// Strategy: find hexes in LaunchCorridor.displayHexes that are NOT in
/// LaunchCorridor.hexes (i.e., they are expansion neighbors), and whose
/// centroid falls in known water zones along the Burke-Gilman.
void main() {
  LaunchCorridor.ensureInitialized();
  ValidTrailHexes.ensureInitialized();

  final h3 = const h3lib.H3Factory().load();
  final waypoints = SeattleTrailDefinitions.burkeGilmanWaypoints;

  final coreHexes = LaunchCorridor.hexes;
  final displayHexes = LaunchCorridor.displayHexes;
  final expansionOnly = displayHexes.difference(coreHexes);

  print('Core corridor hexes: ${coreHexes.length}');
  print('Display hexes: ${displayHexes.length}');
  print('Expansion-only hexes: ${expansionOnly.length}');
  print('');

  // Known water bounding boxes along Burke-Gilman:
  // 1. Lake Union: roughly 47.626-47.640 N, -122.340 to -122.330 W
  // 2. Ship Canal / Fremont Cut: 47.648-47.657 N, -122.370 to -122.330 W
  // 3. Portage Bay / University Bridge area: 47.643-47.652 N, -122.325 to -122.310 W
  // 4. Lake Washington near Sand Point: 47.680-47.695 N, -122.260 to -122.245 W
  // 5. Lake Washington south of Kenmore: 47.740-47.770 N, -122.260 to -122.240 W

  // For a more accurate approach, compute hex centroid and check if it's
  // on the water-side of the trail by checking distance to the trail polyline
  // vs distance in specific water-prone directions.
  //
  // Simpler approach: find expansion hexes whose centroids are farthest from
  // the trail polyline in water-heavy sections.

  // List ALL expansion hexes with their centroid and distance to trail
  final candidates = <({String hex, double lat, double lng, double trailDist})>[];

  for (final hex in expansionOnly) {
    final cell = BigInt.parse(hex, radix: 16);
    final boundary = h3.cellToBoundary(cell);
    if (boundary.isEmpty) continue;
    final cLat = boundary.fold(0.0, (s, p) => s + p.lat) / boundary.length;
    final cLng = boundary.fold(0.0, (s, p) => s + p.lon) / boundary.length;

    // Find nearest trail waypoint distance
    var minDist = double.infinity;
    for (final wp in waypoints) {
      final d = _haversineMeters(cLat, cLng, wp.lat, wp.lng);
      if (d < minDist) minDist = d;
    }

    candidates.add((hex: hex, lat: cLat, lng: cLng, trailDist: minDist));
  }

  candidates.sort((a, b) => b.trailDist.compareTo(a.trailDist));

  print('Expansion hex candidates sorted by distance from trail:');
  print('(farthest first — likely water/inaccessible)\n');
  for (final c in candidates) {
    final label = c.trailDist > 200 ? ' *** LIKELY WATER ***' : '';
    print(
      '  ${c.hex}  '
      'lat=${c.lat.toStringAsFixed(5)} '
      'lng=${c.lng.toStringAsFixed(5)} '
      'dist=${c.trailDist.toStringAsFixed(1)}m'
      '$label',
    );
  }

  // Also check core corridor hexes that are NOT in valid set
  final coreNotValid = coreHexes.difference(ValidTrailHexes.validHexIds);
  print('\n\nCore corridor hexes NOT in valid set: ${coreNotValid.length}');
  for (final hex in coreNotValid) {
    final cell = BigInt.parse(hex, radix: 16);
    final boundary = h3.cellToBoundary(cell);
    if (boundary.isEmpty) continue;
    final cLat = boundary.fold(0.0, (s, p) => s + p.lat) / boundary.length;
    final cLng = boundary.fold(0.0, (s, p) => s + p.lon) / boundary.length;
    print(
      '  $hex  '
      'lat=${cLat.toStringAsFixed(5)} lng=${cLng.toStringAsFixed(5)}',
    );
  }

  // Print a ready-to-paste blacklist set for hexes > 200m from trail
  final blacklistCandidates =
      candidates.where((c) => c.trailDist > 200).toList();
  if (blacklistCandidates.isNotEmpty) {
    print('\n\n// Ready-to-paste blacklist (expansion hexes > 200m from trail):');
    print('static const Set<String> _blacklist = {');
    for (final c in blacklistCandidates) {
      print("  '${c.hex}', // ${c.trailDist.toStringAsFixed(0)}m from trail");
    }
    print('};');
  }
}

double _haversineMeters(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  final dLat = _toRad(lat2 - lat1);
  final dLng = _toRad(lng2 - lng1);
  final a = sin(dLat / 2) * sin(dLat / 2) +
      cos(_toRad(lat1)) * cos(_toRad(lat2)) * sin(dLng / 2) * sin(dLng / 2);
  return r * 2 * atan2(sqrt(a), sqrt(1 - a));
}

double _toRad(double deg) => deg * pi / 180;
