import 'package:flutter_test/flutter_test.dart';
import 'package:territory_game/models/game_tile.dart';
import 'package:territory_game/models/trail_progress.dart';
import 'package:territory_game/models/trail_section.dart';
import 'package:territory_game/src/data/services/objective_engine_service.dart';

void main() {
  late ObjectiveEngineService engine;

  setUp(() {
    engine = ObjectiveEngineService();
  });

  // ── Helpers ──────────────────────────────────────────────

  TrailDefinition _trail({String id = 'test_trail', int tiles = 10}) =>
      TrailDefinition(
        id: id,
        name: 'Test Trail',
        orderedH3Indexes: List.generate(tiles, (i) => 'hex_$i'),
      );

  TrailProgress _trailProgress({
    String trailId = 'test_trail',
    int longestSegment = 0,
    bool isComplete = false,
    String? bestNextTileH3,
    TrailNextTileReason? reason,
  }) =>
      TrailProgress(
        trail: _trail(
          id: trailId,
          tiles: isComplete ? longestSegment : longestSegment + 5,
        ),
        ownedTiles: isComplete ? longestSegment : longestSegment,
        longestOwnedSegmentTiles: longestSegment,
        projectedOwnedSegmentTiles: longestSegment,
        projectedGainTiles: 0,
        bestNextTileH3: bestNextTileH3,
        bestNextTileReason: reason,
      );

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

  TrailSectionProgress _sectionProgress({
    SectionControlState controlState = SectionControlState.unclaimed,
    int tilesToTakeControl = 5,
    String? bestNextTileH3,
    String sectionName = 'Test Section',
  }) =>
      TrailSectionProgress(
        section: _sectionDef(name: sectionName),
        ownedTiles: 0,
        rivalTiles: 0,
        leadingOwnerId: null,
        tilesToTakeControl: tilesToTakeControl,
        tilesToLoseControl: 5,
        isAtRisk: false,
        canFlipWithNextCapture: false,
        longestOwnedSegmentTiles: 0,
        projectedOwnedSegmentTiles: 0,
        projectedGainTiles: 0,
        controlState: controlState,
        bestNextTileH3: bestNextTileH3,
      );

  // ── State 1: Session idle ────────────────────────────────

  group('State 1: Session idle', () {
    test('returns start session guidance when session inactive', () {
      final result = engine.evaluateObjective(
        sessionActive: false,
        currentTile: null,
        capturedHexes: {},
        capturedHexesCount: 0,
        protectedUntil: null,
        trailProgress: [],
        sectionProgress: [],
      );

      expect(result.title, contains('Start a session'));
      expect(result.actionLabel, 'Start Session');
    });

    test('ignores current tile when session inactive', () {
      final result = engine.evaluateObjective(
        sessionActive: false,
        currentTile: const GameTile(
          h3Index: 'abc123',
          ownership: TileOwnership.neutral,
        ),
        capturedHexes: {},
        capturedHexesCount: 0,
        protectedUntil: null,
        trailProgress: [],
        sectionProgress: [],
      );

      expect(result.title, contains('Start a session'));
    });
  });

  // ── State 6: No valid current tile ───────────────────────

  group('State 6: No valid current tile', () {
    test('returns move-closer when current tile is null', () {
      final result = engine.evaluateObjective(
        sessionActive: true,
        currentTile: null,
        capturedHexes: {},
        capturedHexesCount: 0,
        protectedUntil: null,
        trailProgress: [],
        sectionProgress: [],
      );

      expect(result.title, contains('Move closer'));
    });

    test('returns move-closer when current tile has empty h3Index', () {
      final result = engine.evaluateObjective(
        sessionActive: true,
        currentTile: const GameTile(
          h3Index: '',
          ownership: TileOwnership.neutral,
        ),
        capturedHexes: {},
        capturedHexesCount: 0,
        protectedUntil: null,
        trailProgress: [],
        sectionProgress: [],
      );

      expect(result.title, contains('Move closer'));
    });
  });

  // ── State 2: Neutral tile ───────────────────────────────

  group('State 2: Neutral tile', () {
    test('first tile capture copy when no tiles owned', () {
      final result = engine.evaluateObjective(
        sessionActive: true,
        currentTile: const GameTile(
          h3Index: 'hex_a',
          ownership: TileOwnership.neutral,
        ),
        capturedHexes: {},
        capturedHexesCount: 0,
        protectedUntil: null,
        trailProgress: [],
        sectionProgress: [],
      );

      expect(result.title, contains('first territory'));
      expect(result.actionLabel, 'Capture');
    });

    test('expand route copy when tiles already owned', () {
      final result = engine.evaluateObjective(
        sessionActive: true,
        currentTile: const GameTile(
          h3Index: 'hex_a',
          ownership: TileOwnership.neutral,
        ),
        capturedHexes: {'hex_b'},
        capturedHexesCount: 1,
        protectedUntil: null,
        trailProgress: [],
        sectionProgress: [],
      );

      expect(result.title, contains('expand your route'));
      expect(result.actionLabel, 'Capture');
    });

    test('strengthens control copy when section signals match', () {
      final result = engine.evaluateObjective(
        sessionActive: true,
        currentTile: const GameTile(
          h3Index: 'hex_a',
          ownership: TileOwnership.neutral,
        ),
        capturedHexes: {'hex_b'},
        capturedHexesCount: 1,
        protectedUntil: null,
        trailProgress: [],
        sectionProgress: [
          _sectionProgress(
            controlState: SectionControlState.you,
            bestNextTileH3: 'hex_a',
          ),
        ],
      );

      expect(result.title, contains('strengthens your control'));
      expect(result.actionLabel, 'Capture');
    });
  });

  // ── State 3: Player's own tile ──────────────────────────

  group('State 3: Player-owned tile', () {
    test('generic move guidance when no streak or section target', () {
      final result = engine.evaluateObjective(
        sessionActive: true,
        currentTile: const GameTile(
          h3Index: 'hex_a',
          ownership: TileOwnership.mine,
        ),
        capturedHexes: {'hex_a'},
        capturedHexesCount: 1,
        protectedUntil: null,
        trailProgress: [],
        sectionProgress: [],
      );

      expect(result.title, contains('Move to a nearby open tile'));
    });

    test('one-tile-from-contest objective takes priority', () {
      final result = engine.evaluateObjective(
        sessionActive: true,
        currentTile: const GameTile(
          h3Index: 'hex_a',
          ownership: TileOwnership.mine,
        ),
        capturedHexes: {'hex_a'},
        capturedHexesCount: 1,
        protectedUntil: null,
        trailProgress: [],
        sectionProgress: [
          _sectionProgress(
            controlState: SectionControlState.rival,
            tilesToTakeControl: 1,
            bestNextTileH3: 'hex_b',
            sectionName: 'Downtown',
          ),
        ],
      );

      expect(result.title, contains('One more tile contests'));
      expect(result.detail, contains('Downtown'));
    });

    test('streak extension objective when available', () {
      final result = engine.evaluateObjective(
        sessionActive: true,
        currentTile: const GameTile(
          h3Index: 'hex_a',
          ownership: TileOwnership.mine,
        ),
        capturedHexes: {'hex_a'},
        capturedHexesCount: 1,
        protectedUntil: null,
        trailProgress: [
          _trailProgress(
            longestSegment: 3,
            bestNextTileH3: 'hex_b',
            reason: TrailNextTileReason.extendStreak,
          ),
        ],
        sectionProgress: [],
        streakDirectionHint: 'north',
      );

      expect(result.title, contains('north'));
      expect(result.title, contains('extend your streak'));
    });

    test('streak direction defaults to forward when no hint', () {
      final result = engine.evaluateObjective(
        sessionActive: true,
        currentTile: const GameTile(
          h3Index: 'hex_a',
          ownership: TileOwnership.mine,
        ),
        capturedHexes: {'hex_a'},
        capturedHexesCount: 1,
        protectedUntil: null,
        trailProgress: [
          _trailProgress(
            longestSegment: 3,
            bestNextTileH3: 'hex_b',
            reason: TrailNextTileReason.extendStreak,
          ),
        ],
        sectionProgress: [],
      );

      expect(result.title, contains('forward'));
    });

    test('contest takes priority over streak extension', () {
      final result = engine.evaluateObjective(
        sessionActive: true,
        currentTile: const GameTile(
          h3Index: 'hex_a',
          ownership: TileOwnership.mine,
        ),
        capturedHexes: {'hex_a'},
        capturedHexesCount: 1,
        protectedUntil: null,
        trailProgress: [
          _trailProgress(
            longestSegment: 3,
            bestNextTileH3: 'hex_b',
            reason: TrailNextTileReason.extendStreak,
          ),
        ],
        sectionProgress: [
          _sectionProgress(
            controlState: SectionControlState.rival,
            tilesToTakeControl: 1,
            bestNextTileH3: 'hex_c',
            sectionName: 'Fremont',
          ),
        ],
      );

      expect(result.title, contains('One more tile contests'));
    });

    test('isOwnedByPlayer via capturedHexes works for mine ownership', () {
      final result = engine.evaluateObjective(
        sessionActive: true,
        currentTile: const GameTile(
          h3Index: 'HEX_A',
          ownership: TileOwnership.mine,
        ),
        capturedHexes: {'hex_a'},
        capturedHexesCount: 1,
        protectedUntil: null,
        trailProgress: [],
        sectionProgress: [],
      );

      // Should still go through the owned-tile path (State 3)
      expect(result.title, contains('Move to a nearby open tile'));
    });
  });

  // ── State 4: Protected rival tile ───────────────────────

  group('State 4: Protected rival tile', () {
    test('tells player to move on when tile is protected', () {
      final protectedTime = DateTime.now().add(const Duration(hours: 20));

      final result = engine.evaluateObjective(
        sessionActive: true,
        currentTile: const GameTile(
          h3Index: 'hex_rival',
          ownership: TileOwnership.enemy,
        ),
        capturedHexes: {},
        capturedHexesCount: 0,
        protectedUntil: protectedTime,
        trailProgress: [],
        sectionProgress: [],
      );

      expect(result.title, contains('protected'));
      expect(result.title, contains('target another'));
    });
  });

  // ── State 5: Capturable rival tile ──────────────────────

  group('State 5: Capturable rival tile', () {
    test('generic steal copy when no section pressure', () {
      final result = engine.evaluateObjective(
        sessionActive: true,
        currentTile: const GameTile(
          h3Index: 'hex_rival',
          ownership: TileOwnership.enemy,
        ),
        capturedHexes: {},
        capturedHexesCount: 0,
        protectedUntil: null,
        trailProgress: [],
        sectionProgress: [],
      );

      expect(result.title, contains('steal enemy territory'));
      expect(result.actionLabel, 'Capture');
    });

    test('section pressure copy when hex pressures rival section', () {
      final result = engine.evaluateObjective(
        sessionActive: true,
        currentTile: const GameTile(
          h3Index: 'hex_rival',
          ownership: TileOwnership.enemy,
        ),
        capturedHexes: {},
        capturedHexesCount: 0,
        protectedUntil: null,
        trailProgress: [],
        sectionProgress: [
          _sectionProgress(
            controlState: SectionControlState.rival,
            bestNextTileH3: 'hex_rival',
          ),
        ],
      );

      expect(result.title, contains('pressure the rival section'));
      expect(result.actionLabel, 'Capture');
    });

    test('expired protection counts as capturable', () {
      final expiredTime = DateTime.now().subtract(const Duration(hours: 1));

      final result = engine.evaluateObjective(
        sessionActive: true,
        currentTile: const GameTile(
          h3Index: 'hex_rival',
          ownership: TileOwnership.enemy,
        ),
        capturedHexes: {},
        capturedHexesCount: 0,
        protectedUntil: expiredTime,
        trailProgress: [],
        sectionProgress: [],
      );

      expect(result.title, contains('steal enemy territory'));
      expect(result.actionLabel, 'Capture');
    });
  });

  // ── Edge cases ──────────────────────────────────────────

  group('Edge cases', () {
    test('section one-tile-from-contest only fires when bestNextTileH3 is set', () {
      final result = engine.evaluateObjective(
        sessionActive: true,
        currentTile: const GameTile(
          h3Index: 'hex_a',
          ownership: TileOwnership.mine,
        ),
        capturedHexes: {'hex_a'},
        capturedHexesCount: 1,
        protectedUntil: null,
        trailProgress: [],
        sectionProgress: [
          _sectionProgress(
            controlState: SectionControlState.rival,
            tilesToTakeControl: 1,
            bestNextTileH3: null, // no target hex
          ),
        ],
      );

      // Should NOT fire one-tile-from-contest because bestNextTileH3 is null
      expect(result.title, isNot(contains('One more tile contests')));
    });

    test('streak extension only fires for extendStreak reason', () {
      final result = engine.evaluateObjective(
        sessionActive: true,
        currentTile: const GameTile(
          h3Index: 'hex_a',
          ownership: TileOwnership.mine,
        ),
        capturedHexes: {'hex_a'},
        capturedHexesCount: 1,
        protectedUntil: null,
        trailProgress: [
          _trailProgress(
            longestSegment: 3,
            bestNextTileH3: 'hex_b',
            reason: TrailNextTileReason.bridgeGap, // not extendStreak
          ),
        ],
        sectionProgress: [],
      );

      // Named trail detail only appears for extendStreak reason
      expect(result.detail, isNull);
    });

    test('complete trail is excluded from streak extension', () {
      final result = engine.evaluateObjective(
        sessionActive: true,
        currentTile: const GameTile(
          h3Index: 'hex_a',
          ownership: TileOwnership.mine,
        ),
        capturedHexes: {'hex_a'},
        capturedHexesCount: 1,
        protectedUntil: null,
        trailProgress: [
          _trailProgress(
            longestSegment: 10,
            isComplete: true,
            bestNextTileH3: 'hex_b',
            reason: TrailNextTileReason.extendStreak,
          ),
        ],
        sectionProgress: [],
      );

      // Complete trail should not trigger named-trail streak extension
      expect(result.detail, isNull);
    });
  });
}
