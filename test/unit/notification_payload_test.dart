// Pure-logic tests for NotificationService.parseTileLostPayload.
//
// Validates the FCM data-payload contract with the Edge Function
// `supabase/functions/notify-tile-event/index.ts`.  These tests catch
// silent payload-shape drift between server and client without
// requiring a real FCM delivery.

import 'package:flutter_test/flutter_test.dart';
import 'package:HexTrail/src/services/notification_service.dart';

void main() {
  group('parseTileLostPayload — happy path', () {
    test('current contract: { event: tile_lost, hexId: <hex> }', () {
      final hex = NotificationService.parseTileLostPayload(<String, dynamic>{
        'event': 'tile_lost',
        'hexId': '8a283082a677fff',
      });
      expect(hex, '8a283082a677fff');
    });

    test('legacy keys: { type: tile_lost, h3_hex: <hex> } still works', () {
      final hex = NotificationService.parseTileLostPayload(<String, dynamic>{
        'type': 'tile_lost',
        'h3_hex': '8a283082a677fff',
      });
      expect(hex, '8a283082a677fff');
    });

    test('case-insensitive hex normalization → lowercase output', () {
      final hex = NotificationService.parseTileLostPayload(<String, dynamic>{
        'event': 'tile_lost',
        'hexId': '8A283082A677FFF',
      });
      expect(hex, '8a283082a677fff');
    });
  });

  group('parseTileLostPayload — silent-drop semantics', () {
    test('wrong event type → null', () {
      final hex = NotificationService.parseTileLostPayload(<String, dynamic>{
        'event': 'tile_captured',
        'hexId': '8a283082a677fff',
      });
      expect(hex, isNull);
    });

    test('missing event key → null', () {
      final hex = NotificationService.parseTileLostPayload(<String, dynamic>{
        'hexId': '8a283082a677fff',
      });
      expect(hex, isNull);
    });

    test('missing hex key → null', () {
      final hex = NotificationService.parseTileLostPayload(<String, dynamic>{
        'event': 'tile_lost',
      });
      expect(hex, isNull);
    });

    test('empty hex string → null', () {
      final hex = NotificationService.parseTileLostPayload(<String, dynamic>{
        'event': 'tile_lost',
        'hexId': '',
      });
      expect(hex, isNull);
    });

    test('non-hex characters → null (regex guard)', () {
      final hex = NotificationService.parseTileLostPayload(<String, dynamic>{
        'event': 'tile_lost',
        'hexId': 'not-a-hex!!',
      });
      expect(hex, isNull);
    });

    test('empty payload → null', () {
      expect(
        NotificationService.parseTileLostPayload(const <String, dynamic>{}),
        isNull,
      );
    });

    test('null values → null (no throw)', () {
      final hex = NotificationService.parseTileLostPayload(<String, dynamic>{
        'event': null,
        'hexId': null,
      });
      expect(hex, isNull);
    });
  });

  // ── REGRESSION FIXTURES ──────────────────────────────────────────────
  group('REGRESSION: FCM payload contract', () {
    test('exact edge function payload (notify-tile-event/index.ts)', () {
      // This is the literal shape produced by the edge function as of
      // the build-14 contract.  If the edge function ever changes
      // payload shape and forgets to update this test, the failure
      // here is the early-warning signal before a build ships.
      const edgeFunctionPayload = <String, dynamic>{
        'event': 'tile_lost',
        'hexId': '8a283082a677fff',
      };
      expect(
        NotificationService.parseTileLostPayload(edgeFunctionPayload),
        '8a283082a677fff',
      );
    });
  });
}
