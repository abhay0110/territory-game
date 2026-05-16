// Sweep wire contract tests.  Build +26.
//
// Pins the JSON shape exchanged between the Dart client
// (SweepService + sweep_models.dart) and the Supabase Edge Function
// (supabase/functions/sweep/index.ts).
//
// Two complementary checks:
//   1. Pure model round-trip: SweepRequest.toJson and
//      SweepResponse.fromJson produce/accept the locked field names.
//   2. Source-file inspection: the edge function source contains the
//      same field names.  Catches silent rename drift between the
//      two halves of the contract.
//
// If this test fails, the fix is usually:
//   - update sweep_models.dart, OR
//   - update supabase/functions/sweep/index.ts
// then update this contract test to match the new agreed shape.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:HexTrail/src/data/services/sweep/sweep_models.dart';

void main() {
  group('SweepRequest.toJson', () {
    test('produces the locked wire shape', () {
      final req = SweepRequest(
        source: SweepSource.gpx,
        points: [
          SweepPoint(
            ts: DateTime.utc(2026, 5, 16, 12, 0, 0),
            lat: 47.65,
            lon: -122.31,
          ),
          SweepPoint(
            ts: DateTime.utc(2026, 5, 16, 12, 0, 30),
            lat: 47.66,
            lon: -122.32,
            accuracyMeters: 8.5,
          ),
        ],
      );

      final json = req.toJson();
      expect(json['source'], 'gpx');
      expect(json['points'], isA<List>());
      expect((json['points'] as List).length, 2);

      final first = (json['points'] as List)[0] as Map<String, dynamic>;
      expect(first.keys, containsAll(['ts', 'lat', 'lon']));
      expect(first.containsKey('accuracy'), isFalse,
          reason: 'omit accuracy when null');
      expect(first['ts'], '2026-05-16T12:00:00.000Z');
      expect(first['lat'], closeTo(47.65, 1e-9));
      expect(first['lon'], closeTo(-122.31, 1e-9));

      final second = (json['points'] as List)[1] as Map<String, dynamic>;
      expect(second['accuracy'], closeTo(8.5, 1e-9));
    });

    test('normalises non-UTC timestamps to UTC ISO-8601', () {
      // Non-UTC input — must serialise to a Z-suffixed UTC string.
      final localTs = DateTime.parse('2026-05-16T05:00:00-07:00');
      final req = SweepRequest(
        source: SweepSource.strava,
        points: [SweepPoint(ts: localTs, lat: 0, lon: 0)],
      );
      final first =
          (req.toJson()['points'] as List)[0] as Map<String, dynamic>;
      expect(first['ts'], '2026-05-16T12:00:00.000Z');
    });

    test('SweepSource.wire covers every enum value', () {
      // Keep in sync with VALID_SOURCES in the edge function.
      expect(SweepSource.gpx.wire, 'gpx');
      expect(SweepSource.strava.wire, 'strava');
      expect(SweepSource.healthkit.wire, 'healthkit');
      expect(SweepSource.healthconnect.wire, 'healthconnect');
      expect(SweepSource.garmin.wire, 'garmin');
    });
  });

  group('SweepResponse.fromJson', () {
    test('parses the locked wire shape', () {
      final json = <String, dynamic>{
        'import_run_id': '00000000-0000-0000-0000-000000000001',
        'source': 'gpx',
        'points_in': 12,
        'points_after_accuracy': 11,
        'points_after_window': 9,
        'hexes_captured': 0,
        'rejected_pre_install': 2,
        'status': 'success',
        'message': 'Upload received.',
      };
      final r = SweepResponse.fromJson(json);
      expect(r.importRunId, '00000000-0000-0000-0000-000000000001');
      expect(r.source, 'gpx');
      expect(r.pointsIn, 12);
      expect(r.pointsAfterAccuracy, 11);
      expect(r.pointsAfterWindow, 9);
      expect(r.hexesCaptured, 0);
      expect(r.rejectedPreInstall, 2);
      expect(r.status, 'success');
      expect(r.message, 'Upload received.');
    });

    test('coerces num counters from int and double', () {
      // Supabase Functions can return either int or double for numeric
      // fields depending on payload size; fromJson must tolerate both.
      final r = SweepResponse.fromJson({
        'import_run_id': 'x',
        'source': 'gpx',
        'points_in': 1.0,
        'points_after_accuracy': 1,
        'points_after_window': 1,
        'hexes_captured': 0,
        'rejected_pre_install': 0,
        'status': 'success',
        'message': '',
      });
      expect(r.pointsIn, 1);
    });

    test('tolerates missing message field', () {
      final r = SweepResponse.fromJson({
        'import_run_id': 'x',
        'source': 'gpx',
        'points_in': 0,
        'points_after_accuracy': 0,
        'points_after_window': 0,
        'hexes_captured': 0,
        'rejected_pre_install': 0,
        'status': 'success',
      });
      expect(r.message, '');
    });
  });

  group('Edge function source contract', () {
    // Catches drift where someone renames a field on one side of the
    // wire without updating the other.  We literally read the .ts
    // source file and assert the locked field names appear.
    late String functionSrc;

    setUpAll(() {
      final file = File('supabase/functions/sweep/index.ts');
      expect(file.existsSync(), isTrue,
          reason: 'edge function source must exist at expected path');
      functionSrc = file.readAsStringSync();
    });

    test('request field names appear in edge function source', () {
      for (final key in const [
        'body.source',
        'body.points',
        'p.ts',
        'p.lat',
        'p.lon',
      ]) {
        expect(functionSrc.contains(key), isTrue,
            reason: 'edge function should reference $key');
      }
    });

    test('response field names appear in edge function source', () {
      for (final key in const [
        'import_run_id',
        'points_in',
        'points_after_accuracy',
        'points_after_window',
        'hexes_captured',
        'rejected_pre_install',
        'status',
        'message',
      ]) {
        expect(functionSrc.contains(key), isTrue,
            reason: 'edge function should reference $key');
      }
    });

    test('all SweepSource enum wire values are in VALID_SOURCES', () {
      for (final s in SweepSource.values) {
        expect(functionSrc.contains('"${s.wire}"'), isTrue,
            reason: 'edge function VALID_SOURCES must include ${s.wire}');
      }
    });

    test('audit table column names match the migration', () {
      final migration =
          File('supabase/migrations/add_import_runs.sql').readAsStringSync();
      for (final col in const [
        'user_id',
        'source',
        'points_in',
        'points_after_accuracy',
        'points_after_window',
        'hexes_captured',
        'hexes_rejected_offtrail',
        'hexes_rejected_cooldown',
        'rejected_pre_install',
        'duration_ms',
        'status',
      ]) {
        expect(migration.contains(col), isTrue,
            reason: 'migration should declare $col');
        expect(functionSrc.contains(col), isTrue,
            reason: 'edge function should write $col');
      }
    });
  });
}
