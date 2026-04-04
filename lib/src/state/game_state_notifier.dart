import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/game_tile.dart';
import '../../models/objective_state.dart';
import '../data/services/map_render_service.dart';
import '../data/services/objective_engine_service.dart';
import '../../features/map/map_controller.dart';
import '../../features/map/trail_progress_service.dart';
import '../../features/map/trail_section_progress_service.dart';
import 'game_state.dart';

/// Central Riverpod provider for all game state.
final gameStateProvider =
    NotifierProvider<GameStateNotifier, GameState>(GameStateNotifier.new);

/// Derived: resolved HUD personality based on preference + progression.
final hudPersonalityProvider = Provider<HudPersonality>((ref) {
  final state = ref.watch(gameStateProvider);
  return _resolveHudPersonality(state);
});

/// Derived: whether we are in the guided-first-capture intro flow.
final isGuidedFirstCaptureModeProvider = Provider<bool>((ref) {
  final state = ref.watch(gameStateProvider);
  return state.isFirstSessionGuided && !state.firstCaptureCelebrated;
});

/// Derived: session elapsed formatted text.
final sessionElapsedTextProvider = Provider<String>((ref) {
  final state = ref.watch(gameStateProvider);
  if (!state.sessionActive || state.sessionStartedAt == null) return '--:--';
  final elapsed = DateTime.now().difference(state.sessionStartedAt!);
  final hours = elapsed.inHours;
  final minutes = elapsed.inMinutes.remainder(60);
  final seconds = elapsed.inSeconds.remainder(60);
  if (hours > 0) {
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}';
  }
  return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
});

HudPersonality _resolveHudPersonality(GameState state) {
  switch (state.hudPreference) {
    case HudPreference.guided:
      return HudPersonality.guided;
    case HudPreference.pro:
      return HudPersonality.pro;
    case HudPreference.auto:
      // MVP: Auto always resolves to Guided so new users get the
      // simplified trail-first experience.
      return HudPersonality.guided;
  }
}

// ─── SharedPreferences keys (unchanged from original) ─────
const _prefsSessionActive = 'session_active_v1';
const _prefsSessionStartedAt = 'session_started_at_v1';
const _prefsUnlockedMilestones = 'unlocked_milestones_v1';
const _prefsHudPreference = 'hud_preference_v1';
const _prefsSessionsStarted = 'sessions_started_count_v1';
const _prefsShowPreviewEnemyTiles = 'show_preview_enemy_tiles_v1';
const _prefsSessionActivityMode = 'session_activity_mode_v1';

class GameStateNotifier extends Notifier<GameState> {
  @override
  GameState build() => const GameState();

  // ─── Simple state setters ───────────────────────────────

  void setTracking(bool value) =>
      state = state.copyWith(tracking: value);

  void setFollowMe(bool value) =>
      state = state.copyWith(followMe: value);

  void setCompactHud(bool value) =>
      state = state.copyWith(compactHud: value);

  void setLegendVisible(bool value) =>
      state = state.copyWith(legendVisible: value);

  void setActionRailVisible(bool value) =>
      state = state.copyWith(actionRailVisible: value);

  void setMapLegendVisible(bool value) =>
      state = state.copyWith(mapLegendVisible: value);

  void setBottomHudVisible(bool value) =>
      state = state.copyWith(bottomHudVisible: value);

  void setShowRecommendationDebug(bool value) =>
      state = state.copyWith(showRecommendationDebug: value);

  void setCapturePulseActive(bool value) =>
      state = state.copyWith(capturePulseActive: value);

  void setRecommendedTileHex(String? hex) => state = hex == null
      ? state.copyWith(clearRecommendedTile: true)
      : state.copyWith(recommendedTileHex: hex);

  void setRecommendedPulseOn(bool value) =>
      state = state.copyWith(recommendedPulseOn: value);

  void setGuidedCameraCenteredOnce(bool value) =>
      state = state.copyWith(guidedCameraCenteredOnce: value);

  // ─── Location / position ─────────────────────────────────

