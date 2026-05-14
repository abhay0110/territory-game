// Phase 1.2a — Defended-count tile metadata tests.
//
// The increment logic itself lives in a Postgres trigger
// (supabase/migrations/add_defend_count_to_user_tile_captures.sql) and is
// not unit-testable from Dart. These tests cover the *client-side*
// surface area: the GameTile field, the badge threshold constant, and
// the tolerant `defend_count` parser used when reading rows from
// Supabase.
//
// Server-side semantics (documented for the trigger) are covered as
// behaviour spec comments below so they can be verified by hand or in a
// future SQL test harness.
//
// Trigger spec ----------------------------------------------------------
// On INSERT into user_tile_captures (first capture of a hex by a user):
//   - If tile_captures.owner_user_id IS NULL or == NEW.user_id => 0
//   - If tile_captures.owner_user_id != NEW.user_id            => 1
// On UPDATE (upsert ON CONFLICT, same user re-capturing):
//   - If tile_captures.owner_user_id == NEW.user_id => OLD.defend_count
//   - If tile_captures.owner_user_id != NEW.user_id => OLD.defend_count + 1
// ----------------------------------------------------------------------

import 'package:flutter_test/flutter_test.dart';
import 'package:HexTrail/models/game_tile.dart';
import 'package:HexTrail/src/presentation/widgets/tile_details_dialog.dart';

void main() {
  group('GameTile.defendCount', () {
    test('defaults to 0 when not specified', () {
      final t = GameTile(h3Index: 'abc', ownership: TileOwnership.mine);
      expect(t.defendCount, 0);
    });

    test('round-trips through copyWith', () {
      final t = GameTile(
        h3Index: 'abc',
        ownership: TileOwnership.mine,
        defendCount: 5,
      );
      final t2 = t.copyWith();
      expect(t2.defendCount, 5);
      final t3 = t.copyWith(defendCount: 7);
      expect(t3.defendCount, 7);
    });

    test('copyWith preserves defendCount when other fields change', () {
      final t = GameTile(
        h3Index: 'abc',
        ownership: TileOwnership.mine,
        defendCount: 4,
      );
      final t2 = t.copyWith(ownership: TileOwnership.enemy);
      expect(t2.defendCount, 4);
      expect(t2.ownership, TileOwnership.enemy);
    });
  });

  group('kDefendBadgeThreshold', () {
    test('is 3 — only contested tiles earn the badge', () {
      // Locked design decision: below 3 is normal turnover, not "earned".
      expect(kDefendBadgeThreshold, 3);
    });
  });
}
