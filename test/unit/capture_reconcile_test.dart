// Pure-logic tests for CaptureService.reconcileCapturedHexes.
//
// These directly target the static reconciliation function so we can
// exhaustively cover the conservative semantics without booting Supabase
// or shared_preferences.  Critically, this suite is the regression net
// for the build-13 corridor-gap bug: the same logic now powers BOTH
// the nearby-ring and corridor-batch paths, so a single suite covers
// both paths by virtue of the function being pure.

import 'package:flutter_test/flutter_test.dart';
import 'package:HexTrail/models/game_tile.dart';
import 'package:HexTrail/src/data/services/capture_service.dart';

void main() {
  const me = 'uid-me';
  const enemy = 'uid-enemy';

  Set<String> setOf(Iterable<String> hexes) =>
      <String>{for (final h in hexes) h.toLowerCase()};

  Map<String, GameTile> tilesOf(Iterable<String> hexes) => {
        for (final h in hexes)
          h.toLowerCase(): GameTile(
            h3Index: h.toLowerCase(),
            ownership: TileOwnership.mine,
            ownerId: me,
          ),
      };

  group('reconcileCapturedHexes — conservative semantics', () {
    test('server reports different owner → prune', () {
      final captured = setOf(['aaa']);
      final tiles = tilesOf(['aaa']);
      final lost = CaptureService.reconcileCapturedHexes(
        capturedHexes: captured,
        capturedTilesByHex: tiles,
        queriedHexes: const ['aaa'],
        serverOwnerByHex: const {'aaa': enemy},
        currentUserId: me,
      );
      expect(lost, ['aaa']);
      expect(captured, isEmpty);
      expect(tiles, isEmpty);
    });

    test('server reports same owner → keep (no-op)', () {
      final captured = setOf(['aaa']);
      final tiles = tilesOf(['aaa']);
      final lost = CaptureService.reconcileCapturedHexes(
        capturedHexes: captured,
        capturedTilesByHex: tiles,
        queriedHexes: const ['aaa'],
        serverOwnerByHex: const {'aaa': me},
        currentUserId: me,
      );
      expect(lost, isEmpty);
      expect(captured, contains('aaa'));
      expect(tiles, contains('aaa'));
    });

    test('hex queried but absent from server map → keep (conservative)', () {
      // Could be a partial fetch or row deleted by admin; do NOT prune.
      final captured = setOf(['aaa']);
      final tiles = tilesOf(['aaa']);
      final lost = CaptureService.reconcileCapturedHexes(
        capturedHexes: captured,
        capturedTilesByHex: tiles,
        queriedHexes: const ['aaa'],
        serverOwnerByHex: const {},
        currentUserId: me,
      );
      expect(lost, isEmpty);
      expect(captured, contains('aaa'));
      expect(tiles, contains('aaa'));
    });

    test('hex NOT in queriedHexes → keep (out-of-scope, never decide)', () {
      // Never act on hexes the caller did not just query — could be stale.
      final captured = setOf(['aaa']);
      final tiles = tilesOf(['aaa']);
      final lost = CaptureService.reconcileCapturedHexes(
        capturedHexes: captured,
        capturedTilesByHex: tiles,
        queriedHexes: const ['bbb'],
        serverOwnerByHex: const {'aaa': enemy}, // says lost — but unscoped
        currentUserId: me,
      );
      expect(lost, isEmpty);
      expect(captured, contains('aaa'));
    });

    test('mixed: prunes only the ones with explicit different owner', () {
      final captured = setOf(['aaa', 'bbb', 'ccc']);
      final tiles = tilesOf(['aaa', 'bbb', 'ccc']);
      final lost = CaptureService.reconcileCapturedHexes(
        capturedHexes: captured,
        capturedTilesByHex: tiles,
        queriedHexes: const ['aaa', 'bbb', 'ccc'],
        serverOwnerByHex: const {
          'aaa': enemy, // lost
          'bbb': me, // still mine
          // ccc absent → conservative keep
        },
        currentUserId: me,
      );
      expect(lost, ['aaa']);
      expect(captured, {'bbb', 'ccc'});
      expect(tiles.keys, containsAll(['bbb', 'ccc']));
    });

    test('case-insensitive hex normalization', () {
      final captured = setOf(['AaA']); // stored lowercase
      final tiles = tilesOf(['AaA']);
      final lost = CaptureService.reconcileCapturedHexes(
        capturedHexes: captured,
        capturedTilesByHex: tiles,
        queriedHexes: const ['AAA'], // mixed-case query
        serverOwnerByHex: const {'aaa': enemy},
        currentUserId: me,
      );
      expect(lost, ['aaa']);
      expect(captured, isEmpty);
    });

    test('empty inputs → no-op', () {
      final captured = <String>{};
      final tiles = <String, GameTile>{};
      final lost = CaptureService.reconcileCapturedHexes(
        capturedHexes: captured,
        capturedTilesByHex: tiles,
        queriedHexes: const [],
        serverOwnerByHex: const {},
        currentUserId: me,
      );
      expect(lost, isEmpty);
    });
  });

  // ── REGRESSION FIXTURES ──────────────────────────────────────────────
  // These encode walk-test bugs that previously shipped. Each test that
  // stays green here means a previously-observed bug cannot silently
  // regress without a test failure.
  group('REGRESSION: walk-test bugs', () {
    test('build-13 corridor gap: trail hex 3mi from user must reconcile', () {
      // Bug: when user is far from corridor, refreshNearbyOwners is empty
      // (no nearby trail hexes) so reconcile never fires.  The corridor
      // batch fetches the trail but didn't reconcile in build 13.
      // Fix: same pure function now wired into BOTH paths — so as long
      // as the batch fetch produces serverOwnerByHex, reconcile prunes.
      final captured = setOf(['trailhex-1', 'trailhex-2']);
      final tiles = tilesOf(['trailhex-1', 'trailhex-2']);
      // Corridor batch sees both hexes; one was taken by enemy.
      final lost = CaptureService.reconcileCapturedHexes(
        capturedHexes: captured,
        capturedTilesByHex: tiles,
        queriedHexes: const ['trailhex-1', 'trailhex-2'],
        serverOwnerByHex: const {
          'trailhex-1': enemy,
          'trailhex-2': me,
        },
        currentUserId: me,
      );
      expect(lost, ['trailhex-1'],
          reason: 'Corridor batch must prune lost trail hexes regardless of '
              'GPS distance from corridor.');
      expect(captured, {'trailhex-2'});
    });

    test('build-13 stuck-green: same-owner refresh never prunes own tiles',
        () {
      // Bug class: paranoid prune logic could falsely remove tiles after
      // a server owner_user_id round-trip.  Guard: never prune when
      // server confirms current ownership.
      final captured = setOf(['mine-1']);
      final tiles = tilesOf(['mine-1']);
      final lost = CaptureService.reconcileCapturedHexes(
        capturedHexes: captured,
        capturedTilesByHex: tiles,
        queriedHexes: const ['mine-1'],
        serverOwnerByHex: const {'mine-1': me},
        currentUserId: me,
      );
      expect(lost, isEmpty);
      expect(captured, contains('mine-1'));
    });
  });
}
