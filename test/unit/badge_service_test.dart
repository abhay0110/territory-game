import 'package:flutter_test/flutter_test.dart';
import 'package:HexTrail/src/data/services/badge_service.dart';

Map<String, dynamic> _row({
  String key = 'monthly_top3:burke_gilman:2026-03',
  String type = 'monthly_top3',
  String trail = 'burke_gilman',
  String periodStart = '2026-03-01',
  String periodEnd = '2026-03-31',
  int rank = 3,
  int owned = 12,
  String awardedAt = '2026-04-01T00:00:00Z',
}) {
  return <String, dynamic>{
    'badge_key': key,
    'badge_type': type,
    'trail_id': trail,
    'period_start': periodStart,
    'period_end': periodEnd,
    'rank': rank,
    'owned_tiles': owned,
    'awarded_at': awardedAt,
  };
}

void main() {
  group('PeriodicBadge.fromRow', () {
    test('parses every field of a monthly badge', () {
      final b = PeriodicBadge.fromRow(_row());
      expect(b.badgeKey, 'monthly_top3:burke_gilman:2026-03');
      expect(b.badgeType, 'monthly_top3');
      expect(b.trailId, 'burke_gilman');
      expect(b.periodStart, DateTime.parse('2026-03-01'));
      expect(b.periodEnd, DateTime.parse('2026-03-31'));
      expect(b.rank, 3);
      expect(b.ownedTiles, 12);
      expect(b.awardedAt.toUtc(), DateTime.parse('2026-04-01T00:00:00Z'));
    });

    test('accepts num for rank/owned (Supabase int8 round-trip)', () {
      // Supabase JSON sometimes hands back integers as `int`, sometimes
      // wrapped in a num; the parser must accept either without crashing.
      final b = PeriodicBadge.fromRow(_row(rank: 1, owned: 9999));
      expect(b.rank, 1);
      expect(b.ownedTiles, 9999);
    });
  });

  group('PeriodicBadge.label — monthly', () {
    test('formats month name + year', () {
      final b = PeriodicBadge.fromRow(_row(
        key: 'monthly_top3:burke_gilman:2026-03',
        type: 'monthly_top3',
        periodStart: '2026-03-01',
        periodEnd: '2026-03-31',
        rank: 3,
      ));
      expect(b.label, 'Top 3 — Burke-Gilman — March 2026');
    });

    test('rank-1 monthly reads cleanly', () {
      final b = PeriodicBadge.fromRow(_row(
        key: 'monthly_top3:burke_gilman:2026-01',
        periodStart: '2026-01-01',
        periodEnd: '2026-01-31',
        rank: 1,
      ));
      expect(b.label, 'Top 3 — Burke-Gilman — January 2026');
    });
  });

  group('PeriodicBadge.label — weekly', () {
    test('formats "Week of <Mon Day, Year>"', () {
      // 2026-W19 monday = 2026-05-04
      final b = PeriodicBadge.fromRow(_row(
        key: 'weekly_top3:burke_gilman:2026-W19',
        type: 'weekly_top3',
        periodStart: '2026-05-04',
        periodEnd: '2026-05-10',
        rank: 2,
      ));
      expect(b.label, 'Top 3 — Burke-Gilman — Week of May 4, 2026');
    });
  });

  group('PeriodicBadge.label — defensive paths', () {
    test('unknown trail_id falls back to the raw id (no crash)', () {
      final b = PeriodicBadge.fromRow(_row(
        trail: 'mystery_trail_xyz',
      ));
      expect(b.label, contains('mystery_trail_xyz'));
    });

    test('unknown badge_type without numeric suffix defaults to top-3', () {
      // Future-proofing: if the awarder ever ships a "weekly_special"
      // type with no numeric, the label still reads.
      final b = PeriodicBadge.fromRow(_row(
        type: 'weekly_special',
      ));
      expect(b.label, startsWith('Top 3 —'));
    });

    test('top5 badge_type extracts rank size correctly', () {
      // The Edge Function caps at top-3 today, but the parser must not
      // hard-code that.  A future bump to top-5 should not require a
      // client redeploy to render correctly.
      final b = PeriodicBadge.fromRow(_row(
        type: 'monthly_top5',
        rank: 5,
      ));
      expect(b.label, startsWith('Top 5 —'));
    });
  });

  group('PeriodicBadge equality', () {
    test('two badges with the same badgeKey are ==', () {
      final a = PeriodicBadge.fromRow(_row());
      final b = PeriodicBadge.fromRow(_row(owned: 999));
      // Different owned_tiles snapshot but same PK → same identity.
      // Useful so a re-fetch dedup via Set<PeriodicBadge> works.
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('different badgeKey => !=', () {
      final a = PeriodicBadge.fromRow(_row());
      final b = PeriodicBadge.fromRow(_row(
        key: 'monthly_top3:burke_gilman:2026-04',
      ));
      expect(a, isNot(equals(b)));
    });
  });
}
