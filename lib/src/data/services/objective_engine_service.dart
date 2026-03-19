import 'package:territory_game/models/objective_state.dart';
import 'package:territory_game/models/game_tile.dart';
import 'package:territory_game/models/trail_progress.dart';
import 'package:territory_game/models/trail_section.dart';

/// Evaluates current game state and provides objective guidance for Guided mode.
class ObjectiveEngineService {
  /// Determines the current objective based on game state.
  ///
  /// Parameters:
  /// - [sessionActive]: Whether a session is currently active
  /// - [currentTile]: The tile at the player's current location
  /// - [capturedHexes]: Set of hexes already captured by the player
  /// - [capturedHexesCount]: Total count of captured tiles (for context)
  ObjectiveState evaluateObjective({
    required bool sessionActive,
    required GameTile? currentTile,
    required Set<String> capturedHexes,
    required int capturedHexesCount,
    required DateTime? protectedUntil,
    required List<TrailProgress> trailProgress,
    required List<TrailSectionProgress> sectionProgress,
    String? streakDirectionHint,
  }) {
    // State 1: Session idle
    if (!sessionActive) {
      return const ObjectiveState(
        title: 'Start a session to begin capturing territory.',
        actionLabel: 'Start Session',
      );
    }

    // State 6: No valid current tile
    if (currentTile == null || currentTile.h3Index.isEmpty) {
      return const ObjectiveState(
        title: 'Move closer to a visible tile to continue.',
      );
    }

    final tileOwnership = currentTile.ownership;
    final hexLower = currentTile.h3Index.toLowerCase();
    final isOwnedByPlayer = capturedHexes.contains(hexLower);
    final tileSectionSignals = sectionProgress
        .where((s) => s.bestNextTileH3?.toLowerCase() == hexLower)
        .toList(growable: false);
    final pressuresRivalSection = tileSectionSignals.any(
      (s) =>
          s.controlState == SectionControlState.rival ||
          s.controlState == SectionControlState.contested,
    );
    final strengthensYourControl = tileSectionSignals.any(
      (s) =>
          s.controlState == SectionControlState.you ||
          s.controlState == SectionControlState.unclaimed,
    );

    final oneTileFromContest = sectionProgress
        .where((s) => s.tilesToTakeControl == 1 && s.bestNextTileH3 != null)
        .cast<TrailSectionProgress?>()
        .firstWhere((_) => true, orElse: () => null);

    final bestStreakTarget = trailProgress
        .where(
          (p) =>
              !p.isComplete &&
              p.bestNextTileH3 != null &&
              p.bestNextTileReason == TrailNextTileReason.extendStreak,
        )
        .cast<TrailProgress?>()
        .firstWhere((_) => true, orElse: () => null);

    // State 3: Player's own tile
    if (tileOwnership == TileOwnership.mine || isOwnedByPlayer) {
      if (oneTileFromContest != null) {
        return ObjectiveState(
          title: 'One more tile contests this section.',
          detail:
              '${oneTileFromContest.section.name} is one capture away from pressure.',
        );
      }

      if (bestStreakTarget != null) {
        final direction = streakDirectionHint ?? 'forward';
        return ObjectiveState(
          title: 'Capture $direction to extend your streak.',
          detail: 'Next route extension is on ${bestStreakTarget.trail.name}.',
        );
      }

      return const ObjectiveState(
        title: 'Move to a nearby open tile to extend your streak.',
      );
    }

    // State 2: Neutral tile
    if (tileOwnership == TileOwnership.neutral) {
      final contextDetail = capturedHexesCount == 0
          ? 'Capture this tile to claim your first territory.'
          : 'Capture this tile to expand your route.';

      if (strengthensYourControl) {
        return ObjectiveState(
          title: 'This tile strengthens your control.',
          detail: contextDetail,
          actionLabel: 'Capture',
        );
      }

      return ObjectiveState(title: contextDetail, actionLabel: 'Capture');
    }

    // State 4 & 5: Rival tile (protected or capturable)
    if (tileOwnership == TileOwnership.enemy) {
      final now = DateTime.now();
      final isProtected = protectedUntil != null && protectedUntil.isAfter(now);

      if (isProtected) {
        // State 4: Protected rival tile
        return const ObjectiveState(
          title: 'This tile is protected — target another nearby tile.',
        );
      } else {
        // State 5: Capturable rival tile
        if (pressuresRivalSection) {
          return const ObjectiveState(
            title: 'Target this tile to pressure the rival section.',
            detail: 'This capture shifts section momentum toward you.',
            actionLabel: 'Capture',
          );
        }
        return const ObjectiveState(
          title: 'Capture this tile to steal enemy territory.',
          actionLabel: 'Capture',
        );
      }
    }

    // Fallback (should not reach here)
    return const ObjectiveState(
      title: 'Keep capturing tiles to expand your territory.',
    );
  }
}
