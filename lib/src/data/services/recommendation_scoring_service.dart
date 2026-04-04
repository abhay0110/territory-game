import 'package:HexTrail/models/game_tile.dart';
import 'package:HexTrail/models/trail_section.dart';

/// Pure scoring and signal logic for recommendation target selection.
///
/// Extracted from map_screen.dart for testability. All methods are stateless
/// and operate on provided inputs only.
class RecommendationScoringService {
  // ── Scoring constants (match map_screen.dart originals exactly) ──
  static const double scoreMax = 100;
  static const double scoreBase = 26;
  static const double distancePenaltyMax = 28;
  static const double streakBonus = 24;
  static const double sectionPressureBonus = 18;
  static const double sectionFlipBonus = 22;
  static const double atRiskDefenseBonus = 14;
  static const double strengthenLeadBonus = 10;
  static const double neutralBonus = 4;
  static const double rivalBonus = 2;
  static const double switchMargin = 6;
  static const double tieHoldMargin = 2;

  /// Evaluates section-level strategic signals for a given hex.
  ///
  /// Returns a record of boolean flags indicating whether the hex is
  /// relevant for section pressure, flip, at-risk defense, or lead
  /// strengthening.
  static ({
    bool pressure,
    bool canFlip,
    bool atRiskDefense,
    bool strengthensLead,
  })
  sectionSignalsForHex(
    String hexLower,
    List<TrailSectionProgress> sectionProgress,
  ) {
    var pressure = false;
    var canFlip = false;
    var atRiskDefense = false;
    var strengthensLead = false;

    for (final section in sectionProgress) {
      if (section.bestNextTileH3?.toLowerCase() != hexLower) continue;

      if (section.controlState == SectionControlState.contested ||
          section.controlState == SectionControlState.rival) {
        pressure = true;
      }
      if (section.canFlipWithNextCapture || section.tilesToTakeControl <= 1) {
        canFlip = true;
      }
      if (section.isAtRisk && section.controlState == SectionControlState.you) {
        atRiskDefense = true;
      }
      if (section.controlState == SectionControlState.you ||
          section.controlState == SectionControlState.unclaimed) {
        strengthensLead = true;
      }
    }

    return (
      pressure: pressure,
      canFlip: canFlip,
      atRiskDefense: atRiskDefense,
      strengthensLead: strengthensLead,
    );
  }

  /// Scores a single recommendation candidate tile.
  ///
  /// [tile] — the candidate tile
  /// [distance] — distance from the player in meters
  /// [streakTargetHexes] — set of hex strings that extend a trail streak
  /// [sectionProgress] — current section progress list for signal evaluation
  /// [maxCaptureDistanceMeters] — max capture distance for distance normalization
  static ({
    double score,
    double distance,
    double distancePenalty,
    double streakBonusApplied,
    double sectionPressureBonusApplied,
    double sectionFlipBonusApplied,
    double atRiskDefenseBonusApplied,
    double strengthenLeadBonusApplied,
    double ownershipBonusApplied,
    GameTile tile,
  })
  scoreCandidate(
    GameTile tile,
    double distance,
    Set<String> streakTargetHexes,
    List<TrailSectionProgress> sectionProgress, {
    required double maxCaptureDistanceMeters,
  }) {
    final hexLower = tile.h3Index.toLowerCase();
    final signals = sectionSignalsForHex(hexLower, sectionProgress);

    var score = scoreBase;
    final streakBonusApplied = streakTargetHexes.contains(hexLower)
        ? streakBonus
        : 0.0;
    final sectionPressureBonusApplied = signals.pressure
        ? sectionPressureBonus
        : 0.0;
    final sectionFlipBonusApplied = signals.canFlip ? sectionFlipBonus : 0.0;
    final atRiskDefenseBonusApplied = signals.atRiskDefense
        ? atRiskDefenseBonus
        : 0.0;
    final strengthenLeadBonusApplied = signals.strengthensLead
        ? strengthenLeadBonus
        : 0.0;
    final ownershipBonusApplied = switch (tile.ownership) {
      TileOwnership.neutral => neutralBonus,
      TileOwnership.enemy => rivalBonus,
      TileOwnership.mine => 0.0,
    };

    final normalized = (distance / maxCaptureDistanceMeters).clamp(0.0, 1.0);
    final distancePenalty = normalized * distancePenaltyMax;
    score -= distancePenalty;

    score += streakBonusApplied;
    score += sectionPressureBonusApplied;
    score += sectionFlipBonusApplied;
    score += atRiskDefenseBonusApplied;
    score += strengthenLeadBonusApplied;
    score += ownershipBonusApplied;

    score = score.clamp(0, scoreMax).toDouble();
    return (
      score: score,
      distance: distance,
      distancePenalty: distancePenalty,
      streakBonusApplied: streakBonusApplied,
      sectionPressureBonusApplied: sectionPressureBonusApplied,
      sectionFlipBonusApplied: sectionFlipBonusApplied,
      atRiskDefenseBonusApplied: atRiskDefenseBonusApplied,
      strengthenLeadBonusApplied: strengthenLeadBonusApplied,
      ownershipBonusApplied: ownershipBonusApplied,
      tile: tile,
    );
  }

  /// Applies hysteresis to prevent recommendation flickering.
  ///
  /// Returns the best tile from [rankedCandidates], but preserves
  /// [currentRecommendedHex] if it's still competitive (within
  /// [switchMargin] of the top candidate, or within [tieHoldMargin]).
  static GameTile? applyHysteresis({
    required List<({double score, GameTile tile})> rankedCandidates,
    required String? currentRecommendedHex,
  }) {
    if (rankedCandidates.isEmpty) return null;

    var chosen = rankedCandidates.first;

    if (currentRecommendedHex != null) {
      final currentCandidates = rankedCandidates
          .where(
            (item) => item.tile.h3Index.toLowerCase() == currentRecommendedHex,
          )
          .toList(growable: false);
      final current = currentCandidates.isEmpty
          ? null
          : currentCandidates.first;

      if (current != null &&
          chosen.tile.h3Index.toLowerCase() != currentRecommendedHex &&
          chosen.score < current.score + switchMargin) {
        chosen = current;
      }

      if (current != null &&
          chosen.tile.h3Index.toLowerCase() != currentRecommendedHex &&
          (chosen.score - current.score).abs() <= tieHoldMargin) {
        chosen = current;
      }
    }

    return chosen.tile;
  }
}
