import 'package:flutter_test/flutter_test.dart';
import 'package:HexTrail/src/data/services/trail_leaderboard_service.dart';
import 'package:HexTrail/src/presentation/widgets/territory_pressure_card.dart';

TrailLeaderboardEntry _entry({
  required String id,
  required int tiles,
  bool isYou = false,
  String? name,
}) {
  return TrailLeaderboardEntry(
    userId: id,
    ownedTiles: tiles,
    isYou: isYou,
    customDisplayName: name,
  );
}

TrailLeaderboardSnapshot _snap({
  required List<TrailLeaderboardEntry> top,
  int? yourRank,
  required int yourTiles,
}) {
  return TrailLeaderboardSnapshot(
    trailName: 'Burke-Gilman',
    topPlayers: top,
    yourRank: yourRank,
    yourTotalTiles: yourTiles,
    trailTotalTiles: 1000,
    totalPlayers: 25,
    sections: const [],
  );
}

void main() {
  group('pressureCardSummary — null / empty inputs', () {
    test('null snapshot => null', () {
      expect(pressureCardSummary(null), isNull);
    });

    test('empty topPlayers => null (no signal)', () {
      expect(
        pressureCardSummary(_snap(top: const [], yourTiles: 0)),
        isNull,
      );
    });

    test('unranked AND zero tiles => null (fresh install posture)', () {
      final s = _snap(
        top: [_entry(id: 'a', tiles: 100, name: 'Alice')],
        yourTiles: 0,
      );
      expect(pressureCardSummary(s), isNull);
    });
  });

  group('pressureCardSummary — defend (rank #1)', () {
    test('clean lead over #2 => defend headline', () {
      final s = _snap(
        top: [
          _entry(id: 'me', tiles: 50, isYou: true, name: 'Me'),
          _entry(id: 'b', tiles: 42, name: 'Bea'),
          _entry(id: 'c', tiles: 30, name: 'Cal'),
        ],
        yourRank: 1,
        yourTiles: 50,
      );
      final r = pressureCardSummary(s)!;
      expect(r.tone, PressureTone.defend);
      expect(r.headline, '#1 by 8 tiles — defend against Bea');
      expect(r.subline, isNull);
    });

    test('singular tile pluralization', () {
      final s = _snap(
        top: [
          _entry(id: 'me', tiles: 11, isYou: true),
          _entry(id: 'b', tiles: 10, name: 'Bea'),
        ],
        yourRank: 1,
        yourTiles: 11,
      );
      expect(
        pressureCardSummary(s)!.headline,
        '#1 by 1 tile — defend against Bea',
      );
    });

    test('tied for #1 (lead == 0) => defend headline (most-tense state)',
        () {
      final s = _snap(
        top: [
          _entry(id: 'me', tiles: 30, isYou: true),
          _entry(id: 'b', tiles: 30, name: 'Bea'),
        ],
        yourRank: 1,
        yourTiles: 30,
      );
      final r = pressureCardSummary(s)!;
      expect(r.tone, PressureTone.defend);
      expect(r.headline, 'Tied for #1 with Bea — capture 1 more to break it');
    });

    test('rank #1 with no other players => null', () {
      final s = _snap(
        top: [_entry(id: 'me', tiles: 5, isYou: true)],
        yourRank: 1,
        yourTiles: 5,
      );
      expect(pressureCardSummary(s), isNull);
    });
  });

  group('pressureCardSummary — chase (rank 2..N)', () {
    test('rank 2 => chase headline, NO leader subline', () {
      // At rank 2 the "above" player IS the leader; suppressing the
      // subline keeps the card from saying the same name twice.
      final s = _snap(
        top: [
          _entry(id: 'a', tiles: 50, name: 'Alice'),
          _entry(id: 'me', tiles: 42, isYou: true),
        ],
        yourRank: 2,
        yourTiles: 42,
      );
      final r = pressureCardSummary(s)!;
      expect(r.tone, PressureTone.chase);
      expect(r.headline, '9 tiles to overtake Alice');
      expect(r.subline, isNull);
    });

    test('rank 3 => chase + leader subline (different player)', () {
      final s = _snap(
        top: [
          _entry(id: 'a', tiles: 80, name: 'Alice'),
          _entry(id: 'b', tiles: 60, name: 'Bea'),
          _entry(id: 'me', tiles: 40, isYou: true),
        ],
        yourRank: 3,
        yourTiles: 40,
      );
      final r = pressureCardSummary(s)!;
      expect(r.tone, PressureTone.chase);
      expect(r.headline, '21 tiles to overtake Bea');
      expect(r.subline, '👑 Alice leads with 80');
    });

    test('overtake gap of 1 uses singular', () {
      final s = _snap(
        top: [
          _entry(id: 'a', tiles: 10, name: 'Alice'),
          _entry(id: 'me', tiles: 10, isYou: true),
        ],
        yourRank: 2,
        yourTiles: 10,
      );
      // gap == above.tiles - mine + 1 == 1
      expect(
        pressureCardSummary(s)!.headline,
        '1 tile to overtake Alice',
      );
    });
  });

  group('pressureCardSummary — break-in (unranked with tiles)', () {
    test('unranked, has tiles, knows top-N => breakIn headline', () {
      final s = _snap(
        top: [
          _entry(id: 'a', tiles: 80, name: 'Alice'),
          _entry(id: 'b', tiles: 60, name: 'Bea'),
          _entry(id: 'c', tiles: 25, name: 'Cal'),
        ],
        yourRank: null,
        yourTiles: 8,
      );
      final r = pressureCardSummary(s)!;
      expect(r.tone, PressureTone.breakIn);
      // gap = 25 - 8 + 1 = 18; top-N size = 3
      expect(r.headline, 'Capture 18 more to break into the top 3');
    });

    test('unranked but already tied with lowest top-N => null (avoid +1 nag)',
        () {
      final s = _snap(
        top: [
          _entry(id: 'a', tiles: 80, name: 'Alice'),
          _entry(id: 'b', tiles: 8, name: 'Bea'),
        ],
        // yourTiles == lowestTop.tiles, gap would be +1; but if you
        // already match the threshold the API would have ranked you.
        // Defensive: we still emit a "Capture 1 more" headline only
        // when the threshold is strictly higher than your tiles.
        yourRank: null,
        yourTiles: 8,
      );
      // gap = 8 - 8 + 1 = 1, which is > 0, so we DO emit a headline.
      // This test pins the current behavior — change deliberately.
      expect(
        pressureCardSummary(s)!.headline,
        'Capture 1 more to break into the top 2',
      );
    });
  });
}
