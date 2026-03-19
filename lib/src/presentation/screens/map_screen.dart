import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mb;
import 'package:h3_flutter/h3_flutter.dart' as h3;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/constants/game_colors.dart';
import '../../../core/constants/game_rules.dart';
import '../../../core/theme/game_ui_tokens.dart';
import '../../../models/game_tile.dart';
import '../../../models/objective_state.dart';
import '../../../models/trail_progress.dart';
import '../../../models/trail_section.dart';
import '../../config/mapbox.dart';
import '../../../features/map/map_controller.dart';
import '../../../features/map/trail_progress_service.dart';
import '../../../features/map/trail_section_progress_service.dart';
import '../../data/services/capture_service.dart';
import '../../data/services/location_service.dart';
import '../../data/services/map_event_log_service.dart';
import '../../data/services/map_render_service.dart';
import '../../data/services/objective_engine_service.dart';
import '../widgets/frosted_overlay_card.dart';
import '../widgets/leaderboard_dialog.dart';
import '../widgets/map_legend.dart';
import '../widgets/section_progress_dialog.dart';
import '../widgets/tile_details_dialog.dart';

enum HudPreference { auto, guided, pro }

enum HudPersonality { guided, pro }

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _GuidedOverlayCard extends StatelessWidget {
  final String message;
  final Widget? trailing;

  const _GuidedOverlayCard({required this.message, this.trailing});

  @override
  Widget build(BuildContext context) {
    return FrostedOverlayCard(
      emphasized: true,
      borderRadius: const BorderRadius.all(Radius.circular(14)),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.gps_fixed, size: 14, color: GameUiTokens.accentPrimary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: GameUiText.body(
                color: GameUiTokens.textHi,
                size: 13,
                weight: FontWeight.w800,
              ),
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ],
      ),
    );
  }
}

class _CaptureFeedbackOverlay extends StatelessWidget {
  final String text;
  final bool success;

