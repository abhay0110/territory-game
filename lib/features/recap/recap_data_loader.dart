import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../src/data/services/badge_service.dart';
import '../../src/data/services/streak_service.dart';
import 'recap_summary.dart';

/// Pulls the primitives [buildRecapSummary] needs from Supabase + the
/// existing local services.  Kept thin and effects-only so the
/// pure derivation in [recap_summary.dart] is what we test.
///
/// Phase 1.5, build +21.
class RecapDataLoader {
  RecapDataLoader({
    SupabaseClient? client,
    StreakService? streakService,
    BadgeService? badgeService,
  })  : _client = client ?? Supabase.instance.client,
        _streakService = streakService ?? StreakService(),
        _badgeService = badgeService ?? BadgeService();

  final SupabaseClient _client;
  final StreakService _streakService;
  final BadgeService _badgeService;

  /// Loads the recap for the most-recently-completed ISO week (the
  /// week that ENDED before today's UTC date).  Returns `null` if:
  ///   * no signed-in session, or
  ///   * the resulting summary has no content (see [RecapSummary.hasContent]).
  ///
  /// The empty-content suppression lives here, NOT in the screen, so
  /// the FCM-tap handler can short-circuit before navigation.
  Future<RecapSummary?> loadCurrentRecap({DateTime? now}) async {
    final uid = _client.auth.currentUser?.id;
    if (uid == null) return null;

    final reference = (now ?? DateTime.now().toUtc())
        .toUtc()
        .subtract(const Duration(days: 1));
    final weekStart = mondayOfIsoWeek(reference);
    final weekEnd = sundayOfIsoWeek(reference);
    final cutoff = weekEnd.add(const Duration(days: 1));

    int hexes = 0;
    final activeDays = <String>{};
    try {
      final rows = await _client
          .from('user_tile_captures')
          .select('captured_at')
          .eq('user_id', uid)
          .gte('captured_at', weekStart.toIso8601String())
          .lt('captured_at', cutoff.toIso8601String());
      for (final row in rows) {
        final raw = (row as Map)['captured_at'];
        if (raw is! String) continue;
        final dt = DateTime.tryParse(raw)?.toUtc();
        if (dt == null) continue;
        hexes += 1;
        activeDays.add(
          '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}',
        );
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[Recap] capture fetch failed: $e');
      // Continue with hexes=0; downstream hasContent will likely
      // suppress the recap (degrading silently is the right call —
      // a transient REST failure must not deliver a wrong-number push).
    }

    StreakState? streak;
    try {
      streak = await _streakService.readCurrentState();
    } catch (_) {
      streak = null;
    }

    List<PeriodicBadge> allBadges = const [];
    try {
      allBadges = await _badgeService.fetchMine();
    } catch (_) {
      allBadges = const [];
    }

    final summary = buildRecapSummary(
      weekStart: weekStart,
      weekEnd: weekEnd,
      hexesCapturedThisWeek: hexes,
      daysActiveThisWeek: activeDays.length,
      currentStreakDays: streak?.currentStreak ?? 0,
      newBadgesThisWeek: selectBadgesAwardedInWeek(
        allBadges: allBadges,
        weekStart: weekStart,
        weekEnd: weekEnd,
      ),
    );

    return summary.hasContent ? summary : null;
  }
}