  void updatePosition({
    required double lat,
    required double lng,
    double? accuracy,
  }) {
    var distDelta = 0.0;
    if (state.sessionActive &&
        state.lastSessionLat != null &&
        state.lastSessionLng != null) {
      final d = MapRenderService.haversineMeters(
        state.lastSessionLat!,
        state.lastSessionLng!,
        lat,
        lng,
      );
      if (d > 0 && d < 300) distDelta = d;
    }

    state = state.copyWith(
      lastLat: lat,
      lastLng: lng,
      lastAccuracy: accuracy ?? state.lastAccuracy,
      sessionDistanceMeters: state.sessionDistanceMeters + distDelta,
      lastSessionLat: state.sessionActive ? lat : state.lastSessionLat,
      lastSessionLng: state.sessionActive ? lng : state.lastSessionLng,
    );
  }

  // ─── Map refresh result ──────────────────────────────────

  void applyRefreshResult(
    MapRefreshResult result, {
    required Set<String> capturedHexes,
    required Map<String, String> knownOwnerByHex,
    required String? currentUserId,
    required TrailProgressService trailProgressService,
    required TrailSectionProgressService trailSectionProgressService,
    double? currentLat,
    double? currentLng,
  }) {
    GameTile? refreshedSelected;
    bool shouldClearSelection = false;

    if (state.selectedHex != null) {
      final match = result.visibleTiles
          .where((t) => t.h3Index.toLowerCase() == state.selectedHex)
          .firstOrNull;
      if (match != null) {
        refreshedSelected = match;
      } else {
        shouldClearSelection = true;
      }
    }

    final trailProgress = trailProgressService.calculateProgress(
      capturedHexes,
      currentLat: currentLat,
      currentLng: currentLng,
    );

    final sectionProgress = trailSectionProgressService.calculateProgress(
      capturedHexes: capturedHexes,
      knownOwnerByHex: knownOwnerByHex,
      currentUserId: currentUserId,
      currentLat: currentLat,
      currentLng: currentLng,
    );

    state = state.copyWith(
      currentTile: result.currentHex,
      captured: result.isCaptured,
      currentGameTile: result.currentTile,
      visibleTiles: result.visibleTiles,
      selectedTile: shouldClearSelection ? null : (refreshedSelected ?? state.selectedTile),
      selectedHex: shouldClearSelection ? null : state.selectedHex,
      clearSelection: shouldClearSelection,
      trailProgress: trailProgress,
      sectionProgress: sectionProgress,
    );
  }

  // ─── Tile selection ──────────────────────────────────────

  void selectTile(GameTile tile, String hexLower) {
    state = state.copyWith(selectedTile: tile, selectedHex: hexLower);
  }

  void dismissSelection() {
    state = state.copyWith(clearSelection: true);
  }

  // ─── Objective ───────────────────────────────────────────

  void setCurrentObjective(ObjectiveState objective) {
    state = state.copyWith(currentObjective: objective);
  }

  void updateObjective(ObjectiveEngineService engine, {
    required Set<String> capturedHexes,
    String? streakDirectionHint,
  }) {
    final objective = engine.evaluateObjective(
      sessionActive: state.sessionActive,
      currentTile: state.currentGameTile,
      capturedHexes: capturedHexes,
      capturedHexesCount: capturedHexes.length,
      protectedUntil: state.currentGameTile.protectedUntil,
      trailProgress: state.trailProgress,
      sectionProgress: state.sectionProgress,
      streakDirectionHint: streakDirectionHint,
    );
    state = state.copyWith(currentObjective: objective);
  }

  // ─── Capture feedback ────────────────────────────────────

  void showCaptureFeedback(String text, {bool success = false}) {
    state = state.copyWith(
      captureFeedbackText: text,
      captureFeedbackSuccess: success,
    );
  }

  void clearCaptureFeedback() {
    state = state.copyWith(clearCaptureFeedback: true);
  }

  // ─── Session lifecycle ───────────────────────────────────

  void startSession({
    double? lastLat,
    double? lastLng,
    ActivityMode activityMode = ActivityMode.walkRun,
  }) {
    state = state.copyWith(
      sessionActive: true,
      sessionsStartedCount: state.sessionsStartedCount + 1,
      sessionStartedAt: DateTime.now(),
      sessionActivityMode: activityMode,
      sessionDistanceMeters: 0,
      sessionTilesCaptured: 0,
      sessionTilesRefreshed: 0,
      sessionRivalBlocked: 0,
      sessionTakeovers: 0,
      lastSessionLat: lastLat ?? state.lastLat,
      lastSessionLng: lastLng ?? state.lastLng,
      sessionMilestones: const [],
    );
  }

