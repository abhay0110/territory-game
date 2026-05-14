import 'package:flutter_test/flutter_test.dart';
import 'package:HexTrail/features/recap/recap_summary.dart';
import 'package:HexTrail/src/data/services/badge_service.dart';

PeriodicBadge _badge({
  String key = 'weekly_top3:burke_gilman:2026-W19',
  String type = 'weekly_top3',
  String trail = 'burke_gilman',
  String periodStart = '2026-05-04',
  String periodEnd = '2026-05-10',
  int rank = 1,
  int owned = 12,
  required String awardedAt,
}) {
  return PeriodicBadge.fromRow(<String, dynamic>{
    'badge_key': key,
    'badge_type': type,
    'trail_id': trail,
    'period_start': periodStart,
    'period_end': periodEnd,
    'rank': rank,
    'owned_tiles': owned,
    'awarded_at': awardedAt,
  });
}

void main() {
  // Reference week: 2026-W19  →  Mon 2026-05-04 .. Sun 2026-05-10 UTC.
  final weekStart = DateTime.utc(2026, 5, 4);
  final weekEnd = DateTime.utc(2026, 5, 10);

  group('mondayOfIsoWeek / sundayOfIsoWeek', () {
    test('returns Monday for a Wednesday inside the week', () {
      // 2026-05-06 is a Wednesday.
      final ref = DateTime.utc(2026, 5, 6, 12, 30);
      expect(mondayOfIsoWeek(ref), weekStart);
      expect(sundayOfIsoWeek(ref), weekEnd);
    });

    test('returns same Monday when input IS the Monday', () {
      expect(mondayOfIsoWeek(weekStart), weekStart);
    });

    test('returns previous Monday when input IS the Sunday', () {
      // Sunday belongs to the same ISO week as the prior Monday.
      expect(mondayOfIsoWeek(weekEnd), weekStart);
    });

    test('handles non-UTC input by normalizing', () {
      // Caller may hand us a local-time DateTime; helper must
      // normalize to UTC before computing.
      final ref = DateTime(2026, 5, 6, 12, 30); // local
      final monday = mondayOfIsoWeek(ref);
      expect(monday.isUtc, isTrue);
      // Could be the same week or one off depending on tz; just
      // assert it's a Monday at midnight UTC.
      expect(monday.weekday, 1);
      expect(monday.hour, 0);
      expect(monday.minute, 0);
    });
  });

  group('buildRecapSummary — pure derivation', () {
    test('passes through positive values unchanged', () {
      final s = buildRecapSummary(
        weekStart: weekStart,
        weekEnd: weekEnd,
        hexesCapturedThisWeek: 17,
        daysActiveThisWeek: 5,
        currentStreakDays: 9,
        newBadgesThisWeek: const [],
      );
      expect(s.hexesCapturedThisWeek, 17);
      expect(s.daysActiveThisWeek, 5);
      expect(s.currentStreakDays, 9);
      expect(s.newBadgesThisWeek, isEmpty);
    });

    test('clamps negative inputs to 0 (defensive)', () {
      // Corrupted upstream (e.g. truncated SharedPreferences) must
      // degrade silently — never render "−1 hexes" in the UI.
      final s = buildRecapSummary(
        weekStart: weekStart,
        weekEnd: weekEnd,
        hexesCapturedThisWeek: -3,
        daysActiveThisWeek: -1,
        currentStreakDays: -5,
        newBadgesThisWeek: const [],
      );
      expect(s.hexesCapturedThisWeek, 0);
      expect(s.daysActiveThisWeek, 0);
      expect(s.currentStreakDays, 0);
    });

    test('caps daysActiveThisWeek at 7 (max in any ISO week)', () {
      // A bug that emitted 8 distinct days would render visibly broken;
      // clamp upstream so the UI cannot crash.
      final s = buildRecapSummary(
        weekStart: weekStart,
        weekEnd: weekEnd,
        hexesCapturedThisWeek: 1,
        daysActiveThisWeek: 99,
        currentStreakDays: 0,
        newBadgesThisWeek: const [],
      );
      expect(s.daysActiveThisWeek, 7);
    });

    test('newBadgesThisWeek is unmodifiable (defensive)', () {
      final mutable = <PeriodicBadge>[];
      final s = buildRecapSummary(
        weekStart: weekStart,
        weekEnd: weekEnd,
        hexesCapturedThisWeek: 1,
        daysActiveThisWeek: 1,
        currentStreakDays: 1,
        newBadgesThisWeek: mutable,
      );
      expect(() => s.newBadgesThisWeek.add(_badge(awardedAt: '2026-05-10T00:00:00Z')),
          throwsUnsupportedError);
    });
  });

  group('RecapSummary.hasContent — empty-state guard', () {
    test('zero hexes + no badges => no content (do not push)', () {
      final s = buildRecapSummary(
        weekStart: weekStart,
        weekEnd: weekEnd,
        hexesCapturedThisWeek: 0,
        daysActiveThisWeek: 0,
        currentStreakDays: 0,
        newBadgesThisWeek: const [],
      );
      expect(s.hasContent, isFalse,
          reason: 'Pushing "0 hexes" recaps is a guaranteed unsubscribe.');
    });

    test('zero hexes + no badges + active streak => STILL no content', () {
      // Discipline: a streak built last week with no captures this week
      // does NOT make the recap worth sending.  We never want a recap
      // that says "you did nothing but you have a streak".
      final s = buildRecapSummary(
        weekStart: weekStart,
        weekEnd: weekEnd,
        hexesCapturedThisWeek: 0,
        daysActiveThisWeek: 0,
        currentStreakDays: 14,
        newBadgesThisWeek: const [],
      );
      expect(s.hasContent, isFalse);
    });

    test('one hex captured => has content', () {
      final s = buildRecapSummary(
        weekStart: weekStart,
        weekEnd: weekEnd,
        hexesCapturedThisWeek: 1,
        daysActiveThisWeek: 1,
        currentStreakDays: 0,
        newBadgesThisWeek: const [],
      );
      expect(s.hasContent, isTrue);
    });

    test('zero hexes but a badge awarded => has content', () {
      // Edge case: tester earned a "Top 3" badge from prior weeks'
      // captures that landed during this recap window; recap is worth
      // sending even with 0 new captures because the achievement is
      // the headline.
      final s = buildRecapSummary(
        weekStart: weekStart,
        weekEnd: weekEnd,
        hexesCapturedThisWeek: 0,
        daysActiveThisWeek: 0,
        currentStreakDays: 0,
        newBadgesThisWeek: [_badge(awardedAt: '2026-05-10T23:00:00Z')],
      );
      expect(s.hasContent, isTrue);
    });
  });

  group('selectBadgesAwardedInWeek', () {
    test('includes badge awarded at the start-of-Monday boundary', () {
      final inWindow = _badge(awardedAt: '2026-05-04T00:00:00Z');
      final result = selectBadgesAwardedInWeek(
        allBadges: [inWindow],
        weekStart: weekStart,
        weekEnd: weekEnd,
      );
      expect(result, [inWindow]);
    });

    test('includes badge awarded at the late-Sunday cron run', () {
      // Weekly cron fires at Sun 23:00 UTC; the badge it inserts must
      // be classified as belonging to THIS week, not next.
      final lateSunday = _badge(awardedAt: '2026-05-10T23:00:00Z');
      final result = selectBadgesAwardedInWeek(
        allBadges: [lateSunday],
        weekStart: weekStart,
        weekEnd: weekEnd,
      );
      expect(result, [lateSunday]);
    });

    test('excludes badge awarded the next Monday at 00:00:00 UTC', () {
      final nextMonday = _badge(
        key: 'weekly_top3:burke_gilman:2026-W20',
        awardedAt: '2026-05-11T00:00:00Z',
      );
      final result = selectBadgesAwardedInWeek(
        allBadges: [nextMonday],
        weekStart: weekStart,
        weekEnd: weekEnd,
      );
      expect(result, isEmpty);
    });

    test('excludes badge awarded the previous Sunday at 23:59 UTC', () {
      final prevSunday = _badge(
        key: 'weekly_top3:burke_gilman:2026-W18',
        awardedAt: '2026-05-03T23:59:59Z',
      );
      final result = selectBadgesAwardedInWeek(
        allBadges: [prevSunday],
        weekStart: weekStart,
        weekEnd: weekEnd,
      );
      expect(result, isEmpty);
    });

    test('mixed list keeps only in-window entries', () {
      final inA = _badge(awardedAt: '2026-05-05T12:00:00Z');
      final inB = _badge(
        key: 'monthly_top3:burke_gilman:2026-04',
        type: 'monthly_top3',
        awardedAt: '2026-05-10T23:00:00Z',
      );
      final out = _badge(
        key: 'monthly_top3:burke_gilman:2026-03',
        awardedAt: '2026-04-30T23:00:00Z',
      );
      final result = selectBadgesAwardedInWeek(
        allBadges: [inA, out, inB],
        weekStart: weekStart,
        weekEnd: weekEnd,
      );
      expect(result, [inA, inB]);
    });
  });
}
