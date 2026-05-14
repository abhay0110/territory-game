// Pure-logic tests for StreakService.computeTransition.
//
// Targets the static pure function so we can exhaustively cover the
// streak/freeze state machine without touching SharedPreferences or
// the system clock.  This is the regression net for Phase 1.1.

import 'package:flutter_test/flutter_test.dart';
import 'package:HexTrail/src/data/services/streak_service.dart';

void main() {
  // Wed May 13 2026 (ISO week 20).
  final today = DateTime(2026, 5, 13);
  // Monday of the same week.
  final mondayThisWeek = DateTime(2026, 5, 11);
  // Monday of last week.
  final mondayLastWeek = DateTime(2026, 5, 4);

  String anchor(DateTime d) => StreakService.isoWeekAnchorFor(d);

  group('StreakService.computeTransition — first interaction', () {
    test('first-ever capture → streak = 1, didIncrement = true', () {
      final t = StreakService.computeTransition(
        today: today,
        lastCaptureDate: null,
        currentStreak: 0,
        freezesAvailable: 0,
        freezeWeekAnchor: null,
        longestEver: 0,
        captured: true,
      );
      expect(t.state.currentStreak, 1);
      expect(t.state.longestEver, 1);
      expect(t.didIncrement, isTrue);
      expect(t.state.freezeJustConsumed, isFalse);
      // Freeze refilled on first read in a new week.
      expect(t.state.freezesAvailable, 1);
      expect(t.freezeWeekAnchor, anchor(today));
    });

    test('first-ever read (no capture) → streak stays 0, freeze refills', () {
      final t = StreakService.computeTransition(
        today: today,
        lastCaptureDate: null,
        currentStreak: 0,
        freezesAvailable: 0,
        freezeWeekAnchor: null,
        longestEver: 0,
        captured: false,
      );
      expect(t.state.currentStreak, 0);
      expect(t.didIncrement, isFalse);
      expect(t.state.freezesAvailable, 1);
    });
  });

  group('StreakService.computeTransition — same-day captures', () {
    test('second capture same day → no change', () {
      final t = StreakService.computeTransition(
        today: today,
        lastCaptureDate: today,
        currentStreak: 5,
        freezesAvailable: 1,
        freezeWeekAnchor: anchor(today),
        longestEver: 7,
        captured: true,
      );
      expect(t.state.currentStreak, 5);
      expect(t.didIncrement, isFalse);
      expect(t.state.freezesAvailable, 1);
      expect(t.state.longestEver, 7);
    });

    test('read on the same day as last capture → no change', () {
      final t = StreakService.computeTransition(
        today: today,
        lastCaptureDate: today,
        currentStreak: 5,
        freezesAvailable: 1,
        freezeWeekAnchor: anchor(today),
        longestEver: 7,
        captured: false,
      );
      expect(t.state.currentStreak, 5);
      expect(t.didIncrement, isFalse);
    });
  });

  group('StreakService.computeTransition — consecutive days', () {
    test('capture yesterday + capture today → streak = N+1', () {
      final yesterday = today.subtract(const Duration(days: 1));
      final t = StreakService.computeTransition(
        today: today,
        lastCaptureDate: yesterday,
        currentStreak: 5,
        freezesAvailable: 1,
        freezeWeekAnchor: anchor(today),
        longestEver: 7,
        captured: true,
      );
      expect(t.state.currentStreak, 6);
      expect(t.didIncrement, isTrue);
      expect(t.state.freezesAvailable, 1, reason: 'no freeze burned');
      expect(t.state.freezeJustConsumed, isFalse);
    });

    test('new longest-ever updates on increment', () {
      final yesterday = today.subtract(const Duration(days: 1));
      final t = StreakService.computeTransition(
        today: today,
        lastCaptureDate: yesterday,
        currentStreak: 7,
        freezesAvailable: 1,
        freezeWeekAnchor: anchor(today),
        longestEver: 7,
        captured: true,
      );
      expect(t.state.currentStreak, 8);
      expect(t.state.longestEver, 8);
    });
  });

  group('StreakService.computeTransition — freeze consumption', () {
    test('1-day gap (skipped yesterday) WITH freeze → freeze consumed, '
        'capture today extends streak', () {
      final dayBeforeYesterday = today.subtract(const Duration(days: 2));
      final t = StreakService.computeTransition(
        today: today,
        lastCaptureDate: dayBeforeYesterday,
        currentStreak: 5,
        freezesAvailable: 1,
        freezeWeekAnchor: anchor(today),
        longestEver: 7,
        captured: true,
      );
      expect(t.state.currentStreak, 6, reason: 'extended over the freeze');
      expect(t.state.freezesAvailable, 0, reason: 'freeze burned');
      expect(t.state.freezeJustConsumed, isTrue);
      expect(t.didIncrement, isTrue);
    });

    test('1-day gap WITH freeze, READ ONLY → freeze consumed, streak '
        'preserved but does NOT increment (grace, not extension)', () {
      final dayBeforeYesterday = today.subtract(const Duration(days: 2));
      final t = StreakService.computeTransition(
        today: today,
        lastCaptureDate: dayBeforeYesterday,
        currentStreak: 5,
        freezesAvailable: 1,
        freezeWeekAnchor: anchor(today),
        longestEver: 7,
        captured: false,
      );
      expect(t.state.currentStreak, 5);
      expect(t.state.freezesAvailable, 0);
      expect(t.state.freezeJustConsumed, isTrue);
      expect(t.didIncrement, isFalse);
    });

    test('1-day gap WITHOUT freeze + capture today → reset to 1', () {
      final dayBeforeYesterday = today.subtract(const Duration(days: 2));
      final t = StreakService.computeTransition(
        today: today,
        lastCaptureDate: dayBeforeYesterday,
        currentStreak: 5,
        freezesAvailable: 0,
        freezeWeekAnchor: anchor(today),
        longestEver: 7,
        captured: true,
      );
      expect(t.state.currentStreak, 1);
      expect(t.state.longestEver, 7, reason: 'longest-ever preserved');
      expect(t.didIncrement, isTrue);
    });

    test('2-day gap (3 days since last) EVEN WITH freeze → reset to 1', () {
      final threeDaysAgo = today.subtract(const Duration(days: 3));
      final t = StreakService.computeTransition(
        today: today,
        lastCaptureDate: threeDaysAgo,
        currentStreak: 10,
        freezesAvailable: 1,
        freezeWeekAnchor: anchor(today),
        longestEver: 10,
        captured: true,
      );
      expect(t.state.currentStreak, 1, reason: 'freeze covers 1 day, not 2');
      expect(t.state.freezesAvailable, 1, reason: 'freeze NOT burned on lapse');
      expect(t.state.freezeJustConsumed, isFalse);
      expect(t.state.longestEver, 10);
    });

    test('lapsed read (no capture) → streak resets to 0', () {
      final fiveDaysAgo = today.subtract(const Duration(days: 5));
      final t = StreakService.computeTransition(
        today: today,
        lastCaptureDate: fiveDaysAgo,
        currentStreak: 10,
        freezesAvailable: 0,
        freezeWeekAnchor: anchor(today),
        longestEver: 10,
        captured: false,
      );
      expect(t.state.currentStreak, 0);
      expect(t.didIncrement, isFalse);
    });
  });

  group('StreakService.computeTransition — freeze refill (weekly)', () {
    test('crossing into a new ISO week → +1 freeze (capped at 1)', () {
      // lastCaptureDate is in last week's anchor; today is in this week.
      final t = StreakService.computeTransition(
        today: today,
        lastCaptureDate: mondayLastWeek,
        currentStreak: 0,
        freezesAvailable: 0,
        freezeWeekAnchor: anchor(mondayLastWeek),
        longestEver: 3,
        captured: false,
      );
      expect(t.freezeWeekAnchor, anchor(today));
      expect(t.state.freezesAvailable, 1);
    });

    test('already have 1 freeze on Monday refill → still 1 (no stockpile)', () {
      // Use today (May 13) as lastCaptureDate so there is no gap to
      // consume the freeze; we are isolating the refill cap behavior.
      final t = StreakService.computeTransition(
        today: today,
        lastCaptureDate: today,
        currentStreak: 1,
        freezesAvailable: 1,
        freezeWeekAnchor: anchor(mondayLastWeek), // stale anchor
        longestEver: 1,
        captured: false,
      );
      expect(t.state.freezesAvailable, 1, reason: 'capped at 1');
      expect(t.freezeWeekAnchor, anchor(today));
    });

    test('same week → no refill', () {
      final t = StreakService.computeTransition(
        today: today,
        lastCaptureDate: mondayThisWeek,
        currentStreak: 3,
        freezesAvailable: 0,
        freezeWeekAnchor: anchor(today),
        longestEver: 3,
        captured: false,
      );
      expect(t.state.freezesAvailable, 0);
      expect(t.freezeWeekAnchor, anchor(today));
    });
  });

  group('StreakService.computeTransition — edge cases', () {
    test('capture on a brand-new install, no freeze data → still credits '
        'this week\'s freeze', () {
      final t = StreakService.computeTransition(
        today: today,
        lastCaptureDate: null,
        currentStreak: 0,
        freezesAvailable: 0,
        freezeWeekAnchor: null,
        longestEver: 0,
        captured: true,
      );
      expect(t.state.freezesAvailable, 1);
      expect(t.state.currentStreak, 1);
    });

    test('time component on lastCaptureDate is irrelevant — '
        'date-only comparison', () {
      final yesterdayLate = DateTime(2026, 5, 12, 23, 59, 59);
      final todayEarly = DateTime(2026, 5, 13, 0, 0, 1);
      final t = StreakService.computeTransition(
        today: todayEarly,
        lastCaptureDate: yesterdayLate,
        currentStreak: 5,
        freezesAvailable: 1,
        freezeWeekAnchor: anchor(todayEarly),
        longestEver: 5,
        captured: true,
      );
      expect(t.state.currentStreak, 6, reason: 'consecutive across midnight');
      expect(t.state.freezesAvailable, 1);
    });
  });

  group('StreakService.isoWeekAnchorFor — pure ISO week math', () {
    test('Mon-Sun map to the same ISO week anchor', () {
      final mon = DateTime(2026, 5, 11);
      final sun = DateTime(2026, 5, 17);
      expect(StreakService.isoWeekAnchorFor(mon),
          StreakService.isoWeekAnchorFor(sun));
    });

    test('format is YYYY-Www zero-padded', () {
      expect(StreakService.isoWeekAnchorFor(DateTime(2026, 1, 5)),
          '2026-W02');
    });

    test('year boundary handled (ISO week year may differ from calendar year)',
        () {
      // Jan 1 2027 is a Friday → ISO week 53 of 2026.
      expect(StreakService.isoWeekAnchorFor(DateTime(2027, 1, 1)),
          '2026-W53');
    });
  });
}