  void startSessionSilently({double? lastLat, double? lastLng}) {
    if (state.sessionActive) return;
    startSession(lastLat: lastLat, lastLng: lastLng);
  }

  void stopSession() {
    state = state.copyWith(
      sessionActive: false,
      sessionActivityMode: ActivityMode.walkRun,
    );
  }

  // ─── Session distance accumulation ───────────────────────

  /// Accumulates session distance from the previous session-position to the
  /// given [lat]/[lng]. Only updates when a session is active.
  void accumulateSessionDistance(double lat, double lng) {
    if (!state.sessionActive) return;
    var distDelta = 0.0;
    if (state.lastSessionLat != null && state.lastSessionLng != null) {
      final d = MapRenderService.haversineMeters(
        state.lastSessionLat!,
        state.lastSessionLng!,
        lat,
        lng,
      );
      if (d > 0 && d < 300) distDelta = d;
    }
    state = state.copyWith(
      sessionDistanceMeters: state.sessionDistanceMeters + distDelta,
      lastSessionLat: lat,
      lastSessionLng: lng,
    );
  }

  // ─── Session capture counters ────────────────────────────

  void updateSessionCounters(CaptureAttemptResult result) {
    if (!state.sessionActive) return;
    switch (result.status) {
      case CaptureAttemptStatus.captured:
        state = state.copyWith(
            sessionTilesCaptured: state.sessionTilesCaptured + 1);
      case CaptureAttemptStatus.takeoverCaptured:
        state = state.copyWith(
          sessionTilesCaptured: state.sessionTilesCaptured + 1,
          sessionTakeovers: state.sessionTakeovers + 1,
        );
      case CaptureAttemptStatus.protectionRefreshed:
        state = state.copyWith(
            sessionTilesRefreshed: state.sessionTilesRefreshed + 1);
      case CaptureAttemptStatus.protectedByRival:
        state = state.copyWith(
            sessionRivalBlocked: state.sessionRivalBlocked + 1);
      case CaptureAttemptStatus.lowAccuracy:
      case CaptureAttemptStatus.tooFarFromCenter:
        break;
    }
  }

  // ─── First-session guidance ──────────────────────────────

  void refreshFirstSessionGuidance({required bool hasCapturedAnyTile}) {
    final canArm = !state.firstCaptureCelebrated &&
        !state.isFirstSessionGuided &&
        state.sessionsStartedCount == 0 &&
        !hasCapturedAnyTile;
    final shouldDisarm = state.firstCaptureCelebrated || hasCapturedAnyTile;

    if (canArm) {
      state = state.copyWith(isFirstSessionGuided: true);
    }
    if (shouldDisarm) {
      state = state.copyWith(isFirstSessionGuided: false);
    }
  }

  void onFirstCaptureCompleted() {
    if (state.firstCaptureCelebrated) return;
    state = state.copyWith(
      firstCaptureCelebrated: true,
      isFirstSessionGuided: false,
      showPostCaptureGuidance: true,
      clearSelection: true,
    );
  }

  void clearPostCaptureGuidance() {
    state = state.copyWith(showPostCaptureGuidance: false);
  }

  // ─── Milestones ──────────────────────────────────────────

  void addUnlockedMilestones(List<({String id, String title})> milestones) {
    if (milestones.isEmpty) return;
    final newIds = <String>{...state.unlockedMilestoneIds};
    final newSessionMilestones = [...state.sessionMilestones];
    for (final m in milestones) {
      if (newIds.add(m.id)) {
        newSessionMilestones.add(m.title);
      }
    }
    state = state.copyWith(
      unlockedMilestoneIds: newIds,
      sessionMilestones: newSessionMilestones,
    );
  }

  // ─── HUD preference ─────────────────────────────────────

  void setHudPreference(HudPreference pref) {
    state = state.copyWith(hudPreference: pref);
  }

  void setShowPreviewEnemyTiles(bool value) {
    state = state.copyWith(showPreviewEnemyTiles: value);
  }

  void setSessionsStartedCount(int count) {
    state = state.copyWith(sessionsStartedCount: count);
  }