  const _CaptureFeedbackOverlay({required this.text, this.success = false});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) {
        final rise = 12 * (1 - t);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, rise),
            child: Transform.scale(scale: 0.94 + (0.06 * t), child: child),
          ),
        );
      },
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          if (success)
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: GameUiTokens.accentSecondary.withOpacity(0.32),
                  ),
                ),
                child: const SizedBox(width: 54, height: 54),
              ),
            ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(success ? 0.78 : 0.72),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: success
                    ? GameUiTokens.accentSecondary.withOpacity(0.92)
                    : GameUiTokens.accentPrimary.withOpacity(0.62),
              ),
              boxShadow: [
                BoxShadow(
                  color:
                      (success
                              ? GameUiTokens.accentSecondary
                              : GameUiTokens.accentPrimary)
                          .withOpacity(success ? 0.32 : 0.2),
                  blurRadius: success ? 18 : 14,
                  spreadRadius: success ? 2 : 1,
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (success) ...[
                  Icon(
                    Icons.check_circle,
                    size: 14,
                    color: GameUiTokens.accentSecondary,
                  ),
                  const SizedBox(width: 6),
                ],
                Text(
                  text,
                  style: GameUiText.command(
                    color: success
                        ? GameUiTokens.accentSecondary
                        : GameUiTokens.accentPrimary,
                    size: 12,
                    weight: FontWeight.w800,
                    letterSpacing: 0.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MapScreenState extends State<MapScreen> {
  mb.MapboxMap? _map;

  final h3.H3 _h3 = const h3.H3Factory().load();
  h3.H3Index? _currentCell;

  String _currentTile = '';
  bool _captured = false;
  GameTile _currentGameTile = const GameTile(
    h3Index: '',
    ownership: TileOwnership.neutral,
  );

  StreamSubscription<geo.Position>? _posSub;
  bool _tracking = false;
  bool _followMe = true;
  bool _sessionActive = false;
  String? _lastSessionCaptureAttemptHex;
  DateTime? _sessionStartedAt;
  double _sessionDistanceMeters = 0;
  double? _lastSessionLat;
  double? _lastSessionLng;
  int _sessionTilesCaptured = 0;
  int _sessionTilesRefreshed = 0;
  int _sessionRivalBlocked = 0;
  int _sessionTakeovers = 0;
  DateTime? _lastAutoCaptureAttemptAt;
  final Map<String, DateTime> _recentAutoCaptureByHex = {};
  String? _pendingAutoCaptureHex;
  DateTime? _enteredPendingTileAt;

  double? _lastLat;
  double? _lastLng;
  double? _lastAccuracy;

  static const int h3Resolution = 9;
  double _visibleRadiusMeters = GameRules.visibleCapturedRadiusMeters;
  static const double _recommendScoreMax = 100;
  static const double _recommendScoreBase = 26;
  static const double _recommendDistancePenaltyMax = 28;
  static const double _recommendStreakBonus = 24;
  static const double _recommendSectionPressureBonus = 18;
  static const double _recommendSectionFlipBonus = 22;
  static const double _recommendAtRiskDefenseBonus = 14;
  static const double _recommendStrengthenLeadBonus = 10;
  static const double _recommendNeutralBonus = 4;
  static const double _recommendRivalBonus = 2;
  static const double _recommendSwitchMargin = 6;
  static const double _recommendTieHoldMargin = 2;
  static const Duration _autoCaptureDebounce = Duration(seconds: 4);
  static const Duration _autoCaptureTileCooldown = Duration(seconds: 12);
  static const Duration _autoCaptureDwellTime = Duration(seconds: 5);
  static const String _prefsSessionActive = 'session_active_v1';
  static const String _prefsSessionLastHex = 'session_last_hex_v1';
  static const String _prefsSessionStartedAt = 'session_started_at_v1';
  static const String _prefsUnlockedMilestones = 'unlocked_milestones_v1';
  static const String _prefsHudPreference = 'hud_preference_v1';
  static const String _prefsSessionsStarted = 'sessions_started_count_v1';
  static const String _prefsShowPreviewEnemyTiles =
      'show_preview_enemy_tiles_v1';
  static const int _totalMilestoneCount = 8;

  late final CaptureService _captureService;
  late final MapRenderService _mapRenderService;
  late final MapController _mapController;
  late final TrailProgressService _trailProgressService;
  late final TrailSectionProgressService _trailSectionProgressService;
  final ObjectiveEngineService _objectiveEngine = ObjectiveEngineService();
  final MapEventLogService _eventLog = MapEventLogService();
  List<TrailProgress> _trailProgress = const [];
  List<TrailSectionProgress> _sectionProgress = const [];
  ObjectiveState _currentObjective = const ObjectiveState(title: 'Loading...');
  final Set<String> _unlockedMilestoneIds = <String>{};
  final List<String> _sessionMilestones = <String>[];
  bool _capturePulseActive = false;
  Timer? _capturePulseTimer;
  bool _legendVisible = false;
  bool _actionRailVisible = false;
  bool _mapLegendVisible = false;
  bool _bottomHudVisible = false;
  bool _compactHud = false;
  bool _showRecommendationDebug = false;
  HudPreference _hudPreference = HudPreference.auto;
  int _sessionsStartedCount = 0;
  bool _showPreviewEnemyTiles = true;
  Timer? _hudIntroTimer;
  Timer? _actionRailIntroTimer;
  Timer? _mapLegendIntroTimer;
  Timer? _bottomHudIntroTimer;
  Timer? _compactHudIdleTimer;
  Timer? _selectedTileTicker;
  Timer? _recommendedTilePulseTimer;
  String? _recommendedTileHex;
  bool _recommendedPulseOn = false;
  bool _isFirstSessionGuided = false;
  bool _firstCaptureCelebrated = false;
  bool _showPostCaptureGuidance = false;
  bool _guidedCameraCenteredOnce = false;
  String? _captureFeedbackText;
  bool _captureFeedbackSuccess = false;
  Timer? _captureFeedbackTimer;
  Timer? _postCaptureHintTimer;

  // Tap-to-select state
  List<GameTile> _visibleTiles = const [];
  GameTile? _selectedTile;
  String? _selectedHex;

  Timer? _nearbyRefreshTimer;

  int _simStep = 0;
  double? _simBaseLat;
  double? _simBaseLng;

  @override
  void initState() {
    super.initState();
    mb.MapboxOptions.setAccessToken(kMapboxAccessToken);

    _selectedTileTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _selectedTile == null) return;
      setState(() {});
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _hudIntroTimer = Timer(const Duration(milliseconds: 120), () {
        if (!mounted) return;
        setState(() {
          _legendVisible = true;
        });
      });
      _actionRailIntroTimer = Timer(const Duration(milliseconds: 210), () {
        if (!mounted) return;
        setState(() {
          _actionRailVisible = true;
        });
      });
      _mapLegendIntroTimer = Timer(const Duration(milliseconds: 300), () {
        if (!mounted) return;
        setState(() {
          _mapLegendVisible = true;
        });
      });
      _bottomHudIntroTimer = Timer(const Duration(milliseconds: 280), () {
        if (!mounted) return;
        setState(() {
          _bottomHudVisible = true;
        });
      });
    });

    _captureService = CaptureService(
      supabaseClient: Supabase.instance.client,
      h3Resolution: h3Resolution,
    );

    _mapRenderService = MapRenderService(
      h3Instance: _h3,
      h3Resolution: h3Resolution,
    );

    _mapController = MapController(
      locationService: LocationService(),
      captureService: _captureService,
      mapRenderService: _mapRenderService,
    );
    _trailProgressService = TrailProgressService();
    _trailSectionProgressService = TrailSectionProgressService();

    _initializeMapController();
    _loadMilestoneState();
    unawaited(_bootstrapInstantFirstCapture());
    _updateCurrentObjective();
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _nearbyRefreshTimer?.cancel();
    _capturePulseTimer?.cancel();
    _hudIntroTimer?.cancel();
    _actionRailIntroTimer?.cancel();
    _mapLegendIntroTimer?.cancel();
    _bottomHudIntroTimer?.cancel();
    _compactHudIdleTimer?.cancel();
    _selectedTileTicker?.cancel();
    _recommendedTilePulseTimer?.cancel();
    _captureFeedbackTimer?.cancel();
    _postCaptureHintTimer?.cancel();
    _mapRenderService.dispose();
    super.dispose();
  }

  void _triggerCapturePulse() {
    _capturePulseTimer?.cancel();
    if (mounted) {
      setState(() {
        _capturePulseActive = true;
      });
    }

    _capturePulseTimer = Timer(const Duration(milliseconds: 420), () {
      if (!mounted) return;
      setState(() {
        _capturePulseActive = false;
      });
    });
  }

  void _onMapInteraction() {
    if (!_compactHud && mounted) {
      setState(() {
        _compactHud = true;
      });
    }

    _compactHudIdleTimer?.cancel();
    _compactHudIdleTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      setState(() {
        _compactHud = false;
      });
    });
  }

  /// Called when the user taps the map — resolves the tapped hex and selects it.
  void _onMapTap(mb.MapContentGestureContext context) {
    _onMapInteraction();

    final coords = context.point.coordinates;
    final lat = coords.lat.toDouble();
    final lng = coords.lng.toDouble();

    final cell = _h3.geoToCell(h3.GeoCoord(lat: lat, lon: lng), h3Resolution);
    final hexLower = cell.toRadixString(16).toLowerCase();

    if (_selectedHex == hexLower) {
      // Second tap on same hex → deselect.
      _dismissSelection();
      return;
    }

    final tile = _visibleTiles
        .where((t) => t.h3Index.toLowerCase() == hexLower)
        .firstOrNull;

    // Only allow selecting visible hexes to avoid off-context selections.
    if (tile == null) {
      _dismissSelection();
      return;
    }

    setState(() {
      _selectedTile = tile;
      _selectedHex = hexLower;
    });
    unawaited(_mapRenderService.drawSelectionHex(hexLower));
    unawaited(_syncRecommendedTileGlow());

    final recommendedHex = _recommendedTileHex;
    if (_isGuidedFirstCaptureMode &&
        recommendedHex != null &&
        recommendedHex == hexLower) {
      unawaited(_handleGuidedRecommendedTileTap(tile));
    }
  }

  Future<void> _handleGuidedRecommendedTileTap(GameTile tile) async {
    await HapticFeedback.selectionClick();

    if (!_sessionActive) {
      _showCaptureFeedback('Start session to begin auto-capture');
      return;
    }

    if (!mounted) return;
    final selectedHex = tile.h3Index.toLowerCase();
    final isCurrentTile = _currentTile.toLowerCase() == selectedHex;

    if (isCurrentTile && _currentTile.isNotEmpty) {
      _showCaptureFeedback(
        'Hold position or keep moving - auto-capture is live',
      );
      return;
    }

    _showCaptureFeedback('Move to the glowing tile');
  }

  void _dismissSelection() {
    if (_selectedHex == null) return;
    setState(() {
      _selectedTile = null;
      _selectedHex = null;
    });
    unawaited(_mapRenderService.clearSelectionHex());
    unawaited(_syncRecommendedTileGlow());
  }

  Future<void> _initializeMapController() async {
    final result = await _mapController.initialize();
    if (mounted) {
      setState(() {});
      _refreshFirstSessionGuidanceState();
    }

    if (!result.synced && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Supabase not ready (offline mode): ${result.error}'),
        ),
      );
    }
  }

  Future<void> _loadSessionState() async {
    final prefs = await SharedPreferences.getInstance();
    final active = prefs.getBool(_prefsSessionActive) ?? false;
    final lastHex = prefs.getString(_prefsSessionLastHex);
    final startedAtRaw = prefs.getString(_prefsSessionStartedAt);
    final hudPreferenceRaw = prefs.getString(_prefsHudPreference);
    final sessionsStarted = prefs.getInt(_prefsSessionsStarted) ?? 0;
    final showPreviewEnemyTiles =
        prefs.getBool(_prefsShowPreviewEnemyTiles) ?? true;

    if (!mounted) return;
    setState(() {
      _sessionActive = active;
      _lastSessionCaptureAttemptHex = lastHex;
      _sessionStartedAt = startedAtRaw == null
          ? null
          : DateTime.tryParse(startedAtRaw);
      _sessionsStartedCount = sessionsStarted;
      _hudPreference = switch (hudPreferenceRaw) {
        'guided' => HudPreference.guided,
        'pro' => HudPreference.pro,
        _ => HudPreference.auto,
      };
      _showPreviewEnemyTiles = showPreviewEnemyTiles;
    });
    _refreshFirstSessionGuidanceState();

    if (_sessionActive) {
      _eventLog.log(
        MapEventType.sessionStarted,
        'Session restored after app resume/reopen',
        metadata: {'lastHex': _lastSessionCaptureAttemptHex},
      );
    }
  }

  Future<void> _bootstrapInstantFirstCapture() async {
    await _loadSessionState();

    final pos = await _mapController.getCurrentPosition(context);
    if (pos != null) {
      await _refreshMapForCoordinates(
        pos.latitude,
        pos.longitude,
        moveCamera: true,
        accuracy: pos.accuracy,
      );
      unawaited(_startTracking());
    }

    await _syncRecommendedTileGlow(currentLat: _lastLat, currentLng: _lastLng);
  }

  Future<void> _startSessionSilently({
    required bool incrementSessionCount,
  }) async {
    if (_sessionActive) return;

    if (mounted) {
      setState(() {
        _sessionActive = true;
        if (incrementSessionCount) {
          _sessionsStartedCount += 1;
        }
        _lastSessionCaptureAttemptHex = null;
        _sessionStartedAt = DateTime.now();
        _sessionDistanceMeters = 0;
        _sessionTilesCaptured = 0;
        _sessionTilesRefreshed = 0;
        _sessionRivalBlocked = 0;
        _sessionTakeovers = 0;
        _lastSessionLat = _lastLat;
        _lastSessionLng = _lastLng;
        _lastAutoCaptureAttemptAt = null;
        _recentAutoCaptureByHex.clear();
        _pendingAutoCaptureHex = null;
        _enteredPendingTileAt = null;
        _sessionMilestones.clear();
      });
    }

    await _saveSessionState();
    await _unlockMilestones([
      (id: 'first_session_start', title: '🎬 First session started'),
    ]);
    _eventLog.log(MapEventType.sessionStarted, 'Session started');
    _updateCurrentObjective();
  }

  void _refreshFirstSessionGuidanceState() {
    final hasCapturedAnyTile = _captureService.capturedHexes.isNotEmpty;
    final canArmGuidance =
        !_firstCaptureCelebrated &&
        !_isFirstSessionGuided &&
        _sessionsStartedCount == 0 &&
        !hasCapturedAnyTile;
    final shouldDisarmGuidance = _firstCaptureCelebrated || hasCapturedAnyTile;

    if (!mounted) {
      if (canArmGuidance) _isFirstSessionGuided = true;
      if (shouldDisarmGuidance) _isFirstSessionGuided = false;
      return;
    }

    if (!canArmGuidance &&
        !shouldDisarmGuidance &&
        _showPostCaptureGuidance == false) {
      return;
    }

    setState(() {
      if (canArmGuidance) {
        _isFirstSessionGuided = true;
      }
      if (shouldDisarmGuidance) {
        _isFirstSessionGuided = false;
      }
      if (shouldDisarmGuidance && !_showPostCaptureGuidance) {
        _showPostCaptureGuidance = false;
      }
    });
  }

  bool get _isGuidedFirstCaptureMode =>
      _isFirstSessionGuided && !_firstCaptureCelebrated;

  Future<void> _startGuidedSessionFromCta() async {
    if (_sessionActive) return;

    await HapticFeedback.mediumImpact();
    await _startSessionSilently(incrementSessionCount: true);
    if (!_tracking) {
      unawaited(_startTracking());
    }
    if (!mounted) return;

    _showCaptureFeedback(
      'Session live - Move to the glowing tile',
      duration: const Duration(milliseconds: 1900),
    );
    await _syncRecommendedTileGlow(currentLat: _lastLat, currentLng: _lastLng);
  }

  void _showCaptureFeedback(
    String text, {
    bool success = false,
    Duration duration = const Duration(milliseconds: 1700),
  }) {
    _captureFeedbackTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _captureFeedbackText = text;
      _captureFeedbackSuccess = success;
    });
    _captureFeedbackTimer = Timer(duration, () {
      if (!mounted) return;
      setState(() {
        _captureFeedbackText = null;
        _captureFeedbackSuccess = false;
      });
    });
  }

  void _onFirstCaptureCompleted() {
    if (_firstCaptureCelebrated) return;
    _firstCaptureCelebrated = true;
    _isFirstSessionGuided = false;
    _showPostCaptureGuidance = true;
    _dismissSelection();
    _showCaptureFeedback(
      '+1 TILE SECURED',
      success: true,
      duration: const Duration(milliseconds: 2100),
    );
    unawaited(
      _syncRecommendedTileGlow(currentLat: _lastLat, currentLng: _lastLng),
    );
    _postCaptureHintTimer?.cancel();
    _postCaptureHintTimer = Timer(const Duration(milliseconds: 2800), () {
      if (!mounted) return;
      setState(() {
        _showPostCaptureGuidance = false;
      });
    });
  }

  Future<void> _saveSessionState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsSessionActive, _sessionActive);
    final hudPreferenceRaw = switch (_hudPreference) {
      HudPreference.auto => 'auto',
      HudPreference.guided => 'guided',
      HudPreference.pro => 'pro',
    };
    await prefs.setString(_prefsHudPreference, hudPreferenceRaw);
    await prefs.setInt(_prefsSessionsStarted, _sessionsStartedCount);
    await prefs.setBool(_prefsShowPreviewEnemyTiles, _showPreviewEnemyTiles);

    if (_lastSessionCaptureAttemptHex == null) {
      await prefs.remove(_prefsSessionLastHex);
    } else {
      await prefs.setString(
        _prefsSessionLastHex,
        _lastSessionCaptureAttemptHex!,
      );
    }

    if (_sessionStartedAt == null) {
      await prefs.remove(_prefsSessionStartedAt);
    } else {
      await prefs.setString(
        _prefsSessionStartedAt,
        _sessionStartedAt!.toIso8601String(),
      );
    }
  }

  Future<void> _loadMilestoneState() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(_prefsUnlockedMilestones) ?? const [];
    if (!mounted) return;
    setState(() {
      _unlockedMilestoneIds
        ..clear()
        ..addAll(stored);
    });
  }

  Future<void> _saveMilestoneState() async {
    final prefs = await SharedPreferences.getInstance();
    final values = _unlockedMilestoneIds.toList()..sort();
    await prefs.setStringList(_prefsUnlockedMilestones, values);
  }

  Future<void> _refreshMapForCoordinates(
    double lat,
    double lng, {
    required bool moveCamera,
    double? accuracy,
  }) async {
    _lastLat = lat;
    _lastLng = lng;
    if (accuracy != null) {
      _lastAccuracy = accuracy;
    }

    if (_sessionActive) {
      if (_lastSessionLat != null && _lastSessionLng != null) {
        final d = MapRenderService.haversineMeters(
          _lastSessionLat!,
          _lastSessionLng!,
          lat,
          lng,
        );
        if (d > 0 && d < 300) {
          _sessionDistanceMeters += d;
        }
      }
      _lastSessionLat = lat;
      _lastSessionLng = lng;
    }

    final previousHex = _currentCell?.toRadixString(16).toLowerCase();

    final result = await _mapController.refreshMapForCoordinates(
      lat,
      lng,
      radiusMeters: _visibleRadiusMeters,
      includePreviewEnemyTiles: _showPreviewEnemyTiles,
    );
    _applyRefreshResult(result, currentLat: lat, currentLng: lng);

    await _maybeAutoCaptureOnTileEntry(
      previousHex: previousHex,
      currentHex: result.currentHex,
      latitude: lat,
      longitude: lng,
      accuracy: accuracy,
    );

    final cameraUpdate = _mapController.buildCameraUpdate(
      lat,
      lng,
      moveCamera: moveCamera,
    );
    if (cameraUpdate != null) {
      _map?.flyTo(
        mb.CameraOptions(
          center: mb.Point(
            coordinates: mb.Position(
              cameraUpdate.longitude,
              cameraUpdate.latitude,
            ),
          ),
          zoom: cameraUpdate.zoom,
        ),
        mb.MapAnimationOptions(duration: cameraUpdate.durationMs),
      );
    }

    _nearbyRefreshTimer ??= _mapController.startPeriodicRefresh(
      onRefresh: () async {
        final lat = _lastLat;
        final lng = _lastLng;
        if (lat == null || lng == null) return;
        await _refreshMapForCoordinates(lat, lng, moveCamera: false);
      },
    );
  }

  Future<void> _maybeAutoCaptureOnTileEntry({
    required String? previousHex,
    required String currentHex,
    required double latitude,
    required double longitude,
    required double? accuracy,
  }) async {
    if (!_sessionActive) {
      _pendingAutoCaptureHex = null;
      _enteredPendingTileAt = null;
      return;
    }

    final now = DateTime.now();

    if (previousHex != currentHex) {
      _pendingAutoCaptureHex = currentHex;
      _enteredPendingTileAt = now;
      return;
    }

    if (_pendingAutoCaptureHex != currentHex) {
      _pendingAutoCaptureHex = currentHex;
      _enteredPendingTileAt = now;
      return;
    }

    final enteredAt = _enteredPendingTileAt;
    if (enteredAt == null ||
        now.difference(enteredAt) < _autoCaptureDwellTime) {
      return;
    }

    if (_lastSessionCaptureAttemptHex == currentHex) return;
    if (_lastAutoCaptureAttemptAt != null &&
        now.difference(_lastAutoCaptureAttemptAt!) < _autoCaptureDebounce) {
      return;
    }
    final recent = _recentAutoCaptureByHex[currentHex];
    if (recent != null && now.difference(recent) < _autoCaptureTileCooldown) {
      return;
    }

    _recentAutoCaptureByHex.removeWhere(
      (_, t) => now.difference(t) > const Duration(minutes: 2),
    );

    _lastSessionCaptureAttemptHex = currentHex;
    _lastAutoCaptureAttemptAt = now;
    _recentAutoCaptureByHex[currentHex] = now;
    unawaited(_saveSessionState());

    final flowResult = await _mapController.captureAndRefreshForCoordinates(
      currentHex: currentHex,
      latitude: latitude,
      longitude: longitude,
      accuracy: accuracy,
      userId: _mapController.currentUserId,
      radiusMeters: _visibleRadiusMeters,
      includePreviewEnemyTiles: _showPreviewEnemyTiles,
    );

    final result = flowResult.captureAttempt;
    if (!mounted) return;

    if (result.didCapture) {
      final refresh = flowResult.refresh;
      if (refresh != null) {
        _applyRefreshResult(
          refresh,
          currentLat: latitude,
          currentLng: longitude,
        );
      }

      _triggerCapturePulse();
      if (_isGuidedFirstCaptureMode) {
        await HapticFeedback.heavyImpact();
        _onFirstCaptureCompleted();
      } else {
        await HapticFeedback.lightImpact();
      }

      _updateSessionSummaryCounters(result);

      final message = switch (result.status) {
        CaptureAttemptStatus.takeoverCaptured =>
          result.synced
              ? 'Auto-capture takeover ✅ (synced)'
              : 'Auto-capture takeover ✅ (saved locally)',
        CaptureAttemptStatus.protectionRefreshed =>
          result.synced
              ? 'Auto-capture refreshed protection ✅ (synced)'
              : 'Auto-capture refreshed protection ✅ (saved locally)',
        _ =>
          result.synced
              ? 'Auto-capture success ✅ (synced)'
              : 'Auto-capture success ✅ (saved locally)',
      };

      _logCaptureEvent(result, currentHex, auto: true);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
      return;
    }

    if (result.status == CaptureAttemptStatus.protectedByRival) {
      _updateSessionSummaryCounters(result);
      _logCaptureEvent(result, currentHex, auto: true);

      final protectedHint = result.protectedUntil == null
          ? 'Auto-capture blocked: rival protection active'
          : 'Auto-capture blocked: protected for ${_formatDuration(result.protectedUntil!.difference(DateTime.now()))}';

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(protectedHint)));
    }
  }

  void _applyRefreshResult(
    MapRefreshResult result, {
    double? currentLat,
    double? currentLng,
  }) {
    final cell = BigInt.parse(result.currentHex, radix: 16);
    var shouldClearSelection = false;
    setState(() {
      _currentCell = cell;
      _currentTile = result.currentHex;
      _captured = result.isCaptured;
      _currentGameTile = result.currentTile;
      _visibleTiles = result.visibleTiles;
      // Refresh selected tile info when map updates.
      if (_selectedHex != null) {
        final refreshed = result.visibleTiles
            .where((t) => t.h3Index.toLowerCase() == _selectedHex)
            .firstOrNull;
        if (refreshed != null) {
          _selectedTile = refreshed;
        } else {
          _selectedTile = null;
          _selectedHex = null;
          shouldClearSelection = true;
        }
      }
      _trailProgress = _trailProgressService.calculateProgress(
        _captureService.capturedHexes,
        currentLat: currentLat,
        currentLng: currentLng,
      );
      _sectionProgress = _trailSectionProgressService.calculateProgress(
        capturedHexes: _captureService.capturedHexes,
        knownOwnerByHex: _captureService.getKnownOwnerByHex(),
        currentUserId: _captureService.currentUserId,
        currentLat: currentLat,
        currentLng: currentLng,
      );
    });

    if (shouldClearSelection) {
      unawaited(_mapRenderService.clearSelectionHex());
    }

    unawaited(_evaluateMilestones());
    _updateCurrentObjective();
    _refreshFirstSessionGuidanceState();
    unawaited(
      _syncRecommendedTileGlow(currentLat: currentLat, currentLng: currentLng),
    );
  }

  bool _isTileCapturable(GameTile tile) {
    if (tile.ownership == TileOwnership.mine) return false;
    if (tile.ownership == TileOwnership.neutral) return true;
    final until = tile.protectedUntil;
    return until == null || !until.isAfter(DateTime.now());
  }

  double? _distanceToTileMeters(GameTile tile, {double? lat, double? lng}) {
    final userLat = lat ?? _lastLat;
    final userLng = lng ?? _lastLng;
    if (userLat == null || userLng == null) return null;

    try {
      final hexLower = tile.h3Index.toLowerCase();
      final cell = BigInt.parse(hexLower, radix: 16);
      final centroid = _mapRenderService.cellCentroid(cell, hexLower);
      return MapRenderService.haversineMeters(
        userLat,
        userLng,
        centroid.lat,
        centroid.lng,
      );
    } catch (_) {
      return null;
    }
  }

  String? _streakDirectionHint() {
    final currentLat = _lastLat;
    final currentLng = _lastLng;
    if (currentLat == null || currentLng == null) return null;

    final streak =
        _trailProgress
            .where(
              (p) =>
                  !p.isComplete &&
                  p.bestNextTileH3 != null &&
                  p.bestNextTileReason == TrailNextTileReason.extendStreak,
            )
            .toList()
          ..sort(
            (a, b) => (a.bestNextTileDistanceMeters ?? double.infinity)
                .compareTo(b.bestNextTileDistanceMeters ?? double.infinity),
          );

    if (streak.isEmpty) return null;
    final hex = streak.first.bestNextTileH3;
    if (hex == null || hex.isEmpty) return null;

    try {
      final lower = hex.toLowerCase();
      final cell = BigInt.parse(lower, radix: 16);
      final centroid = _mapRenderService.cellCentroid(cell, lower);
      final dLat = centroid.lat - currentLat;
      final dLng = centroid.lng - currentLng;

      if (dLat.abs() >= dLng.abs()) {
        return dLat >= 0 ? 'north' : 'south';
      }
      return dLng >= 0 ? 'east' : 'west';
    } catch (_) {
      return null;
    }
  }

  ({bool pressure, bool canFlip, bool atRiskDefense, bool strengthensLead})
  _sectionSignalsForHex(String hexLower) {
    var pressure = false;
    var canFlip = false;
    var atRiskDefense = false;
    var strengthensLead = false;

    for (final section in _sectionProgress) {
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

  ({
    double score,
    double distance,
    double distancePenalty,
    double streakBonus,
    double sectionPressureBonus,
    double sectionFlipBonus,
    double atRiskDefenseBonus,
    double strengthenLeadBonus,
    double ownershipBonus,
    GameTile tile,
  })
  _scoreRecommendationCandidate(
    GameTile tile,
    double distance,
    Set<String> streakTargetHexes,
  ) {
    final hexLower = tile.h3Index.toLowerCase();
    final signals = _sectionSignalsForHex(hexLower);

    var score = _recommendScoreBase;
    final streakBonus = streakTargetHexes.contains(hexLower)
        ? _recommendStreakBonus
        : 0.0;
    final sectionPressureBonus = signals.pressure
        ? _recommendSectionPressureBonus
        : 0.0;
    final sectionFlipBonus = signals.canFlip ? _recommendSectionFlipBonus : 0.0;
    final atRiskDefenseBonus = signals.atRiskDefense
        ? _recommendAtRiskDefenseBonus
        : 0.0;
    final strengthenLeadBonus = signals.strengthensLead
        ? _recommendStrengthenLeadBonus
        : 0.0;
    final ownershipBonus = switch (tile.ownership) {
      TileOwnership.neutral => _recommendNeutralBonus,
      TileOwnership.enemy => _recommendRivalBonus,
      TileOwnership.mine => 0.0,
    };

    final normalized = (distance / MapController.maxCaptureDistanceMeters)
        .clamp(0.0, 1.0);
    final distancePenalty = normalized * _recommendDistancePenaltyMax;
    score -= distancePenalty;

    score += streakBonus;
    score += sectionPressureBonus;
    score += sectionFlipBonus;
    score += atRiskDefenseBonus;
    score += strengthenLeadBonus;
    score += ownershipBonus;

    score = score.clamp(0, _recommendScoreMax).toDouble();
    return (
      score: score,
      distance: distance,
      distancePenalty: distancePenalty,
      streakBonus: streakBonus,
      sectionPressureBonus: sectionPressureBonus,
      sectionFlipBonus: sectionFlipBonus,
      atRiskDefenseBonus: atRiskDefenseBonus,
      strengthenLeadBonus: strengthenLeadBonus,
      ownershipBonus: ownershipBonus,
      tile: tile,
    );
  }

  List<
    ({
      double score,
      double distance,
      double distancePenalty,
      double streakBonus,
      double sectionPressureBonus,
      double sectionFlipBonus,
      double atRiskDefenseBonus,
      double strengthenLeadBonus,
      double ownershipBonus,
      GameTile tile,
    })
  >
  _rankRecommendationCandidates({double? lat, double? lng}) {
    final withDistance = _visibleTiles
        .where(_isTileCapturable)
        .map(
          (tile) =>
              (tile: tile, d: _distanceToTileMeters(tile, lat: lat, lng: lng)),
        )
        .where((entry) => entry.d != null)
        .map((entry) => (tile: entry.tile, d: entry.d!))
        .where((entry) => entry.d <= MapController.maxCaptureDistanceMeters)
        .toList(growable: false);
    if (withDistance.isEmpty) return const [];

    final streakTargetHexes = _trailProgress
        .where((p) => p.bestNextTileReason == TrailNextTileReason.extendStreak)
        .map((p) => p.bestNextTileH3?.toLowerCase())
        .whereType<String>()
        .toSet();

    final scored = withDistance
        .map(
          (entry) => _scoreRecommendationCandidate(
            entry.tile,
            entry.d,
            streakTargetHexes,
          ),
        )
        .toList(growable: false);

    final ranked = scored.toList()
      ..sort((a, b) {
        final byScore = b.score.compareTo(a.score);
        if (byScore != 0) return byScore;

        final aNeutral = a.tile.ownership == TileOwnership.neutral;
        final bNeutral = b.tile.ownership == TileOwnership.neutral;
        if (aNeutral != bNeutral) return aNeutral ? -1 : 1;

        return a.distance.compareTo(b.distance);
      });

    return ranked;
  }

  GameTile? _bestRecommendedCapturableTile({double? lat, double? lng}) {
    if (!_sessionActive && !_isGuidedFirstCaptureMode) return null;
    final guidedMode = _resolveHudPersonality() == HudPersonality.guided;
    if (_selectedHex != null && !_isGuidedFirstCaptureMode && !guidedMode) {
      return null;
    }

    if (_isGuidedFirstCaptureMode && _currentTile.isNotEmpty) {
      final currentHex = _currentTile.toLowerCase();
      final currentTile = _visibleTiles
          .where((t) => t.h3Index.toLowerCase() == currentHex)
          .firstOrNull;
      if (currentTile != null && _isTileCapturable(currentTile)) {
        return currentTile;
      }
    }

    final ranked = _rankRecommendationCandidates(lat: lat, lng: lng);
    if (ranked.isEmpty) return null;

    var chosen = ranked.first;

    final currentHex = _recommendedTileHex;
    if (currentHex != null) {
      final currentCandidates = ranked
          .where((item) => item.tile.h3Index.toLowerCase() == currentHex)
          .toList(growable: false);
      final current = currentCandidates.isEmpty
          ? null
          : currentCandidates.first;

      if (current != null &&
          chosen.tile.h3Index.toLowerCase() != currentHex &&
          chosen.score < current.score + _recommendSwitchMargin) {
        chosen = current;
      }

      if (current != null &&
          chosen.tile.h3Index.toLowerCase() != currentHex &&
          (chosen.score - current.score).abs() <= _recommendTieHoldMargin) {
        chosen = current;
      }
    }

    return chosen.tile;
  }

  String? _guidedPriorityTargetHex() {
    if (!_sessionActive && !_isGuidedFirstCaptureMode) return null;
    final fallback = _bestRecommendedCapturableTile(
      lat: _lastLat,
      lng: _lastLng,
    );
    return _recommendedTileHex ?? fallback?.h3Index.toLowerCase();
  }

  Future<void> _clearRecommendedTileGlow() async {
    _recommendedTilePulseTimer?.cancel();
    _recommendedTilePulseTimer = null;
    _recommendedTileHex = null;
    _recommendedPulseOn = false;
    await _mapRenderService.clearRecommendedHex();
  }

  void _ensureRecommendedPulseTimer() {
    if (_recommendedTilePulseTimer != null) return;
    _recommendedTilePulseTimer = Timer.periodic(
      const Duration(milliseconds: 950),
      (_) {
        final hex = _recommendedTileHex;
        if (hex == null) return;

        _recommendedPulseOn = !_recommendedPulseOn;
        final strong = _resolveHudPersonality() == HudPersonality.guided;
        unawaited(
          _mapRenderService.drawRecommendedHex(
            hex,
            pulseOn: _recommendedPulseOn,
            strong: strong,
          ),
        );
      },
    );
  }

  Future<void> _syncRecommendedTileGlow({
    double? currentLat,
    double? currentLng,
  }) async {
    final hudPersonality = _resolveHudPersonality();
    final guidedMode = hudPersonality == HudPersonality.guided;
    final proMode = hudPersonality == HudPersonality.pro;
    final showInPro = _currentObjective.actionLabel == 'Capture';

    if ((!_sessionActive && !_isGuidedFirstCaptureMode) ||
        (proMode && !showInPro && !_isGuidedFirstCaptureMode) ||
        (_selectedHex != null && !_isGuidedFirstCaptureMode && !guidedMode)) {
      await _clearRecommendedTileGlow();
      return;
    }

    final candidate = _bestRecommendedCapturableTile(
      lat: currentLat,
      lng: currentLng,
    );
    if (candidate == null) {
      await _clearRecommendedTileGlow();
      return;
    }

    final hex = candidate.h3Index.toLowerCase();
    _recommendedTileHex = hex;
    _ensureRecommendedPulseTimer();

    _recommendedPulseOn = !_recommendedPulseOn;
    await _mapRenderService.drawRecommendedHex(
      hex,
      pulseOn: _recommendedPulseOn,
      strong: guidedMode || _isGuidedFirstCaptureMode,
    );

    if (_isGuidedFirstCaptureMode && !_guidedCameraCenteredOnce) {
      try {
        final cell = BigInt.parse(hex, radix: 16);
        final center = _mapRenderService.cellCentroid(cell, hex);
        _map?.flyTo(
          mb.CameraOptions(
            center: mb.Point(coordinates: mb.Position(center.lng, center.lat)),
            zoom: 16.1,
          ),
          mb.MapAnimationOptions(duration: 900),
        );
        _guidedCameraCenteredOnce = true;
      } catch (_) {
        // Keep guidance running even if centroid conversion fails.
      }
    }
  }

  Widget _buildRecommendationDebugCard() {
    final ranked = _rankRecommendationCandidates();
    final top = ranked.take(3).toList(growable: false);
    final active = _recommendedTileHex;

    return FrostedOverlayCard(
      borderRadius: const BorderRadius.all(Radius.circular(12)),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      emphasized: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Reco Debug (Top 3)',
              style: GameUiText.command(size: 11, letterSpacing: 0.35),
            ),
            const SizedBox(height: 4),
            if (top.isEmpty)
              Text(
                'No capturable candidates in range.',
                style: GameUiText.meta(color: GameUiTokens.textMid),
              )
            else
              for (final entry in top)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '${entry.tile.h3Index.substring(0, 6)} '
                    'S:${entry.score.toStringAsFixed(1)} '
                    'D:${entry.distance.toStringAsFixed(0)}m '
                    '(dist-${entry.distancePenalty.toStringAsFixed(1)} '
                    '+stk${entry.streakBonus.toStringAsFixed(0)} '
                    '+prs${entry.sectionPressureBonus.toStringAsFixed(0)} '
                    '+flp${entry.sectionFlipBonus.toStringAsFixed(0)} '
                    '+def${entry.atRiskDefenseBonus.toStringAsFixed(0)} '
                    '+lead${entry.strengthenLeadBonus.toStringAsFixed(0)} '
                    '+own${entry.ownershipBonus.toStringAsFixed(0)})',
                    style: GameUiText.meta(
                      color: active == entry.tile.h3Index.toLowerCase()
                          ? GameUiTokens.accentSecondary
                          : GameUiTokens.textMid,
                      size: 10,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Future<void> _evaluateMilestones() async {
    final burke = _trailProgress
        .where((p) => p.trail.id == 'burke_gilman')
        .toList();
    final burkeProgress = burke.isEmpty ? null : burke.first;

    final checks = <({String id, String title, bool unlockedNow})>[
      (
        id: 'first_session_start',
        title: '🎬 First session started',
        unlockedNow: _sessionsStartedCount > 0,
      ),
      (
        id: 'first_tile',
        title: '🏁 First tile captured',
        unlockedNow: _captureService.capturedHexes.isNotEmpty,
      ),
      (
        id: 'streak_3',
        title: '🔥 3-tile streak reached',
        unlockedNow: _trailProgress.any((p) => p.longestOwnedSegmentTiles >= 3),
      ),
      (
        id: 'streak_5',
        title: '🔥 5-tile streak reached',
        unlockedNow: _trailProgress.any((p) => p.longestOwnedSegmentTiles >= 5),
      ),
      (
        id: 'streak_10',
        title: '⚡ 10-tile streak reached',
        unlockedNow: _trailProgress.any(
          (p) => p.longestOwnedSegmentTiles >= 10,
        ),
      ),
      (
        id: 'burke_25',
        title: '🗺️ Burke-Gilman 25% complete',
        unlockedNow: (burkeProgress?.completionPercent ?? 0) >= 25,
      ),
      (
        id: 'first_trail_complete',
        title: '🏆 Completed first trail',
        unlockedNow: _trailProgress.any((p) => p.isComplete),
      ),
      (
        id: 'first_section_contested',
        title: '⚔️ First section contested',
        unlockedNow: _sectionProgress.any(
          (s) => s.controlState == SectionControlState.contested,
        ),
      ),
    ];

    final unlockedChecks = checks
        .where((check) => check.unlockedNow)
        .map((check) => (id: check.id, title: check.title))
        .toList(growable: false);

    await _unlockMilestones(unlockedChecks);
  }

  Future<void> _unlockMilestones(
    List<({String id, String title})> checks,
  ) async {
    if (checks.isEmpty) return;

    final newlyUnlocked = <({String id, String title})>[];
    for (final check in checks) {
      if (!_unlockedMilestoneIds.contains(check.id)) {
        _unlockedMilestoneIds.add(check.id);
        newlyUnlocked.add((id: check.id, title: check.title));
      }
    }

    if (newlyUnlocked.isEmpty) return;

    await _saveMilestoneState();

    if (mounted) {
      setState(() {
        _sessionMilestones.addAll(newlyUnlocked.map((m) => m.title));
      });
    }

    for (final unlocked in newlyUnlocked) {
      _eventLog.log(
        MapEventType.milestoneUnlocked,
        'Milestone unlocked',
        metadata: {'milestone': unlocked.title},
      );

      if (!mounted) continue;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Milestone unlocked: ${unlocked.title}')),
      );

      final momentumPrompt = _milestoneMomentumPrompt(unlocked.id);
      if (momentumPrompt != null) {
        await Future<void>.delayed(const Duration(milliseconds: 220));
        if (!mounted) continue;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(momentumPrompt)));
      }

      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  String? _milestoneMomentumPrompt(String milestoneId) {
    switch (milestoneId) {
      case 'first_tile':
        final next = _bestRecommendedCapturableTile();
        if (next != null) {
          return 'Momentum: Capture the next nearby tile to build your streak.';
        }
        return 'Momentum: Move to the next visible tile and keep expanding.';
      case 'streak_3':
        final extend = _trailProgress
            .where(
              (p) =>
                  !p.isComplete &&
                  p.bestNextTileReason == TrailNextTileReason.extendStreak,
            )
            .cast<TrailProgress?>()
            .firstWhere((_) => true, orElse: () => null);
        if (extend != null) {
          return 'Momentum: Push the next ${extend.trail.name} tile to keep the streak climbing.';
        }
        return 'Momentum: Keep your streak alive with the next open tile.';
      case 'first_section_contested':
        final contested = _sectionProgress
            .where((s) => s.controlState == SectionControlState.contested)
            .cast<TrailSectionProgress?>()
            .firstWhere((_) => true, orElse: () => null);
        if (contested != null) {
          return 'Momentum: ${contested.section.name} is contested - one strong capture can swing control.';
        }
        return 'Momentum: Keep pressure on rival sections to flip control.';
      default:
        return null;
    }
  }

  String _formatDuration(Duration d) {
    final totalMinutes = d.inMinutes < 0 ? 0 : d.inMinutes;
    final hours = totalMinutes ~/ 60;
    final minutes = totalMinutes % 60;
    if (hours <= 0) return '${minutes}m';
    return '${hours}h ${minutes}m';
  }

  String _formatSince(DateTime? ts) {
    if (ts == null) return 'Unknown';
    final diff = DateTime.now().difference(ts);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  String _ownerLabel(GameTile tile) {
    if (tile.ownership == TileOwnership.neutral) return 'Neutral';
    if (tile.ownership == TileOwnership.mine) return 'You';
    final owner = tile.ownerId;
    if (owner == null || owner.isEmpty) return 'Rival';
    final short = owner.length > 6 ? owner.substring(0, 6) : owner;
    return 'Player$short';
  }

  String _protectionLabel(GameTile tile) {
    if (tile.ownership == TileOwnership.neutral) return 'No protection';
    final protectedUntil = tile.protectedUntil;
    if (protectedUntil == null) return 'Protection unknown';

    final remaining = protectedUntil.difference(DateTime.now());
    if (remaining.isNegative || remaining.inSeconds <= 0) {
      return tile.ownership == TileOwnership.mine
          ? 'Your protection expired'
          : 'Rival tile is capturable';
    }
    return 'Protected for ${_formatDuration(remaining)}';
  }

  Future<void> _showCurrentTileDetails() async {
    if (!mounted || _currentTile.isEmpty) return;

    await showTileDetailsDialog(
      context,
      ownerLabel: _ownerLabel(_currentGameTile),
      capturedSince: _formatSince(_currentGameTile.capturedAt),
      ownership: _currentGameTile.ownership,
      protectedUntil: _currentGameTile.protectedUntil,
    );
  }

  int _longestProtectionStreak(List<MapEvent> events) {
    final perHex = <String, int>{};
    var best = 0;

    for (final event in events) {
      if (event.type != MapEventType.protectionRefreshed) continue;
      final hex = event.metadata['hex'];
      if (hex is! String || hex.isEmpty) continue;

      final next = (perHex[hex] ?? 0) + 1;
      perHex[hex] = next;
      if (next > best) best = next;
    }
    return best;
  }

  Future<void> _showLeaderboard() async {
    final now = DateTime.now();
    final weekStart = now.subtract(const Duration(days: 7));
    final events = _eventLog.events;

    final capturesThisWeek = events.where((e) {
      final captureLike =
          e.type == MapEventType.tileCaptured ||
          e.type == MapEventType.rivalTakeover;
      return captureLike && e.timestamp.isAfter(weekStart);
    }).length;

    final currentlyOwned = _captureService.capturedHexes.length;
    final longestStreak = _longestProtectionStreak(events);

    if (!mounted) return;
    await showLeaderboardDialog(
      context,
      stats: LocalLeaderboardStats(
        capturesThisWeek: capturesThisWeek,
        currentlyOwned: currentlyOwned,
        longestProtectionStreak: longestStreak,
        trailProgress: _trailProgress,
      ),
    );
  }

  String _trailProgressInlineText() {
    if (_trailProgress.isEmpty) {
      return 'Burke-Gilman: 0 / 0 • Sammamish River: 0 / 0';
    }

    final ordered = _trailProgress.toList()
      ..sort((a, b) => a.trail.name.compareTo(b.trail.name));
    return ordered
        .map(
          (p) =>
              '${p.trail.name}: ${p.ownedTiles}/${p.totalTiles} (${p.completionPercent.toStringAsFixed(0)}%)',
        )
        .join(' • ');
  }

  String _controlLabel(SectionControlState state) {
    return switch (state) {
      SectionControlState.you => 'You control',
      SectionControlState.rival => 'Rival leads',
      SectionControlState.contested => 'Contested',
      SectionControlState.unclaimed => 'Unclaimed',
    };
  }

  String _ownerDisplay(String? ownerId) {
    if (ownerId == null || ownerId.isEmpty) return '--';
    if (ownerId == '__local_player__' ||
        ownerId == _captureService.currentUserId) {
      return 'You';
    }
    final short = ownerId.length > 6 ? ownerId.substring(0, 6) : ownerId;
    return 'Player$short';
  }

  String _sectionSummaryText() {
    if (_sectionProgress.isEmpty) {
      return 'Sections: --';
    }

    final ordered = _sectionProgress.toList()
      ..sort((a, b) {
        final byPercent = b.completionPercent.compareTo(a.completionPercent);
        if (byPercent != 0) return byPercent;
        return a.section.name.compareTo(b.section.name);
      });

    final top = ordered.first;
    return '${top.section.name}: ${top.ownedTiles}/${top.totalTiles} (${top.completionPercent.toStringAsFixed(0)}%) • ${_controlLabel(top.controlState)} • Lead: ${_ownerDisplay(top.leadingOwnerId)}';
  }

  String _sectionObjectiveText() {
    if (_sectionProgress.isEmpty) return 'Section objective: --';

    final candidates =
        _sectionProgress
            .where((s) => !s.isComplete && s.bestNextTileH3 != null)
            .toList()
          ..sort(
            (a, b) => (a.bestNextTileDistanceMeters ?? double.infinity)
                .compareTo(b.bestNextTileDistanceMeters ?? double.infinity),
          );

    if (candidates.isEmpty) return 'Section objective: complete';
    final next = candidates.first;
    final dist = next.bestNextTileDistanceMeters == null
        ? '--'
        : _formatDistanceMeters(next.bestNextTileDistanceMeters!);

    return 'Section objective: ${next.section.name} • $dist • +${next.projectedGainTiles} streak';
  }

  String _sectionControlPressureText() {
    if (_sectionProgress.isEmpty) return 'Section control: --';

    final contested = _sectionProgress
        .where((s) => s.controlState == SectionControlState.contested)
        .toList();
    if (contested.isNotEmpty) {
      contested.sort((a, b) => a.section.name.compareTo(b.section.name));
      return '${contested.first.section.name}: Contested section • Next capture flips section';
    }

    final takeControl =
        _sectionProgress.where((s) => s.tilesToTakeControl > 0).toList()..sort(
          (a, b) => a.tilesToTakeControl.compareTo(b.tilesToTakeControl),
        );
    if (takeControl.isNotEmpty) {
      final sec = takeControl.first;
      final plural = sec.tilesToTakeControl == 1 ? '' : 's';
      return '${sec.section.name}: ${sec.tilesToTakeControl} tile$plural to take control';
    }

    final atRisk = _sectionProgress.where((s) => s.isAtRisk).toList();
    if (atRisk.isNotEmpty) {
      atRisk.sort((a, b) => a.section.name.compareTo(b.section.name));
      return '${atRisk.first.section.name}: at risk';
    }

    final flippable = _sectionProgress
        .where((s) => s.canFlipWithNextCapture)
        .toList();
    if (flippable.isNotEmpty) {
      flippable.sort((a, b) => a.section.name.compareTo(b.section.name));
      return '${flippable.first.section.name}: Next capture flips section';
    }

    return 'Section control stable';
  }

  Future<void> _showSectionProgress() async {
    if (!mounted) return;
    await showSectionProgressDialog(context, sections: _sectionProgress);
  }

  String _formatDistanceMeters(double meters) {
    if (meters < 1000) return '${meters.toStringAsFixed(0)}m';
    return '${(meters / 1000).toStringAsFixed(2)}km';
  }

  String _nearestTrailHintText() {
    String reasonLabel(TrailNextTileReason? reason) {
      return switch (reason) {
        TrailNextTileReason.extendStreak => 'streak boost',
        TrailNextTileReason.bridgeGap => 'route link',
        TrailNextTileReason.startTrail => 'trail start',
        TrailNextTileReason.nearestMissing => 'nearest target',
        null => 'next target',
      };
    }

    if (_trailProgress.isEmpty) return 'Next objective: --';

    final objectiveCandidates =
        _trailProgress
            .where((p) => !p.isComplete && p.bestNextTileH3 != null)
            .toList()
          ..sort(
            (a, b) => (a.bestNextTileDistanceMeters ?? double.infinity)
                .compareTo(b.bestNextTileDistanceMeters ?? double.infinity),
          );

    if (objectiveCandidates.isNotEmpty) {
      final next = objectiveCandidates.first;
      final dist = next.bestNextTileDistanceMeters == null
          ? '--'
          : _formatDistanceMeters(next.bestNextTileDistanceMeters!);
      return 'Target ${next.trail.name} • $dist • ${reasonLabel(next.bestNextTileReason)}';
    }

    final fallbackCandidates =
        _trailProgress
            .where(
              (p) =>
                  !p.isComplete && p.nearestMissingTileDistanceMeters != null,
            )
            .toList()
          ..sort(
            (a, b) => a.nearestMissingTileDistanceMeters!.compareTo(
              b.nearestMissingTileDistanceMeters!,
            ),
          );

    if (fallbackCandidates.isNotEmpty) {
      final next = fallbackCandidates.first;
      return 'Target ${next.trail.name} • ${_formatDistanceMeters(next.nearestMissingTileDistanceMeters!)} • nearest target';
    }

    final hasIncomplete = _trailProgress.any((p) => !p.isComplete);
    if (hasIncomplete) {
      return 'Move closer to a trail to keep momentum';
    }

    return 'All tracked trails complete 🎉';
  }

  String _nextObjectiveDetailText() {
    final objectiveCandidates =
        _trailProgress
            .where((p) => !p.isComplete && p.bestNextTileH3 != null)
            .toList()
          ..sort(
            (a, b) => (a.bestNextTileDistanceMeters ?? double.infinity)
                .compareTo(b.bestNextTileDistanceMeters ?? double.infinity),
          );

    if (_captureService.capturedHexes.isEmpty) {
      return 'Capture your first tile';
    }
    if (objectiveCandidates.isEmpty) {
      return 'Push toward the next trail tile';
    }
    final next = objectiveCandidates.first;
    final dist = next.bestNextTileDistanceMeters == null
        ? null
        : _formatDistanceMeters(next.bestNextTileDistanceMeters!);

    final base = switch (next.bestNextTileReason) {
      TrailNextTileReason.extendStreak =>
        'Extend your streak to ${next.projectedOwnedSegmentTiles}',
      TrailNextTileReason.bridgeGap => 'Close the gap to strengthen your route',
      TrailNextTileReason.startTrail => 'Start a new trail segment',
      TrailNextTileReason.nearestMissing => 'Push to the next missing tile',
      null => 'Push north to grow your territory',
    };

    if (dist == null) return base;
    return '$base • $dist away';
  }

  ({String title, String? detail, String cta}) _guidedMovementCopy(
    String targetHex,
  ) {
    final direction = _streakDirectionHint();
    final signals = _sectionSignalsForHex(targetHex);
    final sectionTarget =
        _sectionProgress
            .where((s) => s.bestNextTileH3?.toLowerCase() == targetHex)
            .toList()
          ..sort((a, b) {
            final byTiles = a.tilesToTakeControl.compareTo(
              b.tilesToTakeControl,
            );
            if (byTiles != 0) return byTiles;
            return a.section.name.compareTo(b.section.name);
          });
    final section = sectionTarget.isEmpty ? null : sectionTarget.first;
    final trailTarget =
        _trailProgress
            .where((p) => p.bestNextTileH3?.toLowerCase() == targetHex)
            .toList()
          ..sort((a, b) {
            final byGain = b.projectedGainTiles.compareTo(a.projectedGainTiles);
            if (byGain != 0) return byGain;
            return a.trail.name.compareTo(b.trail.name);
          });
    final trail = trailTarget.isEmpty ? null : trailTarget.first;

    final directionLead = direction == null
        ? 'Move to the glowing tile'
        : 'Head $direction';

    if (signals.canFlip ||
        (section != null && section.tilesToTakeControl <= 1)) {
      return (
        title: 'One more tile contests this section',
        detail: direction == null
            ? 'Pressure ${section?.section.name ?? 'the rival section'} on the glowing tile'
            : 'Move $direction to pressure ${section?.section.name ?? 'the rival section'}',
        cta: 'Move to Target',
      );
    }

    if (signals.pressure && section != null) {
      return (
        title: 'Pressure the rival section',
        detail: direction == null
            ? '${section.section.name} is the next tactical push'
            : 'Move $direction to pressure ${section.section.name}',
        cta: 'Move to Target',
      );
    }

    if (trail != null &&
        trail.bestNextTileReason == TrailNextTileReason.extendStreak) {
      return (
        title: direction == null
            ? 'Move to the glowing tile'
            : 'Head $direction to extend your streak',
        detail:
            'Streak grows to ${trail.projectedOwnedSegmentTiles} on ${trail.trail.name}',
        cta: 'Move to Target',
      );
    }

    if (trail != null &&
        trail.bestNextTileReason == TrailNextTileReason.bridgeGap) {
      return (
        title: 'Close the route gap',
        detail: direction == null
            ? 'The glowing tile reconnects your route'
            : '$directionLead to reconnect your route',
        cta: 'Move to Target',
      );
    }

    return (
      title: direction == null
          ? 'Move to the glowing tile'
          : '$directionLead to target',
      detail: _currentObjective.detail ?? _nextObjectiveDetailText(),
      cta: 'Move to Target',
    );
  }

  Widget _buildGuidedBottomPanel({required bool compactHud}) {
    final guidedTargetHex = _guidedPriorityTargetHex();
    final targetCopy = guidedTargetHex == null
        ? null
        : _guidedMovementCopy(guidedTargetHex);
    final onRecommendedTile =
        guidedTargetHex != null &&
        _currentTile.isNotEmpty &&
        guidedTargetHex == _currentTile.toLowerCase();
    final direction = _streakDirectionHint();
    final isFirstCapture = _isGuidedFirstCaptureMode;
    final preSession = !_sessionActive;
    final hasMomentumTarget =
        _sessionActive &&
        guidedTargetHex != null &&
        !onRecommendedTile &&
        !isFirstCapture;
    final currentOwnedByMe =
        _sessionActive &&
        _currentGameTile.ownership == TileOwnership.mine &&
        !isFirstCapture;
    final title = preSession
        ? '▶ Start session to begin movement capture'
        : isFirstCapture
        ? (direction == null
              ? '🎯 Session live - move to the glowing tile'
              : '🎯 Session live - move $direction to the glow')
        : hasMomentumTarget
        ? targetCopy!.title
        : _currentObjective.title;
    final detail = preSession
        ? 'Auto-capture activates while you move through target tiles'
        : isFirstCapture
        ? 'Tracking is active. Keep moving to trigger your first capture'
        : hasMomentumTarget
        ? targetCopy!.detail
        : (currentOwnedByMe
              ? (targetCopy?.detail ??
                    'Move to the highlighted target to keep momentum')
              : _currentObjective.detail);
    final buttonLabel = preSession
        ? 'Start Session'
        : isFirstCapture
        ? 'Move to Glow'
        : hasMomentumTarget
        ? targetCopy!.cta
        : (currentOwnedByMe
              ? (targetCopy?.cta ?? 'Move to Target')
              : 'Keep Moving');

    return FrostedOverlayCard(
      emphasized: isFirstCapture || _capturePulseActive,
      padding: EdgeInsets.symmetric(
        horizontal: 12,
        vertical: compactHud ? 8 : 10,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: GameUiText.body(
              color: GameUiTokens.textHi,
              size: 13,
              weight: FontWeight.w700,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (detail != null) ...[
            const SizedBox(height: 2),
            Text(
              detail,
              style: GameUiText.meta(color: GameUiTokens.textMid, size: 11),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: preSession
                  ? () async {
                      await _startGuidedSessionFromCta();
                    }
                  : _currentTile.isEmpty
                  ? null
                  : () async {
                      final shouldMoveFirst =
                          isFirstCapture || hasMomentumTarget;
                      if (shouldMoveFirst) {
                        final hint = direction == null
                            ? 'Move to the glowing tile'
                            : 'Move $direction to the glowing tile';
                        await HapticFeedback.selectionClick();
                        _showCaptureFeedback(hint);
                        return;
                      }

                      await HapticFeedback.selectionClick();
                      _showCaptureFeedback(
                        currentOwnedByMe
                            ? 'Session live - Auto-capture on movement'
                            : 'Tracking active - Keep moving',
                      );
                    },
              style: FilledButton.styleFrom(
                backgroundColor: GameColors.neonGreen,
                foregroundColor: Colors.black,
              ),
              child: Text(buttonLabel),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGuidedStickyCtaBar({required bool compactHud}) {
    final guidedTargetHex = _guidedPriorityTargetHex();
    final targetCopy = guidedTargetHex == null
        ? null
        : _guidedMovementCopy(guidedTargetHex);
    final onRecommendedTile =
        guidedTargetHex != null &&
        _currentTile.isNotEmpty &&
        guidedTargetHex == _currentTile.toLowerCase();
    final direction = _streakDirectionHint();
    final isFirstCapture = _isGuidedFirstCaptureMode;
    final preSession = !_sessionActive;
    final hasMomentumTarget =
        _sessionActive &&
        guidedTargetHex != null &&
        !onRecommendedTile &&
        !isFirstCapture;
    final currentOwnedByMe =
        _sessionActive &&
        _currentGameTile.ownership == TileOwnership.mine &&
        !isFirstCapture;
    final message = preSession
        ? '▶ Start session, then move to the glowing tile'
        : isFirstCapture
        ? (direction == null
              ? '🎯 Session live - move to the glowing tile'
              : '🎯 Session live - move $direction to the glow')
        : hasMomentumTarget
        ? targetCopy!.title
        : _currentObjective.title;
    final buttonLabel = preSession
        ? 'Start'
        : isFirstCapture
        ? 'Move'
        : hasMomentumTarget
        ? targetCopy!.cta
        : (currentOwnedByMe ? (targetCopy?.cta ?? 'Move') : 'Live');

    return FrostedOverlayCard(
      emphasized: isFirstCapture || _capturePulseActive,
      padding: EdgeInsets.symmetric(
        horizontal: 10,
        vertical: compactHud ? 6 : 8,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              style: GameUiText.body(
                color: GameUiTokens.textHi,
                size: 12,
                weight: FontWeight.w700,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 10),
          FilledButton(
            onPressed: preSession
                ? () async {
                    await _startGuidedSessionFromCta();
                  }
                : _currentTile.isEmpty
                ? null
                : () async {
                    final shouldMoveFirst = isFirstCapture || hasMomentumTarget;
                    if (shouldMoveFirst) {
                      final hint = direction == null
                          ? 'Move to the glowing tile'
                          : 'Move $direction to the glowing tile';
                      await HapticFeedback.selectionClick();
                      _showCaptureFeedback(hint);
                      return;
                    }

                    await HapticFeedback.selectionClick();
                    _showCaptureFeedback(
                      currentOwnedByMe
                          ? 'Session live - Auto-capture on movement'
                          : 'Tracking active - Keep moving',
                    );
                  },
            style: FilledButton.styleFrom(
              backgroundColor: GameColors.neonGreen,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            child: Text(
              buttonLabel,
              style: GameUiText.body(
                color: Colors.black,
                weight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _selectedOwnerLabel(GameTile tile) {
    return switch (tile.ownership) {
      TileOwnership.mine => 'You',
      TileOwnership.neutral => 'Neutral',
      TileOwnership.enemy => 'Rival',
    };
  }

  String _selectedStatusLabel(GameTile tile) {
    if (tile.ownership == TileOwnership.neutral) return 'Neutral';
    final until = tile.protectedUntil;
    if (until == null || !until.isAfter(DateTime.now()))
      return 'Capturable now';
    return 'Protected';
  }

  String _selectedProtectionCountdown(GameTile tile) {
    final until = tile.protectedUntil;
    if (until == null || !until.isAfter(DateTime.now())) return '--';

    final remaining = until.difference(DateTime.now());
    final hours = remaining.inHours;
    final minutes = remaining.inMinutes.remainder(60);
    final seconds = remaining.inSeconds.remainder(60);
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  String _selectedHelperLine(GameTile tile) {
    if (tile.ownership == TileOwnership.neutral) return 'Capturable now';
    final until = tile.protectedUntil;
    if (until == null || !until.isAfter(DateTime.now())) {
      return 'Capturable now';
    }

    if (tile.ownership == TileOwnership.enemy) return 'Cannot be taken yet';

    final remaining = until.difference(DateTime.now());
    final mins = remaining.inMinutes;
    final secs = remaining.inSeconds.remainder(60);
    return 'Protected for ${mins}m ${secs.toString().padLeft(2, '0')}s';
  }

  Widget _buildSelectedTileInfoCard({
    required GameTile tile,
    required bool guidedMode,
    required bool compactHud,
  }) {
    final owner = _selectedOwnerLabel(tile);
    final status = _selectedStatusLabel(tile);
    final countdown = _selectedProtectionCountdown(tile);
    final helper = _selectedHelperLine(tile);

    return FrostedOverlayCard(
      emphasized: true,
      borderRadius: const BorderRadius.all(Radius.circular(16)),
      padding: EdgeInsets.symmetric(
        horizontal: 12,
        vertical: guidedMode ? 8 : (compactHud ? 8 : 10),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Selected tile',
                  style: GameUiText.body(
                    color: GameUiTokens.textHi,
                    size: 13,
                    weight: FontWeight.w700,
                  ),
                ),
              ),
              InkWell(
                onTap: _dismissSelection,
                child: Padding(
                  padding: EdgeInsets.all(2),
                  child: Icon(
                    Icons.close,
                    color: GameUiTokens.textMid,
                    size: 18,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _buildHudPill(label: 'Owner', value: owner),
              _buildHudPill(label: 'Status', value: status),
            ],
          ),
          if (status == 'Protected') ...[
            const SizedBox(height: 6),
            Text(
              'Protection: $countdown',
              style: GameUiText.meta(color: GameUiTokens.textMid, size: 12),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            helper,
            style: GameUiText.body(
              color: GameUiTokens.accentPrimary,
              size: 13,
              weight: FontWeight.w700,
            ),
            maxLines: guidedMode ? 1 : 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (!guidedMode) ...[
            const SizedBox(height: 4),
            Text(
              'H3-$h3Resolution:${tile.h3Index}',
              style: GameUiText.meta(color: GameUiTokens.textLow, size: 10),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _cycleVisibleRadius() async {
    const options = <double>[500, 600, 700];
    final currentIndex = options.indexOf(_visibleRadiusMeters);
    final nextIndex = currentIndex == -1
        ? 1
        : (currentIndex + 1) % options.length;

    setState(() {
      _visibleRadiusMeters = options[nextIndex];
    });

    final lat = _lastLat;
    final lng = _lastLng;
    if (lat != null && lng != null) {
      await _refreshMapForCoordinates(lat, lng, moveCamera: false);
    }
  }

  void _updateSessionSummaryCounters(CaptureAttemptResult result) {
    if (!_sessionActive) return;

    switch (result.status) {
      case CaptureAttemptStatus.captured:
        _sessionTilesCaptured += 1;
      case CaptureAttemptStatus.takeoverCaptured:
        _sessionTilesCaptured += 1;
        _sessionTakeovers += 1;
      case CaptureAttemptStatus.protectionRefreshed:
        _sessionTilesRefreshed += 1;
      case CaptureAttemptStatus.protectedByRival:
        _sessionRivalBlocked += 1;
      case CaptureAttemptStatus.lowAccuracy:
      case CaptureAttemptStatus.tooFarFromCenter:
        break;
    }
  }

  void _updateCurrentObjective() {
    setState(() {
      _currentObjective = _objectiveEngine.evaluateObjective(
        sessionActive: _sessionActive,
        currentTile: _currentGameTile,
        capturedHexes: _captureService.capturedHexes,
        capturedHexesCount: _captureService.capturedHexes.length,
        protectedUntil: _currentGameTile.protectedUntil,
        trailProgress: _trailProgress,
        sectionProgress: _sectionProgress,
        streakDirectionHint: _streakDirectionHint(),
      );
    });
    unawaited(_syncRecommendedTileGlow());
  }

  void _logCaptureEvent(
    CaptureAttemptResult result,
    String hex, {
    required bool auto,
  }) {
    final mode = auto ? 'auto' : 'manual';
    switch (result.status) {
      case CaptureAttemptStatus.captured:
        _eventLog.log(
          MapEventType.tileCaptured,
          '$mode capture succeeded',
          metadata: {'hex': hex},
        );
      case CaptureAttemptStatus.takeoverCaptured:
        _eventLog.log(
          MapEventType.rivalTakeover,
          '$mode takeover succeeded',
          metadata: {'hex': hex},
        );
      case CaptureAttemptStatus.protectionRefreshed:
        _eventLog.log(
          MapEventType.protectionRefreshed,
          '$mode protection refreshed',
          metadata: {
            'hex': hex,
            'protectedUntil': result.protectedUntil?.toIso8601String(),
          },
        );
      case CaptureAttemptStatus.protectedByRival:
        _eventLog.log(
          MapEventType.blockedByRivalProtection,
          '$mode capture blocked by rival protection',
          metadata: {
            'hex': hex,
            'protectedUntil': result.protectedUntil?.toIso8601String(),
          },
        );
      case CaptureAttemptStatus.lowAccuracy:
      case CaptureAttemptStatus.tooFarFromCenter:
        break;
    }
  }

  Future<void> _showSessionSummaryDialog() async {
    final now = DateTime.now();
    final startedAt = _sessionStartedAt;
    final elapsed = startedAt == null
        ? Duration.zero
        : now.difference(startedAt);
    final minutes = elapsed.inMinutes;
    final seconds = elapsed.inSeconds % 60;
    final distanceKm = _sessionDistanceMeters / 1000.0;

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Session Summary'),
          content: Text(
            '${_sessionTilesCaptured} tiles captured\n'
            '${_sessionTilesRefreshed} tile protection refreshed\n'
            '${_sessionRivalBlocked} rival tiles still protected\n'
            '${_sessionTakeovers} takeover captures\n'
            '${_sessionMilestones.length} milestones unlocked this session\n'
            'Distance: ${distanceKm.toStringAsFixed(2)} km\n'
            'Time: ${minutes}m ${seconds}s',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _centerOnMeOnce() async {
    final pos = await _mapController.getCurrentPosition(context);
    if (pos == null) return;

    await _refreshMapForCoordinates(
      pos.latitude,
      pos.longitude,
      moveCamera: true,
      accuracy: pos.accuracy,
    );
  }

  Future<void> _startTracking() async {
    await _mapController.stopTracking(_posSub);
    if (!mounted) return;

    final subscription = await _mapController.startTracking(
      context: context,
      onPosition: (pos) async {
        await _refreshMapForCoordinates(
          pos.latitude,
          pos.longitude,
          moveCamera: _followMe,
          accuracy: pos.accuracy,
        );
      },
      onError: (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Location stream error: $e')));
      },
    );

    if (subscription == null) return;

    _posSub = subscription;
    setState(() => _tracking = true);
  }

  Future<void> _stopTracking() async {
    await _mapController.stopTracking(_posSub);
    _posSub = null;
    setState(() => _tracking = false);
  }

  Future<void> _toggleTracking() async {
    if (_tracking) {
      await _stopTracking();
    } else {
      await _startTracking();
    }
  }

  Future<void> _simulateMove() async {
    final simulatedMove = await _mapController.nextSimulatedMove(
      context: context,
      currentStep: _simStep,
      baseLat: _simBaseLat,
      baseLng: _simBaseLng,
    );
    if (simulatedMove == null) return;

    _simBaseLat = simulatedMove.baseLat;
    _simBaseLng = simulatedMove.baseLng;
    _simStep = simulatedMove.step;

    await _refreshMapForCoordinates(
      simulatedMove.latitude,
      simulatedMove.longitude,
      moveCamera: true,
      accuracy: simulatedMove.accuracy,
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Simulated step ${simulatedMove.step} (~${simulatedMove.stepMeters.toInt()}m)',
        ),
      ),
    );
  }

  Future<void> _testMovementAcrossTiles() async {
    final uniqueHexes = <String>{};

    var localStep = _simStep;
    var localBaseLat = _simBaseLat;
    var localBaseLng = _simBaseLng;

    if (localBaseLat == null || localBaseLng == null) {
      final pos = await _mapController.getCurrentPosition(context);
      if (pos == null) return;
      localBaseLat = pos.latitude;
      localBaseLng = pos.longitude;
      localStep = 0;
    }

    for (var i = 0; i < 8; i++) {
      final simulatedMove = await _mapController.nextSimulatedMove(
        currentStep: localStep,
        baseLat: localBaseLat,
        baseLng: localBaseLng,
      );
      if (simulatedMove == null) return;

      localStep = simulatedMove.step;
      localBaseLat = simulatedMove.baseLat;
      localBaseLng = simulatedMove.baseLng;

      final hex = await _captureService.getCurrentHexForPosition(
        simulatedMove.latitude,
        simulatedMove.longitude,
      );
      uniqueHexes.add(hex);

      await _refreshMapForCoordinates(
        simulatedMove.latitude,
        simulatedMove.longitude,
        moveCamera: false,
        accuracy: simulatedMove.accuracy,
      );
    }

    _simStep = localStep;
    _simBaseLat = localBaseLat;
    _simBaseLng = localBaseLng;

    if (!mounted) return;
    final crossedMultiple = uniqueHexes.length > 1;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          crossedMultiple
              ? 'Movement test passed ✅ (${uniqueHexes.length} unique tiles)'
              : 'Movement test failed ❌ (stayed on one tile)',
        ),
      ),
    );
  }

  Future<void> _captureCurrentTile() async {
    if (_currentCell == null || _lastLat == null || _lastLng == null) return;

    final cellHex = _currentCell!.toRadixString(16).toLowerCase();

    final flowResult = await _mapController.captureAndRefreshForCoordinates(
      currentHex: cellHex,
      latitude: _lastLat!,
      longitude: _lastLng!,
      accuracy: _lastAccuracy,
      userId: _mapController.currentUserId,
      radiusMeters: _visibleRadiusMeters,
      includePreviewEnemyTiles: _showPreviewEnemyTiles,
    );
    final result = flowResult.captureAttempt;

    if (!result.didCapture) {
      if (!mounted) return;

      _updateSessionSummaryCounters(result);
      _logCaptureEvent(result, cellHex, auto: false);

      final message = switch (result.status) {
        CaptureAttemptStatus.protectedByRival =>
          result.protectedUntil == null
              ? 'Tile is protected by current owner.'
              : 'Tile is protected for ${_formatDuration(result.protectedUntil!.difference(DateTime.now()))}',
        CaptureAttemptStatus.lowAccuracy =>
          'GPS accuracy too low for capture. Need ≤ ${MapController.maxAllowedAccuracyMeters.toInt()}m.',
        CaptureAttemptStatus.tooFarFromCenter =>
          'Move closer to tile center to capture. Distance: ${result.distanceToCenter?.toStringAsFixed(0) ?? '--'}m / ${MapController.maxCaptureDistanceMeters.toInt()}m allowed.',
        CaptureAttemptStatus.takeoverCaptured => '',
        CaptureAttemptStatus.protectionRefreshed => '',
        CaptureAttemptStatus.captured => '',
      };

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
      _updateCurrentObjective();
      return;
    }

    final refresh = flowResult.refresh;
    if (refresh != null) {
      _applyRefreshResult(refresh, currentLat: _lastLat, currentLng: _lastLng);
    }

    _triggerCapturePulse();
    if (_isGuidedFirstCaptureMode) {
      await HapticFeedback.heavyImpact();
      _onFirstCaptureCompleted();
    } else {
      await HapticFeedback.lightImpact();
    }

    _updateSessionSummaryCounters(result);
    _logCaptureEvent(result, cellHex, auto: false);

    if (!mounted) return;
    final successMessage = switch (result.status) {
      CaptureAttemptStatus.takeoverCaptured =>
        result.synced
            ? 'Takeover captured ✅ (synced)'
            : 'Takeover captured ✅ (saved locally)',
      CaptureAttemptStatus.protectionRefreshed =>
        result.synced
            ? 'Protection refreshed ✅ (synced)'
            : 'Protection refreshed ✅ (saved locally)',
      CaptureAttemptStatus.captured =>
        result.synced
            ? 'Tile captured ✅ (synced)'
            : 'Tile captured ✅ (saved locally)',
      _ =>
        result.synced
            ? 'Tile captured ✅ (synced)'
            : 'Tile captured ✅ (saved locally)',
    };

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(successMessage)));
  }

  Future<void> _toggleSession() async {
    if (_sessionActive) {
      setState(() {
        _sessionActive = false;
        _pendingAutoCaptureHex = null;
        _enteredPendingTileAt = null;
      });

      await _saveSessionState();
      _eventLog.log(
        MapEventType.sessionStopped,
        'Session stopped',
        metadata: {
          'captured': _sessionTilesCaptured,
          'refreshed': _sessionTilesRefreshed,
          'blocked': _sessionRivalBlocked,
          'takeovers': _sessionTakeovers,
          'distanceMeters': _sessionDistanceMeters,
        },
      );

      await _showSessionSummaryDialog();
      _updateCurrentObjective();
      await _clearRecommendedTileGlow();
      return;
    }

    setState(() {
      _sessionActive = true;
      _sessionsStartedCount += 1;
      _lastSessionCaptureAttemptHex = null;
      _sessionStartedAt = DateTime.now();
      _sessionDistanceMeters = 0;
      _sessionTilesCaptured = 0;
      _sessionTilesRefreshed = 0;
      _sessionRivalBlocked = 0;
      _sessionTakeovers = 0;
      _lastSessionLat = _lastLat;
      _lastSessionLng = _lastLng;
      _lastAutoCaptureAttemptAt = null;
      _recentAutoCaptureByHex.clear();
      _pendingAutoCaptureHex = null;
      _enteredPendingTileAt = null;
      _sessionMilestones.clear();
    });

    await _saveSessionState();
    await _unlockMilestones([
      (id: 'first_session_start', title: '🎬 First session started'),
    ]);
    _eventLog.log(MapEventType.sessionStarted, 'Session started');
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Session started ▶️')));
    _updateCurrentObjective();
  }

  Color _ownershipBadgeColor(GameTile tile) {
    final now = DateTime.now();
    final isProtected =
        tile.protectedUntil != null && tile.protectedUntil!.isAfter(now);

    return switch (tile.ownership) {
      TileOwnership.mine =>
        isProtected ? GameColors.neonGreen : GameColors.myTileGreen,
      TileOwnership.enemy =>
        isProtected ? GameColors.rivalRed : GameColors.rivalRedDark,
      TileOwnership.neutral => GameColors.neutralGray,
    };
  }

  String _captureStatusText() {
    if (_lastAccuracy == null) return 'Accuracy: --';
    return 'Accuracy: ${_lastAccuracy!.toStringAsFixed(0)}m';
  }

  Color _hudAccentColor() {
    return _capturePulseActive
        ? _ownershipBadgeColor(_currentGameTile)
        : GameColors.neonGreen;
  }

  HudPersonality _resolveHudPersonality() {
    switch (_hudPreference) {
      case HudPreference.guided:
        return HudPersonality.guided;
      case HudPreference.pro:
        return HudPersonality.pro;
      case HudPreference.auto:
        final captured = _captureService.capturedHexes.length;
        final isBeginner = _sessionsStartedCount < 2 || captured < 5;
        final isEarly = _sessionsStartedCount <= 6 || captured <= 30;
        return (isBeginner || isEarly)
            ? HudPersonality.guided
            : HudPersonality.pro;
    }
  }

  Future<void> _setHudPreference(HudPreference preference) async {
    if (_hudPreference == preference) return;
    setState(() {
      _hudPreference = preference;
    });
    await _saveSessionState();
    await _syncRecommendedTileGlow();
  }

  Future<void> _setShowPreviewEnemyTiles(bool value) async {
    if (_showPreviewEnemyTiles == value) return;
    setState(() {
      _showPreviewEnemyTiles = value;
    });
    await _saveSessionState();

    final lat = _lastLat;
    final lng = _lastLng;
    if (lat != null && lng != null) {
      await _refreshMapForCoordinates(lat, lng, moveCamera: false);
    }
  }

  Widget _buildGuidedModeMenuButton() {
    return PopupMenuButton<HudPreference>(
      tooltip: 'HUD mode',
      onSelected: (value) {
        unawaited(_setHudPreference(value));
      },
      itemBuilder: (context) => [
        CheckedPopupMenuItem(
          value: HudPreference.auto,
          checked: _hudPreference == HudPreference.auto,
          child: const Text('Auto HUD'),
        ),
        CheckedPopupMenuItem(
          value: HudPreference.guided,
          checked: _hudPreference == HudPreference.guided,
          child: const Text('Guided HUD'),
        ),
        CheckedPopupMenuItem(
          value: HudPreference.pro,
          checked: _hudPreference == HudPreference.pro,
          child: const Text('Pro HUD'),
        ),
      ],
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.08),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: Colors.white24.withOpacity(0.7)),
        ),
        child: const Icon(Icons.more_horiz, size: 16, color: Colors.white),
      ),
    );
  }

  Widget _buildGuidedTopHud({required bool compactHud}) {
    final guidedTargetHex = _guidedPriorityTargetHex();
    final targetCopy = guidedTargetHex == null
        ? null
        : _guidedMovementCopy(guidedTargetHex);
    final direction = _streakDirectionHint();

    if (!_sessionActive) {
      return _GuidedOverlayCard(
        message: direction == null
            ? '▶ Start session, then move to the glowing tile'
            : '▶ Start session, then move $direction to the glow',
        trailing: _buildGuidedModeMenuButton(),
      );
    }

    // First-capture: pure action focus — keep it dead simple.
    if (_isGuidedFirstCaptureMode) {
      return _GuidedOverlayCard(
        message: direction == null
            ? '⚡ Session live - move to the glowing tile'
            : '⚡ Session live - move $direction to the glow',
        trailing: _buildGuidedModeMenuButton(),
      );
    }

    // Brief post-capture transition.
    if (_showPostCaptureGuidance) {
      final hasSectionPressure = _sectionProgress.any(
        (s) => s.controlState == SectionControlState.contested,
      );
      return _GuidedOverlayCard(
        message: direction == null
            ? (hasSectionPressure
                  ? '🔥 Great capture. One more tile can swing this section'
                  : '🔥 Great capture. Take the next glowing tile')
            : '🔥 Great capture. Capture $direction to extend your streak',
        trailing: _buildGuidedModeMenuButton(),
      );
    }

    // Normal guided mode: objective-aware compact HUD.
    final mineCount = _captureService.capturedHexes.length;
    final objective = _currentObjective;
    final onRecommendedTile =
        guidedTargetHex != null &&
        _currentTile.isNotEmpty &&
        guidedTargetHex == _currentTile.toLowerCase();
    final title = (!onRecommendedTile && guidedTargetHex != null)
        ? targetCopy!.title
        : objective.title;
    final detail = (!onRecommendedTile && guidedTargetHex != null)
        ? targetCopy!.detail
        : objective.detail;

    return FrostedOverlayCard(
      emphasized: _capturePulseActive,
      borderRadius: const BorderRadius.all(Radius.circular(16)),
      padding: EdgeInsets.fromLTRB(
        12,
        compactHud ? 8 : 10,
        12,
        compactHud ? 8 : 10,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.gps_fixed,
                size: 14,
                color: _sessionActive
                    ? GameUiTokens.accentSecondary
                    : GameUiTokens.textMid,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: GameUiText.body(
                    color: GameUiTokens.textHi,
                    size: 13,
                    weight: FontWeight.w800,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              _buildGuidedModeMenuButton(),
            ],
          ),
          if (detail != null) ...[
            const SizedBox(height: 3),
            Text(
              detail,
              style: GameUiText.meta(color: GameUiTokens.textMid, size: 11),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              _buildHudPill(
                label: 'Tiles',
                value: '$mineCount',
                color: mineCount > 0
                    ? GameUiTokens.accentSecondary
                    : GameUiTokens.textMid,
              ),
              _buildHudPill(
                label: 'Session',
                value: _sessionActive
                    ? 'Live ${_sessionElapsedText()}'
                    : 'Ready',
                color: _sessionActive
                    ? GameUiTokens.accentPrimary
                    : GameUiTokens.textMid,
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _sessionElapsedText() {
    if (!_sessionActive || _sessionStartedAt == null) return '--:--';
    final elapsed = DateTime.now().difference(_sessionStartedAt!);
    final hours = elapsed.inHours;
    final minutes = elapsed.inMinutes.remainder(60);
    final seconds = elapsed.inSeconds.remainder(60);
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  Widget _buildHudPill({
    required String label,
    required String value,
    Color color = Colors.white,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: GameUiTokens.bg2.withOpacity(0.48),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: GameUiTokens.panelBorder.withOpacity(0.75)),
      ),
      child: RichText(
        text: TextSpan(
          style: GameUiText.meta(
            color: GameUiTokens.textMid,
            size: 11,
            weight: FontWeight.w600,
          ),
          children: [
            TextSpan(text: '$label '),
            TextSpan(
              text: value,
              style: GameUiText.body(
                color: color,
                size: 12,
                weight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPremiumTopHud({required bool compactHud, required bool muted}) {
    final mineCount = _captureService.capturedHexes.length;
    final visibleCount = _mapRenderService.visibleCapturedHex.length;
    final distanceKm = (_sessionDistanceMeters / 1000).toStringAsFixed(2);
    final accent = _hudAccentColor();

    return FrostedOverlayCard(
      emphasized: !muted && _capturePulseActive,
      borderRadius: const BorderRadius.all(Radius.circular(20)),
      padding: EdgeInsets.zero,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.white.withOpacity(
                muted
                    ? (_capturePulseActive ? 0.08 : 0.05)
                    : (_capturePulseActive ? 0.12 : 0.08),
              ),
              Colors.white.withOpacity(muted ? 0.01 : 0.02),
            ],
          ),
          border: Border.all(
            color: _capturePulseActive
                ? accent.withOpacity(muted ? 0.45 : 0.75)
                : Colors.white24.withOpacity(muted ? 0.65 : 1),
          ),
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(14, 12, compactHud ? 8 : 10, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'HEXTRAIL COMMAND',
                          style: GameUiText.command(
                            color: _capturePulseActive ? accent : Colors.white,
                            letterSpacing: 1.2,
                            weight: FontWeight.w800,
                            size: 14,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _sessionActive
                              ? 'Seattle Ops • Session live'
                              : 'Seattle Ops • Ready to capture',
                          style: GameUiText.meta(
                            color: GameUiTokens.textMid,
                            size: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Local leaderboard',
                    onPressed: _showLeaderboard,
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.white.withOpacity(0.08),
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.military_tech),
                  ),
                  const SizedBox(width: 6),
                  PopupMenuButton<String>(
                    tooltip: 'More actions',
                    onSelected: (value) {
                      switch (value) {
                        case 'simulate':
                          _simulateMove();
                          break;
                        case 'test':
                          _testMovementAcrossTiles();
                          break;
                        case 'auto':
                          unawaited(_setHudPreference(HudPreference.auto));
                          break;
                        case 'guided':
                          unawaited(_setHudPreference(HudPreference.guided));
                          break;
                        case 'pro':
                          unawaited(_setHudPreference(HudPreference.pro));
                          break;
                        case 'preview_enemy_tiles':
                          unawaited(
                            _setShowPreviewEnemyTiles(!_showPreviewEnemyTiles),
                          );
                          break;
                        case 'debug_reco':
                          setState(() {
                            _showRecommendationDebug =
                                !_showRecommendationDebug;
                          });
                          break;
                      }
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem(
                        value: 'simulate',
                        child: Text('Simulate walk path'),
                      ),
                      const PopupMenuItem(
                        value: 'test',
                        child: Text('Test movement across tiles'),
                      ),
                      const PopupMenuDivider(),
                      CheckedPopupMenuItem(
                        value: 'auto',
                        checked: _hudPreference == HudPreference.auto,
                        child: const Text('Auto HUD'),
                      ),
                      CheckedPopupMenuItem(
                        value: 'guided',
                        checked: _hudPreference == HudPreference.guided,
                        child: const Text('Guided HUD'),
                      ),
                      CheckedPopupMenuItem(
                        value: 'pro',
                        checked: _hudPreference == HudPreference.pro,
                        child: const Text('Pro HUD'),
                      ),
                      const PopupMenuDivider(),
                      CheckedPopupMenuItem(
                        value: 'preview_enemy_tiles',
                        checked: _showPreviewEnemyTiles,
                        child: const Text('Preview rival tiles'),
                      ),
                      if (kDebugMode) ...[
                        const PopupMenuDivider(),
                        CheckedPopupMenuItem(
                          value: 'debug_reco',
                          checked: _showRecommendationDebug,
                          child: const Text('Debug recommendation scoring'),
                        ),
                      ],
                    ],
                    child: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: const Icon(Icons.more_horiz, color: Colors.white),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _buildHudPill(
                    label: 'Tracking',
                    value: _tracking ? 'On' : 'Off',
                    color: _tracking ? GameColors.statusTracking : Colors.grey,
                  ),
                  _buildHudPill(
                    label: 'Session',
                    value: _sessionActive ? 'Active' : 'Paused',
                    color: _sessionActive
                        ? GameColors.statusSessionOn
                        : Colors.grey,
                  ),
                  _buildHudPill(label: 'Captured', value: '$mineCount'),
                  if (!compactHud)
                    _buildHudPill(label: 'Nearby', value: '$visibleCount'),
                  _buildHudPill(
                    label: 'Achievements',
                    value:
                        '${_unlockedMilestoneIds.length}/$_totalMilestoneCount',
                    color: Colors.amberAccent,
                  ),
                  if (!compactHud)
                    _buildHudPill(label: 'Time', value: _sessionElapsedText()),
                  _buildHudPill(
                    label: compactHud ? 'KM' : 'DIST',
                    value: '${distanceKm}km',
                    color: accent,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActionRail({required bool muted}) {
    final accent = _hudAccentColor();

    return FrostedOverlayCard(
      emphasized: !muted && _sessionActive,
      borderRadius: const BorderRadius.all(Radius.circular(16)),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            onPressed: _centerOnMeOnce,
            tooltip: 'Center once',
            icon: const Icon(Icons.place),
            color: muted ? GameUiTokens.textMid : Colors.white,
          ),
          IconButton(
            onPressed: _toggleTracking,
            tooltip: _tracking ? 'Stop tracking' : 'Start tracking',
            icon: Icon(_tracking ? Icons.explore : Icons.explore_outlined),
            color: _tracking
                ? GameColors.statusTracking
                : (muted ? GameUiTokens.textMid : Colors.white),
          ),
          IconButton(
            onPressed: () => setState(() => _followMe = !_followMe),
            tooltip: _followMe ? 'Follow: ON' : 'Follow: OFF',
            icon: Icon(
              _followMe ? Icons.navigation : Icons.navigation_outlined,
            ),
            color: _followMe
                ? Colors.cyanAccent
                : (muted ? GameUiTokens.textMid : Colors.white),
          ),
          IconButton(
            onPressed: _toggleSession,
            tooltip: _sessionActive ? 'Stop session' : 'Start session',
            icon: Icon(
              _sessionActive ? Icons.stop_circle : Icons.play_circle_fill,
            ),
            color: _sessionActive
                ? accent
                : (muted ? GameUiTokens.textMid : Colors.white),
          ),
          IconButton(
            onPressed: _cycleVisibleRadius,
            tooltip: 'Visible radius: ${_visibleRadiusMeters.toInt()}m',
            icon: const Icon(Icons.alt_route),
            color: muted ? GameUiTokens.textMid : Colors.white,
          ),
          IconButton(
            onPressed: _showSectionProgress,
            tooltip: 'Trail sections',
            icon: const Icon(Icons.route),
            color: muted ? GameUiTokens.textMid : Colors.white,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (kMapboxAccessToken.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Map')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Missing Mapbox token.\n\nRun:\nflutter run --dart-define=MAPBOX_ACCESS_TOKEN=YOUR_TOKEN',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    final compactHud = _compactHud;
    final topInset = MediaQuery.paddingOf(context).top;
    final screenSize = MediaQuery.sizeOf(context);
    final hudPersonality = _resolveHudPersonality();
    final guidedMode = hudPersonality == HudPersonality.guided;
    final firstCaptureGuidedMode = _isGuidedFirstCaptureMode;
    final proMode = hudPersonality == HudPersonality.pro;
    final useGuidedStickyBar =
        guidedMode && (screenSize.height < 760 || screenSize.width < 380);
    final topHudMotionDuration = Duration(milliseconds: proMode ? 380 : 430);
    final actionRailMotionDuration = Duration(
      milliseconds: proMode ? 430 : 380,
    );
    final mapLegendMotionDuration = Duration(milliseconds: proMode ? 420 : 380);
    final bottomSlideDuration = Duration(
      milliseconds: guidedMode ? 340 : (proMode ? 430 : 390),
    );
    final bottomFadeDuration = Duration(
      milliseconds: guidedMode ? 320 : (proMode ? 420 : 380),
    );
    final bottomScaleDuration = Duration(
      milliseconds: guidedMode ? 220 : (proMode ? 300 : 260),
    );
    final guidedSwitchDuration = Duration(milliseconds: guidedMode ? 240 : 280);

    return Scaffold(
      body: Stack(
        children: [
          mb.MapWidget(
            key: const ValueKey('mapWidget'),
            styleUri: kMapboxDarkStyleUri,
            onTapListener: _onMapTap,
            cameraOptions: mb.CameraOptions(
              center: mb.Point(coordinates: mb.Position(-122.3321, 47.6062)),
              zoom: 11.5,
            ),
            onMapCreated: (mapboxMap) async {
              _map = mapboxMap;
              await _mapRenderService.attachMap(mapboxMap);

              if (_lastLat != null && _lastLng != null) {
                await _refreshMapForCoordinates(
                  _lastLat!,
                  _lastLng!,
                  moveCamera: false,
                  accuracy: _lastAccuracy,
                );
              }
            },
          ),
          Positioned.fill(
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (_) => _onMapInteraction(),
              onPointerMove: (_) => _onMapInteraction(),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withOpacity(0.18),
                      Colors.transparent,
                      Colors.black.withOpacity(0.13),
                    ],
                    stops: const [0.0, 0.33, 1.0],
                  ),
                ),
              ),
            ),
          ),
          if (firstCaptureGuidedMode)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.22),
                  ),
                ),
              ),
            ),
          if (!guidedMode)
            Positioned(
              left: 12,
              right: compactHud ? 56 : 72,
              top: topInset + 8,
              child: AnimatedSlide(
                duration: topHudMotionDuration,
                curve: Curves.easeOutCubic,
                offset: _legendVisible ? Offset.zero : const Offset(0, -0.18),
                child: AnimatedOpacity(
                  duration: topHudMotionDuration,
                  opacity: _legendVisible ? 1 : 0,
                  child: _buildPremiumTopHud(
                    compactHud: compactHud,
                    muted: proMode,
                  ),
                ),
              ),
            ),
          if (!guidedMode)
            Positioned.fill(
              child: Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: EdgeInsets.only(
                    right: 12,
                    top: compactHud ? 120 : 136,
                    bottom: compactHud ? 120 : 132,
                  ),
                  child: AnimatedSlide(
                    duration: actionRailMotionDuration,
                    curve: Curves.easeOutCubic,
                    offset: _actionRailVisible
                        ? Offset.zero
                        : const Offset(0.2, 0),
                    child: AnimatedOpacity(
                      duration: actionRailMotionDuration,
                      opacity: _actionRailVisible ? 1 : 0,
                      child: _buildActionRail(muted: proMode),
                    ),
                  ),
                ),
              ),
            ),
          if (!guidedMode)
            Positioned(
              left: 12,
              top: topInset + (compactHud ? 170 : 208),
              child: AnimatedSlide(
                duration: mapLegendMotionDuration,
                curve: Curves.easeOutCubic,
                offset: _mapLegendVisible
                    ? Offset.zero
                    : const Offset(0, -0.18),
                child: AnimatedOpacity(
                  duration: mapLegendMotionDuration,
                  opacity: _mapLegendVisible && !compactHud ? 1 : 0.78,
                  child: const MapLegend(),
                ),
              ),
            ),
          if (kDebugMode && _showRecommendationDebug)
            Positioned(
              left: 12,
              right: 12,
              bottom: guidedMode
                  ? (compactHud ? 84 : 98)
                  : (compactHud ? 90 : 110),
              child: IgnorePointer(
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: _buildRecommendationDebugCard(),
                ),
              ),
            ),
          if (guidedMode)
            Positioned(
              left: 12,
              right: 12,
              top: topInset + 8,
              child: AnimatedSwitcher(
                duration: guidedSwitchDuration,
                child: KeyedSubtree(
                  key: ValueKey(
                    _isGuidedFirstCaptureMode
                        ? 'first-capture'
                        : _showPostCaptureGuidance
                        ? 'post-capture'
                        : 'normal',
                  ),
                  child: _buildGuidedTopHud(compactHud: compactHud),
                ),
              ),
            ),
          if (_selectedTile != null)
            Positioned(
              left: 16,
              right: 16,
              bottom: guidedMode
                  ? (useGuidedStickyBar
                        ? (compactHud ? 72 : 80)
                        : (compactHud ? 132 : 154))
                  : (compactHud ? 138 : 168),
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 180),
                opacity: _bottomHudVisible ? 1 : 0,
                child: firstCaptureGuidedMode
                    ? const SizedBox.shrink()
                    : _buildSelectedTileInfoCard(
                        tile: _selectedTile!,
                        guidedMode: guidedMode,
                        compactHud: compactHud,
                      ),
              ),
            ),
          Positioned(
            left: 16,
            right: 16,
            bottom: compactHud ? 10 : 16,
            child: AnimatedSlide(
              duration: bottomSlideDuration,
              curve: Curves.easeOutCubic,
              offset: _bottomHudVisible ? Offset.zero : const Offset(0, 0.2),
              child: AnimatedOpacity(
                duration: bottomFadeDuration,
                opacity: _bottomHudVisible ? 1 : 0,
                child: AnimatedScale(
                  duration: bottomScaleDuration,
                  scale: _capturePulseActive
                      ? (compactHud ? 0.996 : 1.012)
                      : (compactHud ? 0.985 : 1),
                  child: guidedMode
                      ? (useGuidedStickyBar
                            ? _buildGuidedStickyCtaBar(compactHud: compactHud)
                            : _buildGuidedBottomPanel(compactHud: compactHud))
                      : FrostedOverlayCard(
                          emphasized: _capturePulseActive,
                          padding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: compactHud ? 8 : 12,
                          ),
                          child: DefaultTextStyle.merge(
                            style: const TextStyle(color: Colors.white70),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Wrap(
                                            spacing: 10,
                                            runSpacing: 4,
                                            children: [
                                              const Text(
                                                'Location',
                                                style: TextStyle(
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              Text(
                                                _tracking ? 'Tracking' : 'Idle',
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w700,
                                                  color: _tracking
                                                      ? GameColors
                                                            .statusTracking
                                                      : Colors.grey,
                                                ),
                                              ),
                                              const SizedBox(width: 10),
                                              Text(
                                                _sessionActive
                                                    ? 'Capturing'
                                                    : 'Paused',
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w700,
                                                  color: _sessionActive
                                                      ? GameColors
                                                            .statusSessionOn
                                                      : Colors.grey,
                                                ),
                                              ),
                                              const SizedBox(width: 10),
                                              Text(
                                                'Mine: ${_captureService.capturedHexes.length}',
                                                style: const TextStyle(
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                              Text(
                                                'Visible: ${_mapRenderService.visibleCapturedHex.length}',
                                                style: const TextStyle(
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                              Text(
                                                '🏆 ${_unlockedMilestoneIds.length}/$_totalMilestoneCount',
                                                style: const TextStyle(
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w700,
                                                  color: Colors.white,
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 4),
                                          Text(_currentTile),
                                          const SizedBox(height: 4),
                                          Row(
                                            children: [
                                              AnimatedScale(
                                                duration: const Duration(
                                                  milliseconds: 220,
                                                ),
                                                scale: _capturePulseActive
                                                    ? 1.7
                                                    : 1.0,
                                                child: AnimatedOpacity(
                                                  duration: const Duration(
                                                    milliseconds: 220,
                                                  ),
                                                  opacity: _capturePulseActive
                                                      ? 0.9
                                                      : 1,
                                                  child: Container(
                                                    width: 10,
                                                    height: 10,
                                                    decoration: BoxDecoration(
                                                      color:
                                                          _ownershipBadgeColor(
                                                            _currentGameTile,
                                                          ),
                                                      shape: BoxShape.circle,
                                                      boxShadow:
                                                          _capturePulseActive
                                                          ? [
                                                              BoxShadow(
                                                                color:
                                                                    _ownershipBadgeColor(
                                                                      _currentGameTile,
                                                                    ).withOpacity(
                                                                      0.85,
                                                                    ),
                                                                blurRadius: 10,
                                                                spreadRadius: 2,
                                                              ),
                                                            ]
                                                          : null,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                child: Text(
                                                  'Owned by ${_ownerLabel(_currentGameTile)} • Captured ${_formatSince(_currentGameTile.capturedAt)}',
                                                  style: const TextStyle(
                                                    fontSize: 12,
                                                    color: Colors.white,
                                                  ),
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            _protectionLabel(_currentGameTile),
                                            style: const TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            '${_captureStatusText()} • Radius ${_visibleRadiusMeters.toInt()}m',
                                            style: const TextStyle(
                                              fontSize: 12,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            _trailProgressInlineText(),
                                            style: const TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w600,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          if (!compactHud) ...[
                                            const SizedBox(height: 2),
                                            Text(
                                              _nearestTrailHintText(),
                                              style: const TextStyle(
                                                fontSize: 11,
                                                color: Colors.white70,
                                              ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              _nextObjectiveDetailText(),
                                              style: const TextStyle(
                                                fontSize: 11,
                                                color: Colors.white70,
                                              ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              _sectionSummaryText(),
                                              style: const TextStyle(
                                                fontSize: 11,
                                                color: Colors.white70,
                                              ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              _sectionObjectiveText(),
                                              style: const TextStyle(
                                                fontSize: 11,
                                                color: Colors.white70,
                                              ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              _sectionControlPressureText(),
                                              style: const TextStyle(
                                                fontSize: 11,
                                                color: Colors.white,
                                                fontWeight: FontWeight.w600,
                                              ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                    IconButton(
                                      onPressed: _showCurrentTileDetails,
                                      color: Colors.white,
                                      icon: const Icon(
                                        Icons.assistant_navigation,
                                      ),
                                      tooltip: 'Tile details',
                                    ),
                                    const SizedBox(width: 12),
                                    AnimatedScale(
                                      duration: const Duration(
                                        milliseconds: 220,
                                      ),
                                      scale: _capturePulseActive ? 1.06 : 1.0,
                                      child: FilledButton(
                                        onPressed: _currentTile.isEmpty
                                            ? null
                                            : _captureCurrentTile,
                                        style: FilledButton.styleFrom(
                                          backgroundColor: GameColors.neonGreen,
                                          foregroundColor: Colors.black,
                                        ),
                                        child: Text(
                                          _captured ? 'Captured' : 'Capture',
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                ),
              ),
            ),
          ),
          if (_captureFeedbackText != null)
            Positioned(
              left: 0,
              right: 0,
              top: topInset + 150,
              child: IgnorePointer(
                child: Center(
                  child: _CaptureFeedbackOverlay(
                    text: _captureFeedbackText!,
                    success: _captureFeedbackSuccess,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
