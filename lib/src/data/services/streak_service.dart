import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Daily-capture streak with a weekly auto-credited freeze.
///
/// Phase 1.1 of the post build 14/16 roadmap.  Local-first by design:
/// SharedPreferences only, no Supabase schema, no cron, no FCM.  Streak
/// is computed lazily on read and on every capture.
///
/// Backing data is recorded on every capture regardless of
/// [FeatureFlags.streakSystemEnabled] — so when the UI flag flips on,
/// users with existing capture history see a meaningful streak instead
/// of a fresh zero.
///
/// "Day" semantics:
///  - Local calendar day, NOT UTC, NOT 24-hour rolling window.  A
///    capture at 11pm Mon and 1am Tue counts as a 2-day streak in the
///    user's head; UTC or rolling windows would say "1 day, no streak"
///    which feels broken.
///  - Travel across timezones can in rare cases give a free day or
///    swallow one — accepted, not worth the complexity to solve.
///
/// Freeze semantics:
///  - Exactly 1 freeze auto-credited per ISO week (Mon 00:00 local).
///  - Max 1 banked at a time — if user already has one, the Monday
///    refill is a no-op (no stockpiling).
///  - When [recordCaptureToday] or [readCurrentState] sees a 1-day gap
///    AND a freeze is available, freeze is silently consumed; streak
///    is preserved but does NOT increment (no capture happened).
///  - Caller can detect the consumption via [StreakState.freezeJustConsumed]
///    and surface a one-shot banner ("Streak freeze used — capture
///    today to keep your N-day streak.").
///  - 2+ day gap, even with freeze, resets to 0 / 1.
class StreakService {
  StreakService({SharedPreferences? prefs, DateTime Function()? clock})
      : _prefs = prefs,
        _clock = clock ?? DateTime.now;

  static const _kLastCaptureDate = 'streak.last_capture_date'; // 'YYYY-MM-DD'
  static const _kStreakCount = 'streak.count';
  static const _kFreezesAvailable = 'streak.freezes_available';
  static const _kFreezeWeekAnchor = 'streak.freeze_week_anchor'; // ISO 'YYYY-Www'
  static const _kLongestEver = 'streak.longest_ever';
  static const _kPendingBannerOnce = 'streak.pending_banner_once';

  SharedPreferences? _prefs;
  final DateTime Function() _clock;

  Future<SharedPreferences> _ensure() async {
    return _prefs ??= await SharedPreferences.getInstance();
  }

  /// Read the current streak state, applying any time-based transitions
  /// (freeze refill, freeze consumption, lapse).  Idempotent — calling
  /// twice in the same day produces the same state.
  Future<StreakState> readCurrentState() async {
    final prefs = await _ensure();
    final today = _todayLocal();
    return _applyTransitions(prefs, today, captured: false);
  }

  /// Record that a capture happened "today" (local calendar day).
  /// Bumps streak only on the FIRST capture of a given day; subsequent
  /// same-day captures are no-ops.  Always called from the capture path
  /// regardless of UI flag so the streak count is meaningful when the
  /// flag flips on later.
  Future<StreakState> recordCaptureToday() async {
    final prefs = await _ensure();
    final today = _todayLocal();
    return _applyTransitions(prefs, today, captured: true);
  }

  /// Pop the one-shot "freeze was just consumed" flag.  UI calls this
  /// when it shows the banner so the banner only shows once.
  Future<bool> consumeFreezeBanner() async {
    final prefs = await _ensure();
    final pending = prefs.getBool(_kPendingBannerOnce) ?? false;
    if (pending) {
      await prefs.setBool(_kPendingBannerOnce, false);
    }
    return pending;
  }

  /// Reset all streak state.  Intended for tests and the "delete my
  /// data" account path.  NOT a user-facing action.
  Future<void> resetForTesting() async {
    final prefs = await _ensure();
    await prefs.remove(_kLastCaptureDate);
    await prefs.remove(_kStreakCount);
    await prefs.remove(_kFreezesAvailable);
    await prefs.remove(_kFreezeWeekAnchor);
    await prefs.remove(_kLongestEver);
    await prefs.remove(_kPendingBannerOnce);
  }

  // ── Pure helpers (exposed static for unit testing) ──────────────────

  /// Compute the next streak state from the inputs.  Pure: no I/O, no
  /// clock reads.  Returns the new state + whether prefs need writing.
  ///
  /// [today] and [lastCaptureDate] are date-only (time component
  /// ignored at the boundary).  [captured] is true when this transition
  /// is from `recordCaptureToday`, false when from `readCurrentState`.
  static StreakTransition computeTransition({
    required DateTime today,
    required DateTime? lastCaptureDate,
    required int currentStreak,
    required int freezesAvailable,
    required String? freezeWeekAnchor,
    required int longestEver,
    required bool captured,
  }) {
    final todayDate = _dateOnly(today);
    final lastDate =
        lastCaptureDate == null ? null : _dateOnly(lastCaptureDate);
    final thisWeekAnchor = _isoWeekAnchor(todayDate);

    // 1. Refill freeze on Monday (week boundary crossed since last anchor).
    var freezes = freezesAvailable;
    var anchor = freezeWeekAnchor;
    if (anchor != thisWeekAnchor) {
      // Crossed into a new ISO week — credit one freeze (cap at 1).
      if (freezes < 1) freezes = 1;
      anchor = thisWeekAnchor;
    }

    // 2. Determine gap between today and last capture.
    var streak = currentStreak;
    var freezeJustConsumed = false;
    var didIncrement = false;

    if (lastDate == null) {
      // First-ever interaction.
      if (captured) {
        streak = 1;
        didIncrement = true;
      }
    } else {
      final gapDays = todayDate.difference(lastDate).inDays;
      if (gapDays == 0) {
        // Same day — no-op for both read and capture.
      } else if (gapDays == 1) {
        // Yesterday: consecutive.
        if (captured) {
          streak += 1;
          didIncrement = true;
        }
      } else if (gapDays == 2 && freezes > 0) {
        // One day skipped, freeze covers it.
        freezes -= 1;
        freezeJustConsumed = true;
        if (captured) {
          streak += 1;
          didIncrement = true;
        }
        // If !captured, streak preserved at current value — it's the
        // grace period; user must capture today/tomorrow to actually
        // extend.
      } else {
        // Lapsed (>=2 days with no freeze, or >=3 days regardless).
        streak = captured ? 1 : 0;
        didIncrement = captured;
      }
    }

    final newLongest = streak > longestEver ? streak : longestEver;
    final newLastCaptureDate = captured ? todayDate : lastDate;

    return StreakTransition(
      state: StreakState(
        currentStreak: streak,
        longestEver: newLongest,
        freezesAvailable: freezes,
        lastCaptureDate: newLastCaptureDate,
        freezeJustConsumed: freezeJustConsumed,
      ),
      freezeWeekAnchor: anchor,
      didIncrement: didIncrement,
    );
  }

