import 'package:flutter_test/flutter_test.dart';
import 'package:territory_game/models/game_tile.dart';
import 'package:territory_game/models/trail_progress.dart';
import 'package:territory_game/models/trail_section.dart';
import 'package:territory_game/src/data/services/recommendation_scoring_service.dart';

void main() {
  // ── Helpers ──────────────────────────────────────────────

  const maxCapture = 80.0; // MapController.maxCaptureDistanceMeters

  TrailSectionDefinition _sectionDef({String name = 'Test Section'}) =>
      TrailSectionDefinition(
        id: 'section_test',
        trailId: 'test_trail',
        trailName: 'Test Trail',
        name: name,
        startIndex: 0,
        endIndex: 9,
        orderedH3Indexes: List.generate(10, (i) => 'hex_$i'),
      );

  TrailSectionProgress _section({
    SectionControlState controlState = SectionControlState.unclaimed,
    String? bestNextTileH3,
    int tilesToTakeControl = 5,
    bool canFlipWithNextCapture = false,
    bool isAtRisk = false,
  }) =>
      TrailSectionProgress(
        section: _sectionDef(),
        ownedTiles: 0,
        rivalTiles: 0,
        leadingOwnerId: null,
        tilesToTakeControl: tilesToTakeControl,
        tilesToLoseControl: 5,
        isAtRisk: isAtRisk,
        canFlipWithNextCapture: canFlipWithNextCapture,
        longestOwnedSegmentTiles: 0,
        projectedOwnedSegmentTiles: 0,
        projectedGainTiles: 0,
        controlState: controlState,
        bestNextTileH3: bestNextTileH3,
      );

  GameTile _tile(String hex, {TileOwnership ownership = TileOwnership.neutral}) =>
      GameTile(h3Index: hex, ownership: ownership);

  // ── Section signals ─────────────────────────────────────

  group('sectionSignalsForHex', () {
    test('returns all-false when no section matches the hex', () {
      final signals = RecommendationScoringService.sectionSignalsForHex(
        'hex_a',
        [_section(bestNextTileH3: 'hex_b')],
      );

      expect(signals.pressure, false);
      expect(signals.canFlip, false);
      expect(signals.atRiskDefense, false);
      expect(signals.strengthensLead, false);
    });

    test('returns all-false when section list is empty', () {
      final signals = RecommendationScoringService.sectionSignalsForHex(
        'hex_a',
        [],
      );

      expect(signals.pressure, false);
      expect(signals.canFlip, false);
      expect(signals.atRiskDefense, false);
      expect(signals.strengthensLead, false);
    });

    test('detects pressure from rival-controlled section', () {
      final signals = RecommendationScoringService.sectionSignalsForHex(
        'hex_a',
        [
          _section(
            controlState: SectionControlState.rival,
            bestNextTileH3: 'hex_a',
          ),
        ],
      );

      expect(signals.pressure, true);
    });

    test('detects pressure from contested section', () {
      final signals = RecommendationScoringService.sectionSignalsForHex(
        'hex_a',
        [
          _section(
            controlState: SectionControlState.contested,
            bestNextTileH3: 'hex_a',
          ),
        ],
      );

      expect(signals.pressure, true);
    });

    test('detects canFlip from canFlipWithNextCapture', () {
      final signals = RecommendationScoringService.sectionSignalsForHex(
        'hex_a',
        [
          _section(
            controlState: SectionControlState.rival,
            bestNextTileH3: 'hex_a',
            canFlipWithNextCapture: true,
          ),
        ],
      );

      expect(signals.canFlip, true);
    });

    test('detects canFlip from tilesToTakeControl <= 1', () {
      final signals = RecommendationScoringService.sectionSignalsForHex(
        'hex_a',
        [
          _section(
            controlState: SectionControlState.rival,
            bestNextTileH3: 'hex_a',
            tilesToTakeControl: 1,
          ),
        ],
      );

      expect(signals.canFlip, true);
    });

    test('detects at-risk defense for owned at-risk section', () {
      final signals = RecommendationScoringService.sectionSignalsForHex(
        'hex_a',
        [
          _section(
            controlState: SectionControlState.you,
            bestNextTileH3: 'hex_a',
            isAtRisk: true,
          ),
        ],
      );

      expect(signals.atRiskDefense, true);
    });

    test('at-risk defense only when you control the section', () {
      final signals = RecommendationScoringService.sectionSignalsForHex(
        'hex_a',
        [
          _section(
            controlState: SectionControlState.rival,
            bestNextTileH3: 'hex_a',
            isAtRisk: true,
          ),
        ],
      );

      // isAtRisk + rival-controlled should NOT be atRiskDefense
      expect(signals.atRiskDefense, false);
    });

    test('detects strengthensLead for you-controlled section', () {
      final signals = RecommendationScoringService.sectionSignalsForHex(
        'hex_a',
        [
          _section(
            controlState: SectionControlState.you,
            bestNextTileH3: 'hex_a',
          ),
        ],
      );

      expect(signals.strengthensLead, true);
    });

    test('detects strengthensLead for unclaimed section', () {
      final signals = RecommendationScoringService.sectionSignalsForHex(
        'hex_a',
        [
          _section(
            controlState: SectionControlState.unclaimed,
            bestNextTileH3: 'hex_a',
          ),
        ],
      );

      expect(signals.strengthensLead, true);
    });

    test('hex matching is case-insensitive', () {
      final signals = RecommendationScoringService.sectionSignalsForHex(
        'hex_a',
        [
          _section(
            controlState: SectionControlState.rival,
            bestNextTileH3: 'HEX_A',
          ),
        ],
      );

      expect(signals.pressure, true);
    });
  });

  // ── Scoring ─────────────────────────────────────────────

  group('scoreCandidate', () {
    test('base score applied at zero distance with no bonuses', () {
      final result = RecommendationScoringService.scoreCandidate(
        _tile('hex_a', ownership: TileOwnership.mine),
        0, // zero distance
        {},
        [],
        maxCaptureDistanceMeters: maxCapture,
      );

      // Base=26, mine ownership=0, no bonuses, no distance penalty
      expect(result.score, RecommendationScoringService.scoreBase);
    });

    test('distance penalty increases with distance', () {
      final close = RecommendationScoringService.scoreCandidate(
        _tile('hex_a'),
        10,
        {},
        [],
        maxCaptureDistanceMeters: maxCapture,
      );

      final far = RecommendationScoringService.scoreCandidate(
        _tile('hex_a'),
        70,
        {},
        [],
        maxCaptureDistanceMeters: maxCapture,
      );

      expect(far.distancePenalty, greaterThan(close.distancePenalty));
      expect(far.score, lessThan(close.score));
    });

    test('max distance penalty is fully applied at maxCaptureDistance', () {
      final result = RecommendationScoringService.scoreCandidate(
        _tile('hex_a'),
        maxCapture,
        {},
        [],
        maxCaptureDistanceMeters: maxCapture,
      );

      expect(
        result.distancePenalty,
        closeTo(RecommendationScoringService.distancePenaltyMax, 0.001),
      );
    });

    test('distance beyond max is clamped', () {
      final atMax = RecommendationScoringService.scoreCandidate(
        _tile('hex_a'),
        maxCapture,
        {},
        [],
        maxCaptureDistanceMeters: maxCapture,
      );

      final beyond = RecommendationScoringService.scoreCandidate(
        _tile('hex_a'),
        maxCapture * 2,
        {},
        [],
        maxCaptureDistanceMeters: maxCapture,
      );

      expect(beyond.distancePenalty, atMax.distancePenalty);
    });

    test('streak bonus applied when hex is in streak targets', () {
      final without = RecommendationScoringService.scoreCandidate(
        _tile('hex_a'),
        10,
        {},
        [],
        maxCaptureDistanceMeters: maxCapture,
      );

      final with_ = RecommendationScoringService.scoreCandidate(
        _tile('hex_a'),
        10,
        {'hex_a'},
        [],
        maxCaptureDistanceMeters: maxCapture,
      );

      expect(
        with_.score - without.score,
        closeTo(RecommendationScoringService.streakBonus, 0.001),
      );
      expect(with_.streakBonusApplied, RecommendationScoringService.streakBonus);
    });

    test('neutral tile gets higher ownership bonus than mine', () {
      final neutralTile = RecommendationScoringService.scoreCandidate(
        _tile('hex_a', ownership: TileOwnership.neutral),
        10,
        {},
        [],
        maxCaptureDistanceMeters: maxCapture,
      );

      final mineTile = RecommendationScoringService.scoreCandidate(
        _tile('hex_a', ownership: TileOwnership.mine),
        10,
        {},
        [],
        maxCaptureDistanceMeters: maxCapture,
      );

      expect(neutralTile.ownershipBonusApplied, RecommendationScoringService.neutralBonus);
      expect(mineTile.ownershipBonusApplied, 0.0);
      expect(neutralTile.score, greaterThan(mineTile.score));
    });

    test('rival tile gets ownership bonus', () {
      final result = RecommendationScoringService.scoreCandidate(
        _tile('hex_a', ownership: TileOwnership.enemy),
        10,
        {},
        [],
        maxCaptureDistanceMeters: maxCapture,
      );

      expect(result.ownershipBonusApplied, RecommendationScoringService.rivalBonus);
    });

    test('section flip bonus applied for flip-eligible section', () {
      final result = RecommendationScoringService.scoreCandidate(
        _tile('hex_a'),
        10,
        {},
        [
          _section(
            controlState: SectionControlState.rival,
            bestNextTileH3: 'hex_a',
            canFlipWithNextCapture: true,
          ),
        ],
        maxCaptureDistanceMeters: maxCapture,
      );

      expect(
        result.sectionFlipBonusApplied,
        RecommendationScoringService.sectionFlipBonus,
      );
    });

    test('streak extension target beats weaker nearby fallback', () {
      // Tile A: streak target, farther
      final streakTile = RecommendationScoringService.scoreCandidate(
        _tile('hex_streak'),
        60,
        {'hex_streak'},
        [],
        maxCaptureDistanceMeters: maxCapture,
      );

      // Tile B: neutral non-streak, closer
      final fallbackTile = RecommendationScoringService.scoreCandidate(
        _tile('hex_fallback'),
        20,
        {},
        [],
        maxCaptureDistanceMeters: maxCapture,
      );

      expect(streakTile.score, greaterThan(fallbackTile.score));
    });

    test('section impact target beats weaker nearby fallback', () {
      // Tile A: section flip candidate, farther
      final sectionTile = RecommendationScoringService.scoreCandidate(
        _tile('hex_section'),
        60,
        {},
        [
          _section(
            controlState: SectionControlState.rival,
            bestNextTileH3: 'hex_section',
            canFlipWithNextCapture: true,
          ),
        ],
        maxCaptureDistanceMeters: maxCapture,
      );

      // Tile B: plain neutral, closer
      final fallbackTile = RecommendationScoringService.scoreCandidate(
        _tile('hex_plain'),
        20,
        {},
        [],
        maxCaptureDistanceMeters: maxCapture,
      );

      expect(sectionTile.score, greaterThan(fallbackTile.score));
    });

    test('score is clamped to [0, scoreMax]', () {
      // Maximum bonuses: all signals + streak + rival
      final result = RecommendationScoringService.scoreCandidate(
        _tile('hex_a', ownership: TileOwnership.enemy),
        0,
        {'hex_a'},
        [
          _section(
            controlState: SectionControlState.rival,
            bestNextTileH3: 'hex_a',
            canFlipWithNextCapture: true,
            isAtRisk: false,
          ),
        ],
        maxCaptureDistanceMeters: maxCapture,
      );

      expect(result.score, lessThanOrEqualTo(RecommendationScoringService.scoreMax));
      expect(result.score, greaterThanOrEqualTo(0));
    });

    test('owned current tile does not become recommendation when better nearby exists', () {
      // Owned tile at zero distance: base=26, no ownership bonus
      final ownedTile = RecommendationScoringService.scoreCandidate(
        _tile('hex_owned', ownership: TileOwnership.mine),
        0,
        {},
        [],
        maxCaptureDistanceMeters: maxCapture,
      );

      // Neutral tile very close + streak target → significant bonuses
      final betterNearby = RecommendationScoringService.scoreCandidate(
        _tile('hex_neutral', ownership: TileOwnership.neutral),
        10,
        {'hex_neutral'},
        [],
        maxCaptureDistanceMeters: maxCapture,
      );

      expect(betterNearby.score, greaterThan(ownedTile.score));
    });
  });

  // ── Hysteresis ──────────────────────────────────────────

  group('applyHysteresis', () {
    test('returns null for empty candidate list', () {
      final result = RecommendationScoringService.applyHysteresis(
        rankedCandidates: [],
        currentRecommendedHex: null,
      );

      expect(result, isNull);
    });

    test('returns top candidate when no current recommendation', () {
      final result = RecommendationScoringService.applyHysteresis(
        rankedCandidates: [
          (score: 50.0, tile: _tile('hex_a')),
          (score: 40.0, tile: _tile('hex_b')),
        ],
        currentRecommendedHex: null,
      );

      expect(result!.h3Index, 'hex_a');
    });

    test('keeps current tile when new top is within switch margin', () {
      final result = RecommendationScoringService.applyHysteresis(
        rankedCandidates: [
          (score: 50.0, tile: _tile('hex_new')),
          (score: 45.0, tile: _tile('hex_current')),
        ],
        currentRecommendedHex: 'hex_current',
      );

      // 50 < 45 + 6 (switchMargin), so current is kept
      expect(result!.h3Index, 'hex_current');
    });

    test('switches to new tile when gap exceeds switch margin', () {
      final result = RecommendationScoringService.applyHysteresis(
        rankedCandidates: [
          (score: 60.0, tile: _tile('hex_new')),
          (score: 40.0, tile: _tile('hex_current')),
        ],
        currentRecommendedHex: 'hex_current',
      );

      // 60 >= 40 + 6, so new tile wins
      expect(result!.h3Index, 'hex_new');
    });

    test('keeps current tile on exact tie within hold margin', () {
      final result = RecommendationScoringService.applyHysteresis(
        rankedCandidates: [
          (score: 46.0, tile: _tile('hex_new')),
          (score: 45.0, tile: _tile('hex_current')),
        ],
        currentRecommendedHex: 'hex_current',
      );

      // Difference = 1.0, within tieHoldMargin (2), keep current
      expect(result!.h3Index, 'hex_current');
    });

    test('current tile not in candidates → uses top candidate', () {
      final result = RecommendationScoringService.applyHysteresis(
        rankedCandidates: [
          (score: 50.0, tile: _tile('hex_a')),
          (score: 40.0, tile: _tile('hex_b')),
        ],
        currentRecommendedHex: 'hex_gone',
      );

      expect(result!.h3Index, 'hex_a');
    });

    test('hex matching is case-insensitive', () {
      final result = RecommendationScoringService.applyHysteresis(
        rankedCandidates: [
          (score: 50.0, tile: _tile('hex_new')),
          (score: 45.0, tile: _tile('HEX_CURRENT')),
        ],
        currentRecommendedHex: 'hex_current',
      );

      expect(result!.h3Index, 'HEX_CURRENT');
    });
  });
}
