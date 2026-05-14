import 'package:flutter_test/flutter_test.dart';
import 'package:HexTrail/src/services/notification_service.dart';

void main() {
  group('NotificationService.parseRecapPayload', () {
    test('valid payload => returns recapId', () {
      final r = NotificationService.parseRecapPayload(<String, dynamic>{
        'event': 'weekly_recap',
        'recapId': '2026-W19',
      });
      expect(r, '2026-W19');
    });

    test('extra keys are ignored (forward-compat)', () {
      // Server may add fields later (e.g. tz hint, deeplink override).
      // Parser must keep working — we only need event + recapId.
      final r = NotificationService.parseRecapPayload(<String, dynamic>{
        'event': 'weekly_recap',
        'recapId': '2026-W19',
        'tz': 'America/Los_Angeles',
        'deeplink_v2': '/recap?w=19',
      });
      expect(r, '2026-W19');
    });

    test('wrong event => null (does not collide with tile_lost)', () {
      final r = NotificationService.parseRecapPayload(<String, dynamic>{
        'event': 'tile_lost',
        'recapId': '2026-W19',
      });
      expect(r, isNull);
    });

    test('legacy "type" key NOT accepted (recap is event-only)', () {
      // Unlike tile_lost (which accepts both `event` and legacy
      // `type`), recap is a new event introduced after the standard
      // was settled — no legacy alias to support.  Tighter parser =
      // smaller misroute surface.
      final r = NotificationService.parseRecapPayload(<String, dynamic>{
        'type': 'weekly_recap',
        'recapId': '2026-W19',
      });
      expect(r, isNull);
    });

    test('missing recapId => null', () {
      final r = NotificationService.parseRecapPayload(<String, dynamic>{
        'event': 'weekly_recap',
      });
      expect(r, isNull);
    });

    test('empty recapId => null', () {
      final r = NotificationService.parseRecapPayload(<String, dynamic>{
        'event': 'weekly_recap',
        'recapId': '',
      });
      expect(r, isNull);
    });

    test('absurdly long recapId rejected (>16 chars)', () {
      // Defensive: a malicious / buggy server can\'t flood the
      // notifier with megabyte ids.  16 chars covers `2026-W19` and
      // future `2026-Q1` style ids with headroom.
      final r = NotificationService.parseRecapPayload(<String, dynamic>{
        'event': 'weekly_recap',
        'recapId': 'x' * 100,
      });
      expect(r, isNull);
    });

    test('empty payload => null (no crash)', () {
      expect(
        NotificationService.parseRecapPayload(<String, dynamic>{}),
        isNull,
      );
    });

    test('numeric recapId is coerced to string', () {
      // Some server SDKs serialize int-looking values without quotes;
      // the toString() coercion in the parser keeps things alive.
      final r = NotificationService.parseRecapPayload(<String, dynamic>{
        'event': 'weekly_recap',
        'recapId': 202619,
      });
      expect(r, '202619');
    });
  });

  group('NotificationService.parseTileLostPayload — regression guard', () {
    // Quick sanity check that the +21 changes didn\'t break tile_lost.
    test('still parses canonical tile_lost', () {
      final r = NotificationService.parseTileLostPayload(<String, dynamic>{
        'event': 'tile_lost',
        'hexId': '8a2a1072b59ffff',
      });
      expect(r, '8a2a1072b59ffff');
    });

    test('weekly_recap event => null (correct dispatch isolation)', () {
      // The Phase 1.5 wiring runs BOTH parsers on the same payload.
      // Confirm a weekly_recap payload does not accidentally satisfy
      // the tile_lost parser.
      final r = NotificationService.parseTileLostPayload(<String, dynamic>{
        'event': 'weekly_recap',
        'recapId': '2026-W19',
      });
      expect(r, isNull);
    });
  });
}