  /// ISO week anchor string "YYYY-Www" for the week containing [date].
  /// Pure helper, exposed for tests.
  static String isoWeekAnchorFor(DateTime date) => _isoWeekAnchor(date);

  // ── Private ──────────────────────────────────────────────────────────

  Future<StreakState> _applyTransitions(
    SharedPreferences prefs,
    DateTime today, {
    required bool captured,
  }) async {
    final lastDateStr = prefs.getString(_kLastCaptureDate);
    final lastDate = lastDateStr == null ? null : DateTime.parse(lastDateStr);
    final transition = computeTransition(
      today: today,
      lastCaptureDate: lastDate,
      currentStreak: prefs.getInt(_kStreakCount) ?? 0,
      freezesAvailable: prefs.getInt(_kFreezesAvailable) ?? 0,
      freezeWeekAnchor: prefs.getString(_kFreezeWeekAnchor),
      longestEver: prefs.getInt(_kLongestEver) ?? 0,
      captured: captured,
    );

    // Persist.
    await prefs.setInt(_kStreakCount, transition.state.currentStreak);
    await prefs.setInt(_kFreezesAvailable, transition.state.freezesAvailable);
    await prefs.setInt(_kLongestEver, transition.state.longestEver);
    if (transition.freezeWeekAnchor != null) {
      await prefs.setString(_kFreezeWeekAnchor, transition.freezeWeekAnchor!);
    }
    if (transition.state.lastCaptureDate != null) {
      await prefs.setString(
        _kLastCaptureDate,
        _isoDate(transition.state.lastCaptureDate!),
      );
    }
    if (transition.state.freezeJustConsumed) {
      await prefs.setBool(_kPendingBannerOnce, true);
    }
    return transition.state;
  }

  DateTime _todayLocal() {
    final now = _clock();
    return _dateOnly(now);
  }

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  static String _isoDate(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  static String _isoWeekAnchor(DateTime date) {
    // ISO 8601 week-numbering year + week.
    final d = _dateOnly(date);
    // Thursday in current week decides the year.
    final dayOfWeek = d.weekday; // Mon=1..Sun=7
    final thursday = d.add(Duration(days: 4 - dayOfWeek));
    final isoYear = thursday.year;
    final firstThursdayOfYear = _firstThursday(isoYear);
    final weekNumber =
        ((thursday.difference(firstThursdayOfYear).inDays) ~/ 7) + 1;
    final ww = weekNumber.toString().padLeft(2, '0');
    return '$isoYear-W$ww';
  }

  static DateTime _firstThursday(int year) {
    final jan1 = DateTime(year, 1, 1);
    // weekday: Mon=1..Sun=7; Thursday=4
    final delta = (4 - jan1.weekday) % 7;
    return jan1.add(Duration(days: delta));
  }
}

/// Snapshot of the user's streak state as of a given read.
class StreakState {
  const StreakState({
    required this.currentStreak,
    required this.longestEver,
    required this.freezesAvailable,
    required this.lastCaptureDate,
    required this.freezeJustConsumed,
  });

  final int currentStreak;
  final int longestEver;
  final int freezesAvailable;
  final DateTime? lastCaptureDate;

  /// True iff this read/capture caused a freeze to be consumed.  UI
  /// uses this (combined with the one-shot prefs flag) to show the
  /// "freeze used" banner exactly once.
  final bool freezeJustConsumed;

  bool get hasActiveStreak => currentStreak > 0;

  Map<String, dynamic> toJson() => {
        'currentStreak': currentStreak,
        'longestEver': longestEver,
        'freezesAvailable': freezesAvailable,
        'lastCaptureDate': lastCaptureDate == null
            ? null
            : '${lastCaptureDate!.year}-${lastCaptureDate!.month.toString().padLeft(2, '0')}-${lastCaptureDate!.day.toString().padLeft(2, '0')}',
        'freezeJustConsumed': freezeJustConsumed,
      };

  @override
  String toString() => jsonEncode(toJson());
}

/// Result of a pure transition: the new state + the new freeze week
/// anchor + whether the streak count incremented (used by UI to trigger
/// a celebration animation on increment without re-checking the count).
class StreakTransition {
  const StreakTransition({
    required this.state,
    required this.freezeWeekAnchor,
    required this.didIncrement,
  });

  final StreakState state;
  final String? freezeWeekAnchor;
  final bool didIncrement;
}