  void setVisibleRadiusMeters(double value) {
    state = state.copyWith(visibleRadiusMeters: value);
  }

  // ─── Persistence ─────────────────────────────────────────

  Future<void> loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final active = prefs.getBool(_prefsSessionActive) ?? false;
    final startedAtRaw = prefs.getString(_prefsSessionStartedAt);
    final hudPrefRaw = prefs.getString(_prefsHudPreference);
    final sessionsStarted = prefs.getInt(_prefsSessionsStarted) ?? 0;
    final showPreview = prefs.getBool(_prefsShowPreviewEnemyTiles) ?? true;
    final activityModeRaw = prefs.getString(_prefsSessionActivityMode);
    final milestones =
        prefs.getStringList(_prefsUnlockedMilestones) ?? const [];

    final hudPref = switch (hudPrefRaw) {
      'guided' => HudPreference.guided,
      'pro' => HudPreference.pro,
      _ => HudPreference.auto,
    };

    state = state.copyWith(
      sessionActive: active,
      sessionStartedAt:
          startedAtRaw == null ? null : DateTime.tryParse(startedAtRaw),
      sessionsStartedCount: sessionsStarted,
      sessionActivityMode: activityModeRaw == 'ride'
          ? ActivityMode.ride
          : ActivityMode.walkRun,
      hudPreference: hudPref,
      showPreviewEnemyTiles: showPreview,
      unlockedMilestoneIds: {...milestones},
    );
  }

  Future<void> saveToPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsSessionActive, state.sessionActive);
    await prefs.setString(
      _prefsSessionActivityMode,
      state.sessionActivityMode == ActivityMode.ride ? 'ride' : 'walkRun',
    );
    final hudPrefRaw = switch (state.hudPreference) {
      HudPreference.auto => 'auto',
      HudPreference.guided => 'guided',
      HudPreference.pro => 'pro',
    };
    await prefs.setString(_prefsHudPreference, hudPrefRaw);
    await prefs.setInt(_prefsSessionsStarted, state.sessionsStartedCount);
    await prefs.setBool(
        _prefsShowPreviewEnemyTiles, state.showPreviewEnemyTiles);

    if (state.sessionStartedAt == null) {
      await prefs.remove(_prefsSessionStartedAt);
    } else {
      await prefs.setString(
        _prefsSessionStartedAt,
        state.sessionStartedAt!.toIso8601String(),
      );
    }

    final milestoneValues = state.unlockedMilestoneIds.toList()..sort();
    await prefs.setStringList(_prefsUnlockedMilestones, milestoneValues);
  }
}

/// Mode-specific tuning constants.
///
/// Mode-specific tuning for Walk/Run vs Ride.
///
/// Walk/Run values are the established defaults.
/// Ride v1 uses modestly more forgiving timings and wider spatial range
/// to account for faster movement speed on a bike.
class ActivityModeConfig {
  final ActivityMode mode;
  const ActivityModeConfig(this.mode);

  /// Auto-capture dwell time before a tile is eligible.
  Duration get autoCaptureDwellTime => switch (mode) {
    ActivityMode.walkRun => const Duration(seconds: 5),
    ActivityMode.ride    => const Duration(seconds: 3),
  };

  /// Minimum gap between successive auto-capture attempts.
  Duration get autoCaptureDebounce => switch (mode) {
    ActivityMode.walkRun => const Duration(seconds: 4),
    ActivityMode.ride    => const Duration(seconds: 2),
  };

  /// Per-tile cooldown after a capture attempt.
  Duration get autoCaptureTileCooldown => switch (mode) {
    ActivityMode.walkRun => const Duration(seconds: 12),
    ActivityMode.ride    => const Duration(seconds: 8),
  };

  /// How far to search for recommendation targets.
  double get maxRecommendationDistanceMeters => switch (mode) {
    ActivityMode.walkRun => 500,
    ActivityMode.ride    => 800,
  };

  /// Default follow-me camera zoom.
  double get defaultCameraZoom => switch (mode) {
    ActivityMode.walkRun => 15.2,
    ActivityMode.ride    => 14.8,
  };

  /// First-capture guided-mode camera zoom.
  double get firstCaptureCameraZoom => switch (mode) {
    ActivityMode.walkRun => 16.1,
    ActivityMode.ride    => 15.6,
  };
}
