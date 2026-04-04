import 'package:HexTrail/models/trail_progress.dart';
import 'package:HexTrail/models/trail_section.dart';

/// Pure milestone evaluation logic.
///
/// All checks are stateless: given current game state metrics, returns
/// which milestones should be considered unlocked.
class MilestoneEvaluator {
  /// Evaluates all milestone conditions and returns those currently met.
  ///
  /// Callers are responsible for filtering out already-unlocked milestones
  /// before presenting them.
  static List<({String id, String title, bool unlockedNow})> evaluateAll({
    required int sessionsStartedCount,
    required bool hasCapturedTiles,
    required List<TrailProgress> trailProgress,
    required List<TrailSectionProgress> sectionProgress,
  }) {
    final burke = trailProgress
        .where((p) => p.trail.id == 'burke_gilman')
        .toList();
    final burkeProgress = burke.isEmpty ? null : burke.first;

    return [
      (
        id: 'first_session_start',
        title: '🎬 First session started',
        unlockedNow: sessionsStartedCount > 0,
      ),
      (
        id: 'first_tile',
        title: '🏁 First tile captured',
        unlockedNow: hasCapturedTiles,
      ),
      (
        id: 'streak_3',
        title: '🔥 3-tile streak reached',
        unlockedNow: trailProgress.any((p) => p.longestOwnedSegmentTiles >= 3),
      ),
      (
        id: 'streak_5',
        title: '🔥 5-tile streak reached',
        unlockedNow: trailProgress.any((p) => p.longestOwnedSegmentTiles >= 5),
      ),
      (
        id: 'streak_10',
        title: '⚡ 10-tile streak reached',
        unlockedNow: trailProgress.any((p) => p.longestOwnedSegmentTiles >= 10),
      ),
      (
        id: 'burke_25',
        title: '🗺️ Burke-Gilman 25% complete',
        unlockedNow: (burkeProgress?.completionPercent ?? 0) >= 25,
      ),
      (
        id: 'first_trail_complete',
        title: '🏆 Completed first trail',
        unlockedNow: trailProgress.any((p) => p.isComplete),
      ),
      (
        id: 'first_section_contested',
        title: '⚔️ First section contested',
        unlockedNow: sectionProgress.any(
          (s) => s.controlState == SectionControlState.contested,
        ),
      ),
    ];
  }

  /// Filters [allChecks] to only those that are newly unlocked—not already
  /// in [alreadyUnlockedIds].
  static List<({String id, String title})> filterNewlyUnlocked({
    required List<({String id, String title, bool unlockedNow})> allChecks,
    required Set<String> alreadyUnlockedIds,
  }) {
    return allChecks
        .where((c) => c.unlockedNow && !alreadyUnlockedIds.contains(c.id))
        .map((c) => (id: c.id, title: c.title))
        .toList(growable: false);
  }
}
