import 'package:flutter_test/flutter_test.dart';
import 'package:HexTrail/models/game_tile.dart';
import 'package:HexTrail/src/data/services/map_render_service.dart';

GameTile _tile(String hex, int defend, {TileOwnership own = TileOwnership.mine}) {
  return GameTile(
    h3Index: hex,
    ownership: own,
    defendCount: defend,
  );
}

void main() {
  group('selectDefendBadges — threshold filter', () {
    test('empty input => empty map', () {
      expect(selectDefendBadges(tiles: const []), isEmpty);
    });

    test('all tiles below default threshold (3) => empty map', () {
      final result = selectDefendBadges(
        tiles: [_tile('aa', 0), _tile('bb', 1), _tile('cc', 2)],
      );
      expect(result, isEmpty);
    });

    test('tile at exactly threshold (defendCount == 3) => included', () {
      final result = selectDefendBadges(tiles: [_tile('aa', 3)]);
      expect(result, equals({'aa': 3}));
    });

    test('mixed below/above threshold keeps only qualifiers', () {
      final result = selectDefendBadges(
        tiles: [
          _tile('aa', 1),
          _tile('bb', 4),
          _tile('cc', 2),
          _tile('dd', 7),
        ],
      );
      expect(result, equals({'bb': 4, 'dd': 7}));
    });

    test('custom threshold parameter is honored', () {
      // Allows callers to demand a higher bar (e.g. >=5 for a different
      // accent style) without forking the helper.
      final result = selectDefendBadges(
        tiles: [_tile('aa', 3), _tile('bb', 5)],
        threshold: 5,
      );
      expect(result, equals({'bb': 5}));
    });
  });

  group('selectDefendBadges — visibility filter', () {
    test('null visibleHexes includes every qualifier', () {
      final result = selectDefendBadges(
        tiles: [_tile('aa', 4), _tile('bb', 5)],
        visibleHexes: null,
      );
      expect(result, equals({'aa': 4, 'bb': 5}));
    });

    test('explicit visibleHexes filters out non-rendered tiles', () {
      // Off-screen badges would waste annotation slots; the helper
      // mirrors the renderer's distance-gated visibility.
      final result = selectDefendBadges(
        tiles: [_tile('aa', 4), _tile('bb', 5), _tile('cc', 6)],
        visibleHexes: {'aa', 'cc'},
      );
      expect(result, equals({'aa': 4, 'cc': 6}));
    });

    test('empty visibleHexes => empty result (nothing on-screen)', () {
      final result = selectDefendBadges(
        tiles: [_tile('aa', 4)],
        visibleHexes: <String>{},
      );
      expect(result, isEmpty);
    });
  });

  group('selectDefendBadges — hex normalization & edge cases', () {
    test('h3 indices lowercased on output', () {
      // Matches the convention used by every other Set<String> hex
      // collection in MapRenderService.
      final result = selectDefendBadges(tiles: [_tile('AA', 4)]);
      expect(result, equals({'aa': 4}));
    });

    test('visibleHexes match is case-sensitive on lowercase form', () {
      final result = selectDefendBadges(
        tiles: [_tile('AA', 4)],
        visibleHexes: {'aa'},
      );
      expect(result, equals({'aa': 4}));
    });

    test('empty h3 index is dropped (defensive — never seen in prod)', () {
      final result = selectDefendBadges(tiles: [_tile('', 5)]);
      expect(result, isEmpty);
    });

    test('duplicate h3 keeps the LAST occurrence', () {
      // Mirrors the by-hex Map collapse used by the visibility helper
      // (later list entries win).  Documents the behavior so a future
      // refactor that flips the order changes a test, not production.
      final result = selectDefendBadges(
        tiles: [_tile('aa', 3), _tile('aa', 9)],
      );
      expect(result, equals({'aa': 9}));
    });

    test(
        'badges are independent of TileOwnership '
        '(enemy-owned tiles can show defend count too)', () {
      // The defend count is the OWNER\'s reclaim history.  We surface it
      // for both your tiles and rival tiles so the player can see "this
      // one is hard to take".
      final result = selectDefendBadges(tiles: [
        _tile('aa', 4, own: TileOwnership.mine),
        _tile('bb', 4, own: TileOwnership.enemy),
        _tile('cc', 4, own: TileOwnership.neutral),
      ]);
      expect(result, equals({'aa': 4, 'bb': 4, 'cc': 4}));
    });
  });
}
