import '../../models/game_tile.dart';
import '../../models/objective_state.dart';
import '../../models/trail_progress.dart';
import '../../models/trail_section.dart';

/// Immutable snapshot of the full game state managed by [GameStateNotifier].
class GameState {
  // ─── Session ──────────────────────────────────────────────
  final bool sessionActive;
  final DateTime? sessionStartedAt;
  final double sessionDistanceMeters;
  final int sessionTilesCaptured;
  final int sessionTilesRefreshed;
  final int sessionRivalBlocked;
  final int sessionTakeovers;
  final double? lastSessionLat;
  final double? lastSessionLng;
  final List<String> sessionMilestones;
  final int sessionsStartedCount;

  // ─── Location / current hex ───────────────────────────────
  final String currentTile;
  final bool captured;
  final GameTile currentGameTile;
  final double? lastLat;
  final double? lastLng;
  final double? lastAccuracy;
  final bool tracking;
  final bool followMe;

  // ─── Visible & selected tiles ─────────────────────────────
  final List<GameTile> visibleTiles;
  final GameTile? selectedTile;
  final String? selectedHex;

  // ─── Trail / section progress ─────────────────────────────
  final List<TrailProgress> trailProgress;
  final List<TrailSectionProgress> sectionProgress;

  // ─── Objective / recommendation ───────────────────────────
  final ObjectiveState currentObjective;
  final String? recommendedTileHex;
  final bool recommendedPulseOn;

  // ─── HUD state ────────────────────────────────────────────
  final HudPreference hudPreference;
  final bool compactHud;
  final bool legendVisible;
  final bool actionRailVisible;
  final bool mapLegendVisible;
  final bool bottomHudVisible;
  final bool showRecommendationDebug;
  final bool showPreviewEnemyTiles;
  final double visibleRadiusMeters;

  // ─── Milestones ───────────────────────────────────────────
  final Set<String> unlockedMilestoneIds;

  // ─── Capture feedback ─────────────────────────────────────
  final bool capturePulseActive;
  final String? captureFeedbackText;
  final bool captureFeedbackSuccess;

  // ─── First-session guidance ───────────────────────────────
  final bool isFirstSessionGuided;
  final bool firstCaptureCelebrated;
  final bool showPostCaptureGuidance;
  final bool guidedCameraCenteredOnce;

  const GameState({
    this.sessionActive = false,
    this.sessionStartedAt,
    this.sessionDistanceMeters = 0,
    this.sessionTilesCaptured = 0,
    this.sessionTilesRefreshed = 0,
    this.sessionRivalBlocked = 0,
    this.sessionTakeovers = 0,
    this.lastSessionLat,
    this.lastSessionLng,
    this.sessionMilestones = const [],
    this.sessionsStartedCount = 0,
    this.currentTile = '',
    this.captured = false,
    this.currentGameTile = const GameTile(
      h3Index: '',
      ownership: TileOwnership.neutral,
    ),
    this.lastLat,
    this.lastLng,
    this.lastAccuracy,
    this.tracking = false,
    this.followMe = true,
    this.visibleTiles = const [],
    this.selectedTile,
    this.selectedHex,
    this.trailProgress = const [],
    this.sectionProgress = const [],
    this.currentObjective = const ObjectiveState(title: 'Loading...'),
    this.recommendedTileHex,
    this.recommendedPulseOn = false,
    this.hudPreference = HudPreference.auto,
    this.compactHud = false,
    this.legendVisible = false,
    this.actionRailVisible = false,
    this.mapLegendVisible = false,
    this.bottomHudVisible = false,
    this.showRecommendationDebug = false,
    this.showPreviewEnemyTiles = true,
    this.visibleRadiusMeters = 600,
    this.unlockedMilestoneIds = const {},
    this.capturePulseActive = false,
    this.captureFeedbackText,
    this.captureFeedbackSuccess = false,
    this.isFirstSessionGuided = false,
    this.firstCaptureCelebrated = false,
    this.showPostCaptureGuidance = false,
    this.guidedCameraCenteredOnce = false,
  });

