import 'package:flutter_test/flutter_test.dart';
import 'package:territory_game/models/trail_progress.dart';
import 'package:territory_game/models/trail_section.dart';
import 'package:territory_game/src/data/services/milestone_evaluator.dart';

void main() {
  // ── Helpers ──────────────────────────────────────────────

  TrailDefinition trail({String id = 'test_trail', int tiles = 10}) =>
      TrailDefinition(
        id: id,
        name: 'Test Trail',
        orderedH3Indexes: List.generate(tiles, (i) => 'hex_$i'),
      );

  TrailProgress trailProgress({
    String trailId = 'test_trail',
    int longestSegment = 0,
    int ownedTiles = 0,
    int totalTiles = 10,
    bool isComplete = false,
  }) {
    final effectiveOwned = isComplete ? totalTiles : ownedTiles;
    return TrailProgress(
      trail: trail(id: trailId, tiles: totalTiles),
      ownedTiles: effectiveOwned,
      longestOwnedSegmentTiles: longestSegment,
      projectedOwnedSegmentTiles: longestSegment,
      projectedGainTiles: 0,
    );
  }

  TrailSectionDefinition sectionDef() => TrailSectionDefinition(
        id: 'section_test',
        trailId: 'test_trail',
        trailName: 'Test Trail',
        name: 'Test Section',
        startIndex: 0,
        endIndex: 9,
        orderedH3Indexes: List.generate(10, (i) => 'hex_$i'),
      );

  TrailSectionProgress section({
    SectionControlState controlState = SectionControlState.unclaimed,
  }) =>
      TrailSectionProgress(
        section: sectionDef(),
        ownedTiles: 0,
        rivalTiles: 0,
        leadingOwnerId: null,
        tilesToTakeControl: 5,
        tilesToLoseControl: 5,
        isAtRisk: false,
        canFlipWithNextCapture: false,
        longestOwnedSegmentTiles: 0,
        projectedOwnedSegmentTiles: 0,
        projectedGainTiles: 0,
        controlState: controlState,
      );

  // ── evaluateAll ─────────────────────────────────────────

  group('evaluateAll', () {
    test('returns 8 milestone checks', () {
      final checks = MilestoneEvaluator.evaluateAll(
        sessionsStartedCount: 0,
        hasCapturedTiles: false,
        trailProgress: [],
        sectionProgress: [],
      );

      expect(checks.length, 8);
    });

    test('first_session_start unlocks when sessions > 0', () {
      final checks = MilestoneEvaluator.evaluateAll(
        sessionsStartedCount: 1,
        hasCapturedTiles: false,
        trailProgress: [],
        sectionProgress: [],
      );

      final milestone = checks.firstWhere((c) => c.id == 'first_session_start');
      expect(milestone.unlockedNow, true);
    });

    test('first_session_start locked when sessions == 0', () {
      final checks = MilestoneEvaluator.evaluateAll(
        sessionsStartedCount: 0,
        hasCapturedTiles: false,
        trailProgress: [],
        sectionProgress: [],
      );

      final milestone = checks.firstWhere((c) => c.id == 'first_session_start');
      expect(milestone.unlockedNow, false);
    });

    test('first_tile unlocks when hasCapturedTiles is true', () {
      final checks = MilestoneEvaluator.evaluateAll(
        sessionsStartedCount: 0,
        hasCapturedTiles: true,
        trailProgress: [],
        sectionProgress: [],
      );

      final milestone = checks.firstWhere((c) => c.id == 'first_tile');
      expect(milestone.unlockedNow, true);
    });

    test('streak_3 unlocks with 3+ tile segment on any trail', () {
      final checks = MilestoneEvaluator.evaluateAll(
        sessionsStartedCount: 0,
        hasCapturedTiles: true,
        trailProgress: [trailProgress(longestSegment: 3)],
        sectionProgress: [],
      );

      final milestone = checks.firstWhere((c) => c.id == 'streak_3');
      expect(milestone.unlockedNow, true);
    });

    test('streak_5 locked with only 4-tile segment', () {
      final checks = MilestoneEvaluator.evaluateAll(
        sessionsStartedCount: 0,
        hasCapturedTiles: true,
        trailProgress: [trailProgress(longestSegment: 4)],
        sectionProgress: [],
      );

      final milestone = checks.firstWhere((c) => c.id == 'streak_5');
      expect(milestone.unlockedNow, false);
    });

    test('streak_10 unlocks with 10+ tile segment', () {
      final checks = MilestoneEvaluator.evaluateAll(
        sessionsStartedCount: 0,
        hasCapturedTiles: true,
        trailProgress: [trailProgress(longestSegment: 10)],
        sectionProgress: [],
      );

      final milestone = checks.firstWhere((c) => c.id == 'streak_10');
      expect(milestone.unlockedNow, true);
    });

    test('burke_25 unlocks when burke_gilman >= 25% complete', () {
      final checks = MilestoneEvaluator.evaluateAll(
        sessionsStartedCount: 0,
        hasCapturedTiles: true,
        trailProgress: [
          trailProgress(
            trailId: 'burke_gilman',
            ownedTiles: 3,
            totalTiles: 10,
          ),
        ],
        sectionProgress: [],
      );

      final milestone = checks.firstWhere((c) => c.id == 'burke_25');
      expect(milestone.unlockedNow, true);
    });

    test('burke_25 locked when burke_gilman < 25%', () {
      final checks = MilestoneEvaluator.evaluateAll(
        sessionsStartedCount: 0,
        hasCapturedTiles: true,
        trailProgress: [
          trailProgress(
            trailId: 'burke_gilman',
            ownedTiles: 2,
            totalTiles: 10,
          ),
        ],
        sectionProgress: [],
      );

      final milestone = checks.firstWhere((c) => c.id == 'burke_25');
      expect(milestone.unlockedNow, false);
    });

    test('burke_25 locked when no burke_gilman trail exists', () {
      final checks = MilestoneEvaluator.evaluateAll(
        sessionsStartedCount: 0,
        hasCapturedTiles: true,
        trailProgress: [trailProgress(trailId: 'other_trail')],
        sectionProgress: [],
      );

      final milestone = checks.firstWhere((c) => c.id == 'burke_25');
      expect(milestone.unlockedNow, false);
    });

    test('first_trail_complete unlocks when any trail isComplete', () {
      final checks = MilestoneEvaluator.evaluateAll(
        sessionsStartedCount: 0,
        hasCapturedTiles: true,
        trailProgress: [trailProgress(totalTiles: 5, isComplete: true)],
        sectionProgress: [],
      );

      final milestone = checks.firstWhere((c) => c.id == 'first_trail_complete');
      expect(milestone.unlockedNow, true);
    });

    test('first_section_contested unlocks when section is contested', () {
      final checks = MilestoneEvaluator.evaluateAll(
        sessionsStartedCount: 0,
        hasCapturedTiles: false,
        trailProgress: [],
        sectionProgress: [
          section(controlState: SectionControlState.contested),
        ],
      );

      final milestone =
          checks.firstWhere((c) => c.id == 'first_section_contested');
      expect(milestone.unlockedNow, true);
    });

    test('first_section_contested locked when only unclaimed sections', () {
      final checks = MilestoneEvaluator.evaluateAll(
        sessionsStartedCount: 0,
        hasCapturedTiles: false,
        trailProgress: [],
        sectionProgress: [
          section(controlState: SectionControlState.unclaimed),
        ],
      );

      final milestone =
          checks.firstWhere((c) => c.id == 'first_section_contested');
      expect(milestone.unlockedNow, false);
    });

    test('all milestones locked when everything is zeroed', () {
      final checks = MilestoneEvaluator.evaluateAll(
        sessionsStartedCount: 0,
        hasCapturedTiles: false,
        trailProgress: [],
        sectionProgress: [],
      );

      expect(checks.every((c) => !c.unlockedNow), true);
    });
  });

  // ── filterNewlyUnlocked ─────────────────────────────────

  group('filterNewlyUnlocked', () {
    test('returns only newly unlocked milestones', () {
      final allChecks = [
        (id: 'first_session_start', title: 'First session', unlockedNow: true),
        (id: 'first_tile', title: 'First tile', unlockedNow: true),
        (id: 'streak_3', title: '3-tile streak', unlockedNow: false),
      ];

      final result = MilestoneEvaluator.filterNewlyUnlocked(
        allChecks: allChecks,
        alreadyUnlockedIds: {'first_session_start'},
      );

      expect(result.length, 1);
      expect(result.first.id, 'first_tile');
    });

    test('returns empty list when all unlocked are already known', () {
      final allChecks = [
        (id: 'first_session_start', title: 'First session', unlockedNow: true),
        (id: 'streak_3', title: '3-tile streak', unlockedNow: false),
      ];

      final result = MilestoneEvaluator.filterNewlyUnlocked(
        allChecks: allChecks,
        alreadyUnlockedIds: {'first_session_start'},
      );

      expect(result, isEmpty);
    });

    test('returns empty list when nothing is unlocked', () {
      final allChecks = [
        (id: 'first_session_start', title: 'First session', unlockedNow: false),
        (id: 'first_tile', title: 'First tile', unlockedNow: false),
      ];

      final result = MilestoneEvaluator.filterNewlyUnlocked(
        allChecks: allChecks,
        alreadyUnlockedIds: {},
      );

      expect(result, isEmpty);
    });

    test('no duplicate unlocks via filterNewlyUnlocked', () {
      final checks = MilestoneEvaluator.evaluateAll(
        sessionsStartedCount: 2,
        hasCapturedTiles: true,
        trailProgress: [trailProgress(longestSegment: 5)],
        sectionProgress: [],
      );

      // first round: nothing already unlocked
      final firstRound = MilestoneEvaluator.filterNewlyUnlocked(
        allChecks: checks,
        alreadyUnlockedIds: {},
      );

      // second round: all from first round are now already unlocked
      final alreadyUnlocked = firstRound.map((m) => m.id).toSet();
      final secondRound = MilestoneEvaluator.filterNewlyUnlocked(
        allChecks: checks,
        alreadyUnlockedIds: alreadyUnlocked,
      );

      expect(secondRound, isEmpty);
    });
  });
}
