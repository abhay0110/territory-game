// Edge function payload contract test.
//
// The Dart client (NotificationService.notifyTileLost) sends:
//   { type: 'tile_lost', target_user_id: <uuid>, h3_hex: <hex> }
// to the `notify-tile-event` Supabase Edge Function.
//
// The edge function (supabase/functions/notify-tile-event/index.ts)
// reads BOTH camelCase and snake_case forms for compat:
//   payload.type ?? payload.event
//   payload.target_user_id ?? payload.targetPlayerId
//   payload.h3_hex ?? payload.hexId
//
// And in turn, the FCM `data` block it dispatches to clients is:
//   { event: type, hexId: h3Hex }   (camelCase to mirror flutter side)
//
// This test pins BOTH halves of the contract by literally reading the
// edge function source file and asserting the key names appear.  It
// catches silent rename drift (e.g. someone renaming `target_user_id`
// to `targetUserId` on the client without updating the function).
//
// If this test fails, the fix is usually:
//   - update notification_service.dart to send the new key, OR
//   - update notify-tile-event/index.ts to read the new key
// then update this contract test to match the new agreed shape.

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Edge function payload contract', () {
    late String clientSource;
    late String edgeSource;

    setUpAll(() {
      final clientFile = File('lib/src/services/notification_service.dart');
      final edgeFile = File('supabase/functions/notify-tile-event/index.ts');
      expect(clientFile.existsSync(), isTrue);
      expect(edgeFile.existsSync(), isTrue);
      clientSource = clientFile.readAsStringSync();
      edgeSource = edgeFile.readAsStringSync();
    });

    // ── Client → Edge Function (request body) ─────────────────────────
    group('client → edge function', () {
      test("client sends 'type': 'tile_lost'", () {
        expect(clientSource.contains("'type': 'tile_lost'"), isTrue,
            reason: 'notify-tile-event reads payload.type for event '
                'classification.');
      });

      test("client sends 'target_user_id'", () {
        expect(clientSource.contains("'target_user_id'"), isTrue,
            reason: 'notify-tile-event reads payload.target_user_id for '
                'recipient lookup.');
      });

      test("client sends 'h3_hex'", () {
        expect(clientSource.contains("'h3_hex'"), isTrue,
            reason: 'notify-tile-event reads payload.h3_hex for ownership '
                'authorization check.');
      });

      test('edge function reads payload.type', () {
        expect(edgeSource.contains('payload.type'), isTrue);
      });

      test('edge function reads payload.target_user_id', () {
        expect(edgeSource.contains('payload.target_user_id'), isTrue);
      });

      test('edge function reads payload.h3_hex', () {
        expect(edgeSource.contains('payload.h3_hex'), isTrue);
      });
    });

    // ── Edge Function → Client (FCM data payload) ─────────────────────
    group('edge function → client (FCM data)', () {
      test("edge function emits FCM data { event: type, hexId: h3Hex }", () {
        // The exact line in index.ts:
        //   { event: type, hexId: h3Hex }
        // is the FCM `data` payload that the Flutter client parses via
        // NotificationService.parseTileLostPayload.
        expect(
          edgeSource.contains('{ event: type, hexId: h3Hex }'),
          isTrue,
          reason: 'Edge function must emit { event, hexId } so the '
              "Flutter client's parseTileLostPayload() finds the keys "
              'it expects.  See notification_payload_test.dart for the '
              'client side.',
        );
      });

      test("client parser reads 'event' or 'type' (forward-compat)", () {
        expect(clientSource.contains("data['event']"), isTrue);
        expect(clientSource.contains("data['type']"), isTrue);
      });

      test("client parser reads 'hexId' or 'h3_hex' (forward-compat)", () {
        expect(clientSource.contains("data['hexId']"), isTrue);
        expect(clientSource.contains("data['h3_hex']"), isTrue);
      });
    });
  });
}