  GameState copyWith({
    bool? sessionActive,
    DateTime? sessionStartedAt,
    double? sessionDistanceMeters,
    int? sessionTilesCaptured,
    int? sessionTilesRefreshed,
    int? sessionRivalBlocked,
    int? sessionTakeovers,
    double? lastSessionLat,
    double? lastSessionLng,
    List<String>? sessionMilestones,
    int? sessionsStartedCount,
    String? currentTile,
    bool? captured,
    GameTile? currentGameTile,
    double? lastLat,
    double? lastLng,
    double? lastAccuracy,
    bool? tracking,
    bool? followMe,
    List<GameTile>? visibleTiles,
    GameTile? selectedTile,
    String? selectedHex,
    bool clearSelection = false,
    List<TrailProgress>? trailProgress,
    List<TrailSectionProgress>? sectionProgress,
    ObjectiveState? currentObjective,
    String? recommendedTileHex,
    bool clearRecommendedTile = false,
    bool? recommendedPulseOn,
    HudPreference? hudPreference,
    bool? compactHud,
    bool? legendVisible,
    bool? actionRailVisible,
    bool? mapLegendVisible,
    bool? bottomHudVisible,
    bool? showRecommendationDebug,
    bool? showPreviewEnemyTiles,
    double? visibleRadiusMeters,
    Set<String>? unlockedMilestoneIds,
    bool? capturePulseActive,
    String? captureFeedbackText,
    bool clearCaptureFeedback = false,
    bool? captureFeedbackSuccess,
    bool? isFirstSessionGuided,
    bool? firstCaptureCelebrated,
    bool? showPostCaptureGuidance,
    bool? guidedCameraCenteredOnce,
  }) {
    return GameState(
      sessionActive: sessionActive ?? this.sessionActive,
      sessionStartedAt: sessionStartedAt ?? this.sessionStartedAt,
      sessionDistanceMeters:
          sessionDistanceMeters ?? this.sessionDistanceMeters,
      sessionTilesCaptured:
          sessionTilesCaptured ?? this.sessionTilesCaptured,
      sessionTilesRefreshed:
          sessionTilesRefreshed ?? this.sessionTilesRefreshed,
      sessionRivalBlocked: sessionRivalBlocked ?? this.sessionRivalBlocked,
      sessionTakeovers: sessionTakeovers ?? this.sessionTakeovers,
      lastSessionLat: lastSessionLat ?? this.lastSessionLat,
      lastSessionLng: lastSessionLng ?? this.lastSessionLng,
      sessionMilestones: sessionMilestones ?? this.sessionMilestones,
      sessionsStartedCount:
          sessionsStartedCount ?? this.sessionsStartedCount,
      currentTile: currentTile ?? this.currentTile,
      captured: captured ?? this.captured,
      currentGameTile: currentGameTile ?? this.currentGameTile,
      lastLat: lastLat ?? this.lastLat,
      lastLng: lastLng ?? this.lastLng,
      lastAccuracy: lastAccuracy ?? this.lastAccuracy,
      tracking: tracking ?? this.tracking,
      followMe: followMe ?? this.followMe,
      visibleTiles: visibleTiles ?? this.visibleTiles,
      selectedTile: clearSelection ? null : (selectedTile ?? this.selectedTile),
      selectedHex: clearSelection ? null : (selectedHex ?? this.selectedHex),
      trailProgress: trailProgress ?? this.trailProgress,
      sectionProgress: sectionProgress ?? this.sectionProgress,
      currentObjective: currentObjective ?? this.currentObjective,
      recommendedTileHex: clearRecommendedTile
          ? null
          : (recommendedTileHex ?? this.recommendedTileHex),
      recommendedPulseOn: recommendedPulseOn ?? this.recommendedPulseOn,
      hudPreference: hudPreference ?? this.hudPreference,
      compactHud: compactHud ?? this.compactHud,
      legendVisible: legendVisible ?? this.legendVisible,
      actionRailVisible: actionRailVisible ?? this.actionRailVisible,
      mapLegendVisible: mapLegendVisible ?? this.mapLegendVisible,
      bottomHudVisible: bottomHudVisible ?? this.bottomHudVisible,
      showRecommendationDebug:
          showRecommendationDebug ?? this.showRecommendationDebug,
      showPreviewEnemyTiles:
          showPreviewEnemyTiles ?? this.showPreviewEnemyTiles,
      visibleRadiusMeters: visibleRadiusMeters ?? this.visibleRadiusMeters,
      unlockedMilestoneIds:
          unlockedMilestoneIds ?? this.unlockedMilestoneIds,
      capturePulseActive: capturePulseActive ?? this.capturePulseActive,
      captureFeedbackText: clearCaptureFeedback
          ? null
          : (captureFeedbackText ?? this.captureFeedbackText),
      captureFeedbackSuccess:
          clearCaptureFeedback
              ? false
              : (captureFeedbackSuccess ?? this.captureFeedbackSuccess),
      isFirstSessionGuided:
          isFirstSessionGuided ?? this.isFirstSessionGuided,
      firstCaptureCelebrated:
          firstCaptureCelebrated ?? this.firstCaptureCelebrated,
      showPostCaptureGuidance:
          showPostCaptureGuidance ?? this.showPostCaptureGuidance,
      guidedCameraCenteredOnce:
          guidedCameraCenteredOnce ?? this.guidedCameraCenteredOnce,
    );
  }
}

/// Which HUD mode the user selected (persisted).
enum HudPreference { auto, guided, pro }

/// The resolved runtime HUD personality after auto-detection.
enum HudPersonality { guided, pro }
