import 'package:flutter/foundation.dart';

import '../../src/data/services/badge_service.dart';

/// Immutable snapshot of one player's activity for a single ISO week.
///
/// Built by [buildRecapSummary] from already-fetched primitives so the
/// derivation logic stays pure (no Supabase / SharedPreferences calls)
/// and is fully covered by unit tests.  The data loader
/// ([RecapDataLoader.loadCurrentRecap]) is the integration seam that
/// pulls the primitives.
///
/// Phase 1.5, build +21.  Recap is gated by
/// `FeatureFlags.weeklyRecapEnabled` and ships OFF; the flag flip
/// requires >= 2 weeks of per-tester capture history per discipline
/// rule (empty recap = bad first impression).
@immutable
class RecapSummary {
  const RecapSummary({
    required this.weekStart,
    required this.weekEnd,
    required this.hexesCapturedThisWeek,
    required this.daysActiveThisWeek,
    required this.currentStreakDays,
    required this.newBadgesThisWeek,
  });

  /// Monday of the recapped week, midnight UTC.
  final DateTime weekStart;

  /// Sunday of the recapped week, midnight UTC.  INCLUSIVE — the
  /// awarded period ends at end-of-day on this date.
  final DateTime weekEnd;

  /// Number of NEW captures (h3 events) the player made in this week.
  /// Counts each capture event once, even if the same hex was reclaimed
  /// multiple times.
  final int hexesCapturedThisWeek;

  /// Distinct calendar days (UTC) on which the player captured at least
  /// one hex.  0..7.
  final int daysActiveThisWeek;

  /// Player's current streak as of the end of the week.  Surfaced even
  /// when 0 so the UI can show a "build a streak" CTA — but the recap
  /// itself is still suppressed if there is no other content.
  final int currentStreakDays;

  /// Badges whose `awardedAt` falls inside this week's window.  May be
  /// empty.  Almost always 0..2 entries (weekly + monthly cron rarely
  /// fire in the same window).
  final List<PeriodicBadge> newBadgesThisWeek;

  /// True iff the recap has anything worth showing the player.
  ///
  /// EMPTY-STATE GUARD (per discipline rule):
  ///   * if the player captured nothing this week AND
  ///   * earned no badges this week
  /// then we MUST NOT push a recap.  An "you captured 0 hexes" message
  /// is a guaranteed unsubscribe; better to stay quiet.
  ///
  /// Note we do NOT count `currentStreakDays > 0` as content.  A
  /// passive streak built last week with no activity this week is not
  /// recap-worthy on its own.
  bool get hasContent =>
      hexesCapturedThisWeek > 0 || newBadgesThisWeek.isNotEmpty;
}

/// Pure builder.  Caller supplies pre-fetched primitives; this helper
/// performs no I/O and is fully unit-testable.
RecapSummary buildRecapSummary({
  required DateTime weekStart,
  required DateTime weekEnd,
  required int hexesCapturedThisWeek,
  required int daysActiveThisWeek,
  required int currentStreakDays,
  required Iterable<PeriodicBadge> newBadgesThisWeek,
}) {
  // Defensive clamps — never trust upstream maths.  Negative counts
  // would render as garbage in the UI; a corrupted source (e.g. a
  // truncated SharedPreferences value) should degrade quietly.
  final hexes = hexesCapturedThisWeek < 0 ? 0 : hexesCapturedThisWeek;
  final days = switch (daysActiveThisWeek) {
    < 0 => 0,
    > 7 => 7,
    _ => daysActiveThisWeek,
  };
  final streak = currentStreakDays < 0 ? 0 : currentStreakDays;
  return RecapSummary(
    weekStart: weekStart,
    weekEnd: weekEnd,
    hexesCapturedThisWeek: hexes,
    daysActiveThisWeek: days,
    currentStreakDays: streak,
    newBadgesThisWeek: List.unmodifiable(newBadgesThisWeek),
  );
}

/// Returns the subset of [allBadges] whose `awardedAt` falls within
/// the inclusive `[weekStart, weekEnd + 1 day)` UTC window.
///
/// Pure helper.  Exposed as a top-level function so the recap loader
/// and unit tests can call it without instantiating a class.
List<PeriodicBadge> selectBadgesAwardedInWeek({
  required Iterable<PeriodicBadge> allBadges,
  required DateTime weekStart,
  required DateTime weekEnd,
}) {
  // weekEnd is the inclusive Sunday at 00:00 UTC; the actual cutoff
  // is the start of Monday so badges awarded by the Sunday-night cron
  // (Sun 23:00 UTC) land in the right week.
  final cutoff = DateTime.utc(
    weekEnd.year,
    weekEnd.month,
    weekEnd.day,
  ).add(const Duration(days: 1));
  final start = DateTime.utc(weekStart.year, weekStart.month, weekStart.day);
  final result = <PeriodicBadge>[];
  for (final b in allBadges) {
    final t = b.awardedAt.toUtc();
    if (t.isBefore(start)) continue;
    if (!t.isBefore(cutoff)) continue;
    result.add(b);
  }
  return result;
}

/// Returns the Monday (00:00 UTC) of the ISO week containing [d].
/// Pure utility used by both the loader and unit tests.
DateTime mondayOfIsoWeek(DateTime d) {
  final utc = d.toUtc();
  final dow = utc.weekday; // 1..7, Mon..Sun
  final monday = DateTime.utc(utc.year, utc.month, utc.day)
      .subtract(Duration(days: dow - 1));
  return monday;
}

/// Returns the Sunday (00:00 UTC) of the ISO week containing [d].
DateTime sundayOfIsoWeek(DateTime d) {
  return mondayOfIsoWeek(d).add(const Duration(days: 6));
}
