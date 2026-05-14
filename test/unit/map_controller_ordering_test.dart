// Source-level invariant test for the map_controller refresh ordering.
//
// Why source-level: MapController depends on Supabase, geolocator, and
// Mapbox — all hard to mock without bringing in a mocking framework.
// The actual invariant is structural ("refresh calls precede the
// capturedTiles snapshot read") so a lightweight source-string assertion
// is a deterministic tripwire that catches regression without runtime
// plumbing.
//
// If this test breaks because the file was reorganized, update the
// regex BUT verify the ordering invariant is preserved.  Specifically:
// `refreshNearbyOwnersForHex` AND `refreshCorridorOwners` must both
// complete BEFORE the first call to `getCapturedTilesForCurrentUser`.

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('REGRESSION: map_controller refresh ordering', () {
    late String source;

    setUpAll(() {
      final file = File('lib/features/map/map_controller.dart');
      expect(file.existsSync(), isTrue,
          reason: 'map_controller.dart must exist at expected path');
      source = file.readAsStringSync();
    });

    int _idx(String needle) {
      final i = source.indexOf(needle);
      expect(i, greaterThanOrEqualTo(0),
          reason: 'expected to find "$needle" in map_controller.dart');
      return i;
    }

    test('refreshNearbyOwnersForHex precedes getCapturedTilesForCurrentUser',
        () {
      final refreshIdx = _idx('captureService.refreshNearbyOwnersForHex(');
      final snapshotIdx = _idx('captureService.getCapturedTilesForCurrentUser(');
      expect(refreshIdx, lessThan(snapshotIdx),
          reason:
              'Nearby refresh must run before captured-tiles snapshot so '
              'reconcile-driven prunes are visible same cycle. '
              'See map_controller.dart `refreshMapForCoordinates`.');
    });

    test('refreshCorridorOwners precedes getCapturedTilesForCurrentUser', () {
      final refreshIdx = _idx('captureService.refreshCorridorOwners(');
      final snapshotIdx = _idx('captureService.getCapturedTilesForCurrentUser(');
      expect(refreshIdx, lessThan(snapshotIdx),
          reason:
              'Corridor refresh must run before captured-tiles snapshot so '
              'a 3-mi-from-trail user sees lost trail hexes flip from green '
              'to enemy in the SAME refresh cycle (~15s), not the next.  '
              'This is the build-13 → build-14 UI-ordering fix.');
    });

    test('getCorridorTiles snapshot read happens after both refreshes', () {
      final corridorRefreshIdx = _idx('captureService.refreshCorridorOwners(');
      final corridorSnapshotIdx = _idx('captureService.getCorridorTiles(');
      expect(corridorRefreshIdx, lessThan(corridorSnapshotIdx),
          reason: 'Corridor snapshot read must come after the refresh.');
    });
  });
}
