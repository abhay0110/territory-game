import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mb;
import 'package:h3_flutter/h3_flutter.dart' as h3;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/constants/game_colors.dart';
import '../../../core/constants/game_rules.dart';
import '../../../core/constants/launch_corridor.dart';
import '../../../core/constants/seattle_trails.dart';
import '../../../core/constants/valid_trail_hexes.dart';
import '../../../core/theme/game_ui_tokens.dart';
import '../../../models/game_tile.dart';
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
import '../widgets/session_share_card.dart';
import '../../data/services/milestone_evaluator.dart';
import '../../data/services/objective_engine_service.dart';
import '../../data/services/recommendation_scoring_service.dart';
import '../../data/services/trail_leaderboard_service.dart';
import '../../state/game_state.dart';
import '../../state/game_state_notifier.dart';
import '../widgets/capture_feedback_overlay.dart';
import '../widgets/frosted_overlay_card.dart';
import '../widgets/guided_cta_panel.dart';
import '../widgets/guided_top_hud.dart';
import '../widgets/hud_pill.dart';
import '../widgets/selected_tile_info_card.dart';
import '../widgets/map_legend.dart';
import '../widgets/section_progress_dialog.dart';
import '../widgets/tile_details_dialog.dart';
import '../widgets/trail_leaderboard_sheet.dart';
import '../widgets/welcome_dialog.dart';

// HudPreference and HudPersonality are now in game_state.dart, re-exported here
// for backward compat with widget code that references them directly.
export '../../state/game_state.dart' show HudPreference, HudPersonality;

class MapScreen extends ConsumerStatefulWidget {
  /// When true the leaderboard sheet opens automatically after bootstrap.
  final bool openLeaderboard;

  const MapScreen({super.key, this.openLeaderboard = false});

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _SummaryStat {
  final IconData? icon;
  final String? emoji;
  final String label;
  final String value;
  final bool hero;
  const _SummaryStat(this.icon, this.label, this.value, {this.hero = false})
      : emoji = null;
  const _SummaryStat.emoji(this.emoji, this.label, this.value)
      : icon = null, hero = false;
}

/// Animated session summary card with entrance fade+scale+slide and staggered
/// content reveal. Shared by Walk/Run and Ride.
class _AnimatedSessionSummary extends StatefulWidget {
  final bool riding;
  final String title;
  final String subtitle;
  final String distanceText;
  final String timeText;
  final int tilesCaptured;
  final List<_SummaryStat> stats;
  final VoidCallback onShare;

  const _AnimatedSessionSummary({
    required this.riding,
    required this.title,
    required this.subtitle,
    required this.distanceText,
    required this.timeText,
    required this.tilesCaptured,
    required this.stats,
    required this.onShare,
  });

  @override
  State<_AnimatedSessionSummary> createState() =>
      _AnimatedSessionSummaryState();
}

class _AnimatedSessionSummaryState extends State<_AnimatedSessionSummary>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _cardFade;
  late final Animation<double> _cardScale;
  late final Animation<Offset> _cardSlide;

  // Stagger slots: header, hero, each regular stat, trail bar, buttons.
  // We pre-build an interval list so each group fades in sequentially.
  static const _totalMs = 420;
  static const _staggerMs = 40;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: _totalMs),
    );
    _cardFade = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.0, 0.55, curve: Curves.easeOut),
    );
    _cardScale = Tween<double>(begin: 0.92, end: 1.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.0, 0.55, curve: Curves.easeOutCubic),
      ),
    );
    _cardSlide = Tween<Offset>(begin: const Offset(0, 0.06), end: Offset.zero)
        .animate(
          CurvedAnimation(
            parent: _ctrl,
            curve: const Interval(0.0, 0.55, curve: Curves.easeOutCubic),
          ),
        );
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// Returns opacity animation for stagger slot [index] (0-based).
  Animation<double> _slotFade(int index) {
    final startFrac = (index * _staggerMs) / _totalMs;
    final endFrac = ((index * _staggerMs) + 180) / _totalMs;
    return CurvedAnimation(
      parent: _ctrl,
      curve: Interval(
        startFrac.clamp(0.0, 1.0),
        endFrac.clamp(0.0, 1.0),
        curve: Curves.easeOut,
      ),
    );
  }

  Widget _staggerWrap(int slot, Widget child) {
    return FadeTransition(opacity: _slotFade(slot), child: child);
  }

  @override
  Widget build(BuildContext context) {
    final riding = widget.riding;
    final stats = widget.stats;

    // Assign stagger slots:
    // 0 = header (icon + title + subtitle)
    // 1 = divider + hero stat
    // 2..n = regular stat rows
    // n+1 = trail bar (if present)
    // n+2 = buttons
    var slot = 0;
    final headerSlot = slot++;
    final heroSlot = slot++;
    final regularStartSlot = slot;
    final regularCount = stats.where((s) => !s.hero).length;
    slot += regularCount;
    final buttonSlot = slot++;

    return FadeTransition(
      opacity: _cardFade,
      child: SlideTransition(
        position: _cardSlide,
        child: ScaleTransition(
          scale: _cardScale,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Material(
                color: Colors.transparent,
                child: FrostedOverlayCard(
                  emphasized: true,
                  borderRadius: const BorderRadius.all(Radius.circular(18)),
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // ── Mode icon + title ──
                      _staggerWrap(
                        headerSlot,
                        Column(
                          children: [
                            Icon(
                              riding ? Icons.pedal_bike : Icons.directions_walk,
                              color: GameUiTokens.accentPrimary,
                              size: 28,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              widget.title,
                              style: GameUiText.command(
                                color: GameUiTokens.accentPrimary,
                                size: 16,
                                letterSpacing: 1.5,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              widget.subtitle,
                              style: GameUiText.meta(
                                color: GameUiTokens.textMid,
                                size: 11,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      // ── Divider + stats ──
                      _staggerWrap(
                        heroSlot,
                        Column(
                          children: [
                            Container(
                              height: 1,
                              color: GameUiTokens.panelBorder.withOpacity(0.50),
                            ),
                            const SizedBox(height: 12),
                            // Hero stat (first hero in list)
                            ...stats
                                .where((s) => s.hero)
                                .map(
                                  (s) => Padding(
                                    padding: const EdgeInsets.only(bottom: 10),
                                    child: Column(
                                      children: [
                                        Text(
                                          s.value,
                                          style: GameUiText.command(
                                            color: GameUiTokens.accentSecondary,
                                            size: 26,
                                            letterSpacing: 0.5,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          s.label.toUpperCase(),
                                          style: GameUiText.meta(
                                            color: GameUiTokens.textMid,
                                            size: 10,
                                            weight: FontWeight.w700,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                          ],
                        ),
                      ),
                      // ── Regular stat rows (individually staggered) ──
                      ...() {
                        var idx = 0;
                        return stats.where((s) => !s.hero).map((s) {
                          final thisSlot = regularStartSlot + idx;
                          idx++;
                          return _staggerWrap(
                            thisSlot,
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 5),
                              child: Row(
                                children: [
                                  if (s.emoji != null)
                                    Text(
                                      s.emoji!,
                                      style: const TextStyle(fontSize: 14),
                                    )
                                  else
                                    Icon(
                                      s.icon,
                                      size: 16,
                                      color: GameUiTokens.textMid,
                                    ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      s.label,
                                      style: GameUiText.meta(
                                        color: GameUiTokens.textMid,
                                        size: 12,
                                        weight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    s.value,
                                    style: GameUiText.body(
                                      color: GameUiTokens.textHi,
                                      size: 14,
                                      weight: FontWeight.w800,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }).toList();
                      }(),
                      const SizedBox(height: 18),
                      // ── Action buttons ──
                      _staggerWrap(
                        buttonSlot,
                        Column(
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: TextButton(
                                    style: TextButton.styleFrom(
                                      backgroundColor:
                                          GameUiTokens.bg2.withOpacity(0.60),
                                      foregroundColor: GameUiTokens.textMid,
                                      shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(10),
                                        side: BorderSide(
                                          color: GameUiTokens.panelBorder
                                              .withOpacity(0.60),
                                        ),
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 12,
                                      ),
                                    ),
                                    onPressed: widget.onShare,
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Icon(
                                          Icons.share,
                                          size: 14,
                                          color: GameUiTokens.textMid,
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          'SHARE',
                                          style: GameUiText.command(
                                            color: GameUiTokens.textMid,
                                            size: 12,
                                            letterSpacing: 0.8,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: TextButton(
                                    style: TextButton.styleFrom(
                                      backgroundColor: GameUiTokens
                                          .accentPrimary
                                          .withOpacity(0.12),
                                      foregroundColor:
                                          GameUiTokens.accentPrimary,
                                      shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(10),
                                        side: BorderSide(
                                          color: GameUiTokens.accentPrimary
                                              .withOpacity(0.30),
                                        ),
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 12,
                                      ),
                                    ),
                                    onPressed: () =>
                                        Navigator.of(context).pop(),
                                    child: Text(
                                      'DONE',
                                      style: GameUiText.command(
                                        color: GameUiTokens.accentPrimary,
                                        size: 13,
                                        letterSpacing: 1.0,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MapScreenState extends ConsumerState<MapScreen> {
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
  String? _lastSessionCaptureAttemptHex;

  // ── Session state (single source of truth in Riverpod) ──
  bool get _sessionActive => ref.read(gameStateProvider).sessionActive;
  DateTime? get _sessionStartedAt =>
      ref.read(gameStateProvider).sessionStartedAt;
  double get _sessionDistanceMeters =>
      ref.read(gameStateProvider).sessionDistanceMeters;
  int get _sessionTilesCaptured =>
      ref.read(gameStateProvider).sessionTilesCaptured;
  int get _sessionTilesRefreshed =>
      ref.read(gameStateProvider).sessionTilesRefreshed;
  int get _sessionRivalBlocked =>
      ref.read(gameStateProvider).sessionRivalBlocked;
  int get _sessionTakeovers => ref.read(gameStateProvider).sessionTakeovers;
  DateTime? _lastAutoCaptureAttemptAt;
  final Map<String, DateTime> _recentAutoCaptureByHex = {};
  String? _pendingAutoCaptureHex;
  DateTime? _enteredPendingTileAt;

  double? _lastLat;
  double? _lastLng;
  double? _lastAccuracy;

  static const int h3Resolution = 9;
  double _visibleRadiusMeters = GameRules.visibleCapturedRadiusMeters;

  /// Pre-session activity-mode selection (Walk/Run default).
  ActivityMode _selectedActivityMode = ActivityMode.walkRun;

  /// Activity-mode-aware configuration for the current session.
  ActivityModeConfig get _modeConfig =>
      ActivityModeConfig(ref.read(gameStateProvider).sessionActivityMode);

  /// Whether the active (or selected) session mode is Ride.
  bool get _isRiding =>
      (_sessionActive
          ? ref.read(gameStateProvider).sessionActivityMode
          : _selectedActivityMode) ==
      ActivityMode.ride;

  // Prefs keys managed by provider are in GameStateNotifier.
  // Only auto-capture local key remains here.
  static const String _prefsSessionLastHex = 'session_last_hex_v1';
  static const String _prefsOnboardingShown = 'onboarding_shown_v1';
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
  // ── Milestones & session milestones (single source of truth in Riverpod) ──
  Set<String> get _unlockedMilestoneIds =>
      ref.read(gameStateProvider).unlockedMilestoneIds;
  List<String> get _sessionMilestones =>
      ref.read(gameStateProvider).sessionMilestones;
  // Migrated to provider — getters for backward-compat with build helpers.
  bool get _capturePulseActive =>
      ref.read(gameStateProvider).capturePulseActive;
  String? get _captureFeedbackText =>
      ref.read(gameStateProvider).captureFeedbackText;
  bool get _captureFeedbackSuccess =>
      ref.read(gameStateProvider).captureFeedbackSuccess;
  Timer? _capturePulseTimer;
  bool _legendVisible = false;
  bool _actionRailVisible = false;
  bool _mapLegendVisible = false;
  bool _bottomHudVisible = false;
  bool _compactHud = false;
  bool _showRecommendationDebug = false;
  int get _sessionsStartedCount =>
      ref.read(gameStateProvider).sessionsStartedCount;
  Timer? _hudIntroTimer;
  Timer? _actionRailIntroTimer;
  Timer? _mapLegendIntroTimer;
  Timer? _bottomHudIntroTimer;
  Timer? _compactHudIdleTimer;
  Timer? _selectedTileTicker;
  Timer? _recommendedTilePulseTimer;
  String? _recommendedTileHex;
  ({double lat, double lng})? _recommendedGuidancePoint;
  int _recommendedGlowSyncToken = 0;
  bool _recommendedPulseOn = false;
  // Migrated to provider — getters for backward-compat.
  bool get _showPostCaptureGuidance =>
      ref.read(gameStateProvider).showPostCaptureGuidance;
  bool get _guidedCameraCenteredOnce =>
      ref.read(gameStateProvider).guidedCameraCenteredOnce;
  Timer? _captureFeedbackTimer;
  Timer? _postCaptureHintTimer;

  // Tap-to-select state
  List<GameTile> _visibleTiles = const [];

  Timer? _nearbyRefreshTimer;

  // ── Launch corridor (one-trail-first) ──
  String? _corridorEntryHex;
  double _corridorEntryDistanceMeters = double.infinity;
  bool _showLaunchBanner = false;
  bool _corridorLaneRequested = false;

  // ── Leaderboard teaser (lightweight prefetch) ──
  int? _leaderboardRank;
  int? _leaderboardTiles;
  int? _leaderboardTotalPlayers;
  Timer? _leaderboardRefreshTimer;

  int _simStep = 0;
  double? _simBaseLat;
  double? _simBaseLng;

  @override
  void initState() {
    super.initState();
    // Full-screen immersive: hide status & nav bars on the map.
    // User can swipe from edge to temporarily reveal them.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    mb.MapboxOptions.setAccessToken(kMapboxAccessToken);

    _selectedTileTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final hasSelectedTile =
          ref.read(gameStateProvider).selectedTile != null;
      if (!hasSelectedTile && !_sessionActive) return;
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
    // Milestones now load via loadFromPrefs() inside _bootstrapInstantFirstCapture.
    unawaited(_bootstrapInstantFirstCapture());
    // Defer objective update so it does not mutate a provider while the
    // widget tree is still building (Riverpod guard).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _updateCurrentObjective();
    });
  }

  @override
  void dispose() {
    // Restore normal edge-to-edge mode when leaving the map.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
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
    _leaderboardRefreshTimer?.cancel();
    _mapRenderService.dispose();
    super.dispose();
  }

  void _triggerCapturePulse() {
    _capturePulseTimer?.cancel();
    if (mounted) {
      ref.read(gameStateProvider.notifier).setCapturePulseActive(true);
    }

    _capturePulseTimer = Timer(const Duration(milliseconds: 420), () {
      if (!mounted) return;
      ref.read(gameStateProvider.notifier).setCapturePulseActive(false);
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

    if (ref.read(gameStateProvider).selectedHex == hexLower) {
      // Second tap on same hex → deselect.
      _dismissSelection();
      return;
    }

    // Only allow on-trail hexes.
    // Accept if the hex is in the playable set (ValidTrailHexes) OR the
    // visual trail corridor (displayHexes).  Both exclude water/blacklisted
    // hexes.  Off-trail hexes are in neither set → blocked.
    if (!ValidTrailHexes.isValid(hexLower) &&
        !LaunchCorridor.displayHexes.contains(hexLower)) {
      _dismissSelection();
      return;
    }

    // Look up tile data from the visible set or capture service; for trail
    // hexes beyond the ring-7 disk (visible via corridor lane), fall back to
    // the corridor ownership cache or a neutral placeholder.
    final tile = _visibleTiles
            .where((t) => t.h3Index.toLowerCase() == hexLower)
            .firstOrNull ??
        _captureService.getTileByHex(hexLower) ??
        GameTile(h3Index: hexLower, ownership: TileOwnership.neutral);

    ref.read(gameStateProvider.notifier).selectTile(tile, hexLower);
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
        _isRiding
            ? 'Keep riding — auto-capture is live'
            : 'Hold position or keep moving - auto-capture is live',
      );
      return;
    }

    _showCaptureFeedback(
      _isRiding ? 'Ride to the glowing tile' : 'Move to the glowing tile',
    );
  }

  void _dismissSelection() {
    if (ref.read(gameStateProvider).selectedHex == null) return;
    ref.read(gameStateProvider.notifier).dismissSelection();
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

  /// Compute the nearest Burke-Gilman entry hex and draw the corridor lane.
  void _resolveCorridorEntry(double lat, double lng) {
    final entry = LaunchCorridor.nearestEntry(
      lat,
      lng,
      haversine: MapRenderService.haversineMeters,
      cellCentroid: _mapRenderService.cellCentroid,
    );
    if (entry == null) return;

    _corridorEntryHex = entry.hex;
    _corridorEntryDistanceMeters = entry.distanceMeters;

    // Show launch banner when user is far enough that normal reco won't fire.
    // Guard: only set once so repeated location updates don't re-assert.
    if (!_showLaunchBanner &&
        entry.distanceMeters > _modeConfig.maxRecommendationDistanceMeters) {
      _showLaunchBanner = true;
      _mapRenderService.launchEntryMode = true;
    }

    _drawCorridorLaneIfNeeded();
  }

  Future<void> _drawCorridorLaneIfNeeded() async {
    if (_corridorLaneRequested || _map == null) return;
    _corridorLaneRequested = true;
    // Use the wider display set for visual continuity; playable set is unchanged.
    await _mapRenderService.drawCorridorLane(
      LaunchCorridor.displayHexes.toList(),
    );
  }

  /// Fly camera to frame both user and nearest corridor entry so the user
  /// can visually see which part of the trail they are heading toward.
  ///
  /// Uses Mapbox `cameraForCoordinateBounds` to compute the optimal zoom
  /// and center.  Clamps zoom to [11, 15] so we never show the full city
  /// and never zoom in too tight.
  Future<void> _maybeFlyToCorridorOverview(
    double userLat,
    double userLng,
  ) async {
    if (_corridorEntryHex == null) return;
    if (_corridorEntryDistanceMeters <=
        _modeConfig.maxRecommendationDistanceMeters) {
      return;
    }
    final map = _map;
    if (map == null) return;

    try {
      final cell = BigInt.parse(_corridorEntryHex!, radix: 16);
      final entry = _mapRenderService.cellCentroid(cell, _corridorEntryHex!);

      final sw = mb.Point(
        coordinates: mb.Position(
          math.min(userLng, entry.lng),
          math.min(userLat, entry.lat),
        ),
      );
      final ne = mb.Point(
        coordinates: mb.Position(
          math.max(userLng, entry.lng),
          math.max(userLat, entry.lat),
        ),
      );

      final camera = await map.cameraForCoordinateBounds(
        mb.CoordinateBounds(
          southwest: sw,
          northeast: ne,
          infiniteBounds: false,
        ),
        mb.MbxEdgeInsets(top: 120, left: 64, bottom: 180, right: 64),
        null, // bearing
        null, // pitch
        15.0, // maxZoom — never tighter than neighbourhood level
        null, // offset
      );

      final zoom = (camera.zoom ?? 13.0).clamp(11.0, 15.0);

      map.flyTo(
        mb.CameraOptions(center: camera.center, zoom: zoom, pitch: 40),
        mb.MapAnimationOptions(duration: 1200),
      );
    } catch (_) {}
  }

  Future<void> _loadSessionState() async {
    // Load persisted session, HUD, and milestone state into the provider.
    await ref.read(gameStateProvider.notifier).loadFromPrefs();

    // Load auto-capture local state.
    final prefs = await SharedPreferences.getInstance();
    final lastHex = prefs.getString(_prefsSessionLastHex);
    if (!mounted) return;
    _lastSessionCaptureAttemptHex = lastHex;

    _refreshFirstSessionGuidanceState();

    // For MVP, always start in pre-session state when the map opens.
    // The user must explicitly tap "Start Session" to begin gameplay.
    // This prevents stale persisted sessions from auto-restoring and
    // making "Enter the Battle" feel like it starts a session.
    if (_sessionActive) {
      ref.read(gameStateProvider.notifier).stopSession();
      unawaited(_saveSessionState());
    }
  }

  /// Shows the welcome dialog exactly once (first-run onboarding).
  Future<void> _maybeShowOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    final shown = prefs.getBool(_prefsOnboardingShown) ?? false;
    if (shown || !mounted) return;
    await prefs.setBool(_prefsOnboardingShown, true);
    if (!mounted) return;
    await showWelcomeDialog(context);
  }

  Future<void> _bootstrapInstantFirstCapture() async {
    await _loadSessionState();

    // Show first-run onboarding if it hasn't been shown yet.
    await _maybeShowOnboarding();

    final pos = await _mapController.getCurrentPosition(context);
    if (pos != null) {
      // Resolve corridor entry before moving camera so we can override the
      // camera target when the user is far from the active trail.
      _resolveCorridorEntry(pos.latitude, pos.longitude);

      final farFromCorridor =
          _corridorEntryDistanceMeters >
          _modeConfig.maxRecommendationDistanceMeters;
      await _refreshMapForCoordinates(
        pos.latitude,
        pos.longitude,
        moveCamera: !farFromCorridor,
        accuracy: pos.accuracy,
      );

      if (farFromCorridor) {
        unawaited(_maybeFlyToCorridorOverview(pos.latitude, pos.longitude));
      }

      unawaited(_startTracking());
    }

    await _syncRecommendedTileGlow(currentLat: _lastLat, currentLng: _lastLng);

    // Prefetch lightweight leaderboard teaser for Guided HUD pill.
    unawaited(_prefetchLeaderboardTeaser());

    // If launched with openLeaderboard flag (e.g. from home screen Trail
    // Rankings card), show the leaderboard sheet once the map is ready.
    if (widget.openLeaderboard) {
      // Small delay so the map renders before the sheet slides up.
      Future.delayed(const Duration(milliseconds: 600), () {
        if (mounted) _showLeaderboard();
      });
    }
  }

  Future<void> _startSessionSilently({
    required bool incrementSessionCount,
  }) async {
    if (_sessionActive) return;

    // Start session in provider (single source of truth for counters).
    final notifier = ref.read(gameStateProvider.notifier);
    if (incrementSessionCount) {
      notifier.startSession(
        lastLat: _lastLat,
        lastLng: _lastLng,
        activityMode: _selectedActivityMode,
      );
    } else {
      notifier.startSessionSilently(lastLat: _lastLat, lastLng: _lastLng);
    }

    // Reset auto-capture local state.
    _lastSessionCaptureAttemptHex = null;
    _lastAutoCaptureAttemptAt = null;
    _recentAutoCaptureByHex.clear();
    _pendingAutoCaptureHex = null;
    _enteredPendingTileAt = null;

    // Trigger rebuild for HUD.
    if (mounted) setState(() {});

    await _saveSessionState();
    await _unlockMilestones([
      (id: 'first_session_start', title: '🎬 First session started'),
    ]);
    _eventLog.log(MapEventType.sessionStarted, 'Session started');
    _updateCurrentObjective();
  }

  void _refreshFirstSessionGuidanceState() {
    ref
        .read(gameStateProvider.notifier)
        .refreshFirstSessionGuidance(
          hasCapturedAnyTile: _captureService.capturedHexes.isNotEmpty,
        );
  }

  bool get _isGuidedFirstCaptureMode =>
      ref.read(isGuidedFirstCaptureModeProvider);

  Future<void> _startGuidedSessionFromCta() async {
    if (_sessionActive) return;

    await HapticFeedback.mediumImpact();
    await _startSessionSilently(incrementSessionCount: true);
    if (_showLaunchBanner) {
      _showLaunchBanner = false;
      // launchEntryMode is now driven by _isFarFromCorridor in the refresh
      // loop — do NOT force it off here so muting and corridor constraint
      // persist until the user is physically near the corridor.
    }
    if (!_tracking) {
      unawaited(_startTracking());
    }
    if (!mounted) return;

    await _syncRecommendedTileGlow(currentLat: _lastLat, currentLng: _lastLng);
    final hasTarget = _recommendedTileHex != null;
    _showCaptureFeedback(
      hasTarget
          ? (_isFarFromCorridor
                ? (_isRiding
                      ? 'Session live — Ride to ${LaunchCorridor.activeTrailName}'
                      : 'Session live - Head to ${LaunchCorridor.activeTrailName}')
                : (_isRiding
                      ? 'Session live — Ride to the glowing tile'
                      : 'Session live - Move to the glowing tile'))
          : (_isRiding
                ? 'Session live — Captures happen as you ride'
                : 'Session live - Auto-capture on movement'),
      duration: const Duration(milliseconds: 1900),
    );
  }

  void _showCaptureFeedback(
    String text, {
    bool success = false,
    Duration duration = const Duration(milliseconds: 1700),
  }) {
    _captureFeedbackTimer?.cancel();
    if (!mounted) return;
    ref
        .read(gameStateProvider.notifier)
        .showCaptureFeedback(text, success: success);
    _captureFeedbackTimer = Timer(duration, () {
      if (!mounted) return;
      ref.read(gameStateProvider.notifier).clearCaptureFeedback();
    });
  }

  void _onFirstCaptureCompleted() {
    if (ref.read(gameStateProvider).firstCaptureCelebrated) return;
    _dismissSelection();
    ref.read(gameStateProvider.notifier).onFirstCaptureCompleted();
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
      ref.read(gameStateProvider.notifier).clearPostCaptureGuidance();
    });
  }

  Future<void> _saveSessionState() async {
    // Persist provider-managed session/HUD/milestone state.
    await ref.read(gameStateProvider.notifier).saveToPrefs();

    // Persist auto-capture local state.
    final prefs = await SharedPreferences.getInstance();
    if (_lastSessionCaptureAttemptHex == null) {
      await prefs.remove(_prefsSessionLastHex);
    } else {
      await prefs.setString(
        _prefsSessionLastHex,
        _lastSessionCaptureAttemptHex!,
      );
    }
  }

  // Milestone loading is now handled by GameStateNotifier.loadFromPrefs()
  // called inside _loadSessionState(). No separate _loadMilestoneState needed.

  Future<void> _saveMilestoneState() async {
    // Milestones are in the provider — save via saveToPrefs which includes them.
    await ref.read(gameStateProvider.notifier).saveToPrefs();
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

    // Accumulate session distance via the provider.
    // Returns false if movement exceeds the mode speed limit (anti-cheat).
    final movementValid = ref
        .read(gameStateProvider.notifier)
        .accumulateSessionDistance(
          lat,
          lng,
          maxSpeedMetersPerSecond: _modeConfig.maxSpeedMetersPerSecond,
        );

    final previousHex = _currentCell?.toRadixString(16).toLowerCase();

    // Resolve corridor entry BEFORE camera decisions so _isFarFromCorridor
    // reflects this position, not the previous one.
    if (_corridorEntryHex != null) {
      _resolveCorridorEntry(lat, lng);
      if (_showLaunchBanner &&
          _corridorEntryDistanceMeters <=
              _modeConfig.maxRecommendationDistanceMeters) {
        setState(() => _showLaunchBanner = false);
      }
    }

    // Sync the launch-entry visual mode so captured tiles are muted/normal.
    // Use distance-based check so muting persists even after session start.
    _mapRenderService.launchEntryMode = _isFarFromCorridor;

    final result = await _mapController.refreshMapForCoordinates(
      lat,
      lng,
      radiusMeters: _visibleRadiusMeters,
      includePreviewEnemyTiles: ref
          .read(gameStateProvider)
          .showPreviewEnemyTiles,
      trailOnlyRendering: !_isFarFromCorridor,
      corridorHexes: LaunchCorridor.hexes.toList(),
    );
    _applyRefreshResult(result, currentLat: lat, currentLng: lng);

    // Only attempt auto-capture when movement is valid for the current mode.
    // This prevents car-speed movement in Walk/Run from awarding tiles.
    if (movementValid) {
      await _maybeAutoCaptureOnTileEntry(
        previousHex: previousHex,
        currentHex: result.currentHex,
        latitude: lat,
        longitude: lng,
        accuracy: accuracy,
      );
    }

    // When far from the active corridor, the corridor-overview camera is
    // the visual guide — skip the user-centered camera so the overview
    // framing is preserved until the user is close enough.
    if (!_isFarFromCorridor) {
      final cameraUpdate = _mapController.buildCameraUpdate(
        lat,
        lng,
        moveCamera: moveCamera,
        zoom: _modeConfig.defaultCameraZoom,
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
            pitch: 45,
          ),
          mb.MapAnimationOptions(duration: cameraUpdate.durationMs),
        );
      }
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
        now.difference(enteredAt) < _modeConfig.autoCaptureDwellTime) {
      return;
    }

    if (_lastSessionCaptureAttemptHex == currentHex) return;
    if (_lastAutoCaptureAttemptAt != null &&
        now.difference(_lastAutoCaptureAttemptAt!) <
            _modeConfig.autoCaptureDebounce) {
      return;
    }
    final recent = _recentAutoCaptureByHex[currentHex];
    if (recent != null &&
        now.difference(recent) < _modeConfig.autoCaptureTileCooldown) {
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
      includePreviewEnemyTiles: ref
          .read(gameStateProvider)
          .showPreviewEnemyTiles,
      trailOnlyRendering: !_isFarFromCorridor,
      corridorHexes: LaunchCorridor.hexes.toList(),
    );

    final result = flowResult.captureAttempt;
    if (!mounted) return;

    if (result.didCapture && result.synced) {
      // Immediately redraw the just-captured hex green without waiting
      // for the next periodic refresh cycle.
      final capturedTile = _captureService.getTileByHex(currentHex);
      if (capturedTile != null) {
        unawaited(_mapRenderService.forceRedrawHex(capturedTile));
      }

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
          'Auto-capture takeover ✅',
        CaptureAttemptStatus.protectionRefreshed =>
          'Auto-capture refreshed protection ✅',
        _ =>
          'Auto-capture success ✅',
      };

      _logCaptureEvent(result, currentHex, auto: true);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
      return;
    }

    if (result.didCapture && !result.synced) {
      // Capture attempt ran but Supabase write failed — do NOT count.
      debugPrint('[AutoCapture] ⚠️ didCapture but NOT synced for $currentHex');
      _logCaptureEvent(result, currentHex, auto: true);
      // Allow retry on next dwell cycle.
      _lastSessionCaptureAttemptHex = null;
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Capture failed to sync — will retry')));
      return;
    }

    // Capture did not succeed — allow retry on next dwell cycle.
    _lastSessionCaptureAttemptHex = null;

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
    setState(() {
      _currentCell = cell;
      _currentTile = result.currentHex;
      _captured = result.isCaptured;
      _currentGameTile = result.currentTile;
      _visibleTiles = result.visibleTiles;
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

    // Refresh selected tile info from provider after map update.
    final selectedHex = ref.read(gameStateProvider).selectedHex;
    var shouldClearSelection = false;
    if (selectedHex != null) {
      final refreshed = result.visibleTiles
          .where((t) => t.h3Index.toLowerCase() == selectedHex)
          .firstOrNull;
      if (refreshed != null) {
        ref.read(gameStateProvider.notifier).selectTile(refreshed, selectedHex);
      } else {
        ref.read(gameStateProvider.notifier).dismissSelection();
        shouldClearSelection = true;
      }
    }

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

  /// Direction from the player to a specific hex (used for glow-aligned copy).
  ///
  /// If the hex is the current recommended target and a snapped guidance
  /// point exists, the direction is calculated toward the trail polyline
  /// point rather than the raw hex centroid.
  String? _directionToHex(String targetHex) {
    final currentLat = _lastLat;
    final currentLng = _lastLng;
    if (currentLat == null || currentLng == null) return null;

    try {
      // Prefer the snapped guidance point for the recommended hex.
      final ({double lat, double lng}) target;
      if (targetHex == _recommendedTileHex &&
          _recommendedGuidancePoint != null) {
        target = _recommendedGuidancePoint!;
      } else {
        final cell = BigInt.parse(targetHex, radix: 16);
        final c = _mapRenderService.cellCentroid(cell, targetHex);
        target = (lat: c.lat, lng: c.lng);
      }
      final dLat = target.lat - currentLat;
      final dLng = target.lng - currentLng;

      // If the player is essentially on top of the target, don't guess.
      if (dLat.abs() < 1e-6 && dLng.abs() < 1e-6) return null;

      if (dLat.abs() >= dLng.abs()) {
        return dLat >= 0 ? 'north' : 'south';
      }
      return dLng >= 0 ? 'east' : 'west';
    } catch (_) {
      return null;
    }
  }

  /// Format a distance in meters as a compact miles string (e.g. "2.3 mi").
  String _formatDistanceMiles(double meters) {
    final miles = meters / 1609.344;
    if (miles < 0.1) return '${(meters).round()} ft';
    return '${miles.toStringAsFixed(1)} mi';
  }

  String? _streakDirectionHint() {
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
    return _directionToHex(hex.toLowerCase());
  }

  ({bool pressure, bool canFlip, bool atRiskDefense, bool strengthensLead})
  _sectionSignalsForHex(String hexLower) {
    return RecommendationScoringService.sectionSignalsForHex(
      hexLower,
      _sectionProgress,
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
    final result = RecommendationScoringService.scoreCandidate(
      tile,
      distance,
      streakTargetHexes,
      _sectionProgress,
      maxCaptureDistanceMeters: _modeConfig.maxRecommendationDistanceMeters,
    );
    return (
      score: result.score,
      distance: result.distance,
      distancePenalty: result.distancePenalty,
      streakBonus: result.streakBonusApplied,
      sectionPressureBonus: result.sectionPressureBonusApplied,
      sectionFlipBonus: result.sectionFlipBonusApplied,
      atRiskDefenseBonus: result.atRiskDefenseBonusApplied,
      strengthenLeadBonus: result.strengthenLeadBonusApplied,
      ownershipBonus: result.ownershipBonusApplied,
      tile: result.tile,
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
        .where((tile) => ValidTrailHexes.isValid(tile.h3Index.toLowerCase()))
        .map(
          (tile) =>
              (tile: tile, d: _distanceToTileMeters(tile, lat: lat, lng: lng)),
        )
        .where((entry) => entry.d != null)
        .map((entry) => (tile: entry.tile, d: entry.d!))
        .where(
          (entry) => entry.d <= _modeConfig.maxRecommendationDistanceMeters,
        )
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
    final guidedMode = _resolveHudPersonality() == HudPersonality.guided;
    // Allow recommendation in Guided mode even pre-session so glow and copy stay in sync.
    if (!_sessionActive && !_isGuidedFirstCaptureMode && !guidedMode) {
      return null;
    }
    if (ref.read(gameStateProvider).selectedHex != null &&
        !_isGuidedFirstCaptureMode &&
        !guidedMode) {
      return null;
    }

    if (_isGuidedFirstCaptureMode && _currentTile.isNotEmpty) {
      final currentHex = _currentTile.toLowerCase();
      if (ValidTrailHexes.isValid(currentHex)) {
        final currentTile = _visibleTiles
            .where((t) => t.h3Index.toLowerCase() == currentHex)
            .firstOrNull;
        if (currentTile != null && _isTileCapturable(currentTile)) {
          return currentTile;
        }
      }
    }

    final ranked = _rankRecommendationCandidates(lat: lat, lng: lng);
    if (ranked.isEmpty) return null;

    return RecommendationScoringService.applyHysteresis(
      rankedCandidates: ranked
          .map((item) => (score: item.score, tile: item.tile))
          .toList(growable: false),
      currentRecommendedHex: _recommendedTileHex,
    );
  }

  /// Whether the user is still outside the corridor-entry zone.
  ///
  /// This is a distance-based check, NOT tied to `_showLaunchBanner` (which
  /// is a UI element dismissed on session start).  The corridor recommendation
  /// constraint must remain active regardless of banner/session state until
  /// the user is physically close enough to the corridor.
  bool get _isFarFromCorridor =>
      _corridorEntryHex != null &&
      _corridorEntryDistanceMeters >
          _modeConfig.maxRecommendationDistanceMeters;

  String? _guidedPriorityTargetHex({double? lat, double? lng}) {
    final guidedMode = _resolveHudPersonality() == HudPersonality.guided;
    // Allow target resolution in Guided mode pre-session so copy and glow align.
    if (!_sessionActive && !_isGuidedFirstCaptureMode && !guidedMode) {
      return null;
    }

    // When the user is far from the active corridor, constrain
    // recommendations to the corridor entry hex — do NOT fall through to
    // normal local tile recommendations.  This holds even after session start.
    if (_isFarFromCorridor && guidedMode && _corridorEntryHex != null) {
      return _corridorEntryHex;
    }

    final reco = _bestRecommendedCapturableTile(
      lat: lat,
      lng: lng,
    )?.h3Index.toLowerCase();
    if (reco != null) return reco;

    // Fallback: when no nearby capturable tiles, guide the user toward the
    // nearest hex on the active launch corridor.
    if (guidedMode && _corridorEntryHex != null) return _corridorEntryHex;
    return null;
  }

  Future<void> _clearRecommendedTileGlow() async {
    _recommendedGlowSyncToken += 1;
    _recommendedTilePulseTimer?.cancel();
    _recommendedTilePulseTimer = null;
    _recommendedTileHex = null;
    _recommendedGuidancePoint = null;
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
    final syncToken = ++_recommendedGlowSyncToken;
    final hudPersonality = _resolveHudPersonality();
    final guidedMode = hudPersonality == HudPersonality.guided;
    final proMode = hudPersonality == HudPersonality.pro;
    final showInPro =
        ref.read(gameStateProvider).currentObjective.actionLabel == 'Capture';

    // Allow glow pre-session in Guided mode so it matches the copy that mentions it.
    if ((!_sessionActive && !_isGuidedFirstCaptureMode && !guidedMode) ||
        (proMode && !showInPro && !_isGuidedFirstCaptureMode) ||
        (ref.read(gameStateProvider).selectedHex != null &&
            !_isGuidedFirstCaptureMode &&
            !guidedMode)) {
      if (syncToken != _recommendedGlowSyncToken) return;
      await _clearRecommendedTileGlow();
      return;
    }

    final targetHex = _guidedPriorityTargetHex(
      lat: currentLat,
      lng: currentLng,
    );
    if (targetHex == null) {
      if (syncToken != _recommendedGlowSyncToken) return;
      await _clearRecommendedTileGlow();
      return;
    }

    _recommendedTileHex = targetHex;
    _recommendedGuidancePoint = ValidTrailHexes.guidancePointForHex(targetHex);
    if (kDebugMode) {
      final dist = ValidTrailHexes.debugDistanceForHex(targetHex);
      debugPrint(
        '[HexReco] target=$targetHex '
        'valid=${ValidTrailHexes.isValid(targetHex)} '
        'polylineDist=${dist?.toStringAsFixed(0)}m '
        'guidancePt=$_recommendedGuidancePoint',
      );
    }
    if (_map == null) return;

    // The bounds camera now frames both user and corridor entry on-screen,
    // so draw the glow even when far — it becomes the strongest visual anchor.

    _ensureRecommendedPulseTimer();

    _recommendedPulseOn = !_recommendedPulseOn;
    if (syncToken != _recommendedGlowSyncToken) return;
    await _mapRenderService.drawRecommendedHex(
      targetHex,
      pulseOn: _recommendedPulseOn,
      strong: guidedMode || _isGuidedFirstCaptureMode,
    );
    if (syncToken != _recommendedGlowSyncToken) return;

    if (_isGuidedFirstCaptureMode && !_guidedCameraCenteredOnce) {
      try {
        final cell = BigInt.parse(targetHex, radix: 16);
        final center = _mapRenderService.cellCentroid(cell, targetHex);
        _map?.flyTo(
          mb.CameraOptions(
            center: mb.Point(coordinates: mb.Position(center.lng, center.lat)),
            zoom: _modeConfig.firstCaptureCameraZoom,
            pitch: 45,
          ),
          mb.MapAnimationOptions(duration: 900),
        );
        ref.read(gameStateProvider.notifier).setGuidedCameraCenteredOnce(true);
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
    final checks = MilestoneEvaluator.evaluateAll(
      sessionsStartedCount: _sessionsStartedCount,
      hasCapturedTiles: _captureService.capturedHexes.isNotEmpty,
      trailProgress: _trailProgress,
      sectionProgress: _sectionProgress,
    );

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

    // Filter to truly new milestones using the provider as source of truth.
    final gs = ref.read(gameStateProvider);
    final newlyUnlocked = checks
        .where((c) => !gs.unlockedMilestoneIds.contains(c.id))
        .toList(growable: false);

    if (newlyUnlocked.isEmpty) return;

    // Update provider (adds to both unlockedMilestoneIds and sessionMilestones).
    ref.read(gameStateProvider.notifier).addUnlockedMilestones(newlyUnlocked);
    await _saveMilestoneState();

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

  Future<void> _showLeaderboard() async {
    final service = TrailLeaderboardService(
      supabaseClient: _captureService.supabaseClient,
    );
    if (!mounted) return;
    await showTrailLeaderboardSheet(context, service: service);
    // Refresh teaser after the user closes the sheet (data may have changed).
    unawaited(_prefetchLeaderboardTeaser());
  }

  /// Lightweight background fetch for the leaderboard rank/tile teaser.
  /// Updates [_leaderboardRank] and [_leaderboardTiles] used by the
  /// Guided HUD pill without blocking other operations.
  Future<void> _prefetchLeaderboardTeaser() async {
    try {
      final service = TrailLeaderboardService(
        supabaseClient: _captureService.supabaseClient,
      );
      final snapshot = await service.fetchBurkeGilman(topN: 5);
      if (!mounted || snapshot == null) return;
      setState(() {
        _leaderboardRank = snapshot.yourRank;
        _leaderboardTiles = snapshot.yourTotalTiles;
        _leaderboardTotalPlayers = snapshot.totalPlayers;
      });
    } catch (_) {
      // Silently ignore — the teaser pill falls back to generic "Leaderboard".
    }
  }

  /// Start a periodic 60-second leaderboard teaser refresh.
  /// Only runs while a session is active so we're not polling when idle.
  void _startLeaderboardRefreshTimer() {
    _leaderboardRefreshTimer?.cancel();
    _leaderboardRefreshTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => unawaited(_prefetchLeaderboardTeaser()),
    );
  }

  /// Stop the periodic leaderboard refresh (session ended or widget disposed).
  void _stopLeaderboardRefreshTimer() {
    _leaderboardRefreshTimer?.cancel();
    _leaderboardRefreshTimer = null;
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
    // When the target is a corridor entry (user is far from the trail),
    // show corridor-specific messaging instead of objective-based copy.
    if (_corridorEntryHex == targetHex &&
        _corridorEntryDistanceMeters >
            _modeConfig.maxRecommendationDistanceMeters) {
      final direction = _directionToHex(targetHex);
      final dist = _formatDistanceMiles(_corridorEntryDistanceMeters);
      return (
        title: direction == null
            ? '${LaunchCorridor.activeTrailName} is $dist away'
            : 'Head $direction to ${LaunchCorridor.activeTrailName}',
        detail: '$dist to the active battlefield',
        cta: _isRiding ? 'Ride to Trail' : 'Move to Trail',
      );
    }

    final direction = _directionToHex(targetHex);
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
        ? (_isRiding ? 'Ride to the glowing tile' : 'Move to the glowing tile')
        : (_isRiding ? 'Ride $direction' : 'Head $direction');

    if (signals.canFlip ||
        (section != null && section.tilesToTakeControl <= 1)) {
      return (
        title: 'One more tile contests this section',
        detail: direction == null
            ? 'Pressure ${section?.section.name ?? 'the rival section'} on the glowing tile'
            : (_isRiding
                  ? 'Ride $direction to pressure ${section?.section.name ?? 'the rival section'}'
                  : 'Move $direction to pressure ${section?.section.name ?? 'the rival section'}'),
        cta: _isRiding ? 'Ride to Target' : 'Move to Target',
      );
    }

    if (signals.pressure && section != null) {
      return (
        title: 'Pressure the rival section',
        detail: direction == null
            ? '${section.section.name} is the next tactical push'
            : (_isRiding
                  ? 'Ride $direction to pressure ${section.section.name}'
                  : 'Move $direction to pressure ${section.section.name}'),
        cta: _isRiding ? 'Ride to Target' : 'Move to Target',
      );
    }

    if (trail != null &&
        trail.bestNextTileReason == TrailNextTileReason.extendStreak) {
      return (
        title: direction == null
            ? (_isRiding
                  ? 'Ride to the glowing tile'
                  : 'Move to the glowing tile')
            : (_isRiding
                  ? 'Ride $direction to extend your streak'
                  : 'Head $direction to extend your streak'),
        detail:
            'Streak grows to ${trail.projectedOwnedSegmentTiles} on ${trail.trail.name}',
        cta: _isRiding ? 'Ride to Target' : 'Move to Target',
      );
    }

    if (trail != null &&
        trail.bestNextTileReason == TrailNextTileReason.bridgeGap) {
      return (
        title: 'Close the route gap',
        detail: direction == null
            ? 'The glowing tile reconnects your route'
            : '$directionLead to reconnect your route',
        cta: _isRiding ? 'Ride to Target' : 'Move to Target',
      );
    }

    return (
      title: direction == null
          ? (_isRiding
                ? 'Ride to the glowing tile'
                : 'Move to the glowing tile')
          : '$directionLead to target',
      detail:
          ref.read(gameStateProvider).currentObjective.detail ??
          _nextObjectiveDetailText(),
      cta: _isRiding ? 'Ride to Target' : 'Move to Target',
    );
  }

  bool get _isCorridorEntryTarget =>
      _isFarFromCorridor &&
      _corridorEntryHex != null &&
      _corridorEntryHex == _guidedPriorityTargetHex();

  GuidedCtaCopy _guidedCtaCopyForBottomPanel({
    required bool preSession,
    required bool isFirstCapture,
    required bool hasMomentumTarget,
    required bool currentOwnedByMe,
    required String? direction,
    required ({String title, String? detail, String cta})? targetCopy,
    required String? guidedTargetHex,
  }) {
    final corridorEntry = _isCorridorEntryTarget;
    final riding = _isRiding;
    final title = preSession
        ? (corridorEntry
              ? '▶ Tap to start your session'
              : '▶ Start session to begin movement capture')
        : isFirstCapture
        ? (corridorEntry
              ? (riding
                    ? '🎯 Session live — ride to the trail'
                    : '🎯 Session live — move to the trail')
              : direction == null
              ? (riding
                    ? '🎯 Session live — ride to the glowing tile'
                    : '🎯 Session live — move to the glowing tile')
              : (riding
                    ? '🎯 Session live — ride $direction to the glow'
                    : '🎯 Session live — move $direction to the glow'))
        : hasMomentumTarget
        ? targetCopy!.title
        : ref.read(gameStateProvider).currentObjective.title;
    final detail = preSession
        ? (corridorEntry
              ? 'Auto-capture activates near the trail'
              : (riding
                    ? 'Auto-capture activates as you ride through target tiles'
                    : 'Auto-capture activates while you move through target tiles'))
        : isFirstCapture
        ? (riding
              ? 'Tracking is active. Keep riding to trigger your first capture'
              : 'Tracking is active. Keep moving to trigger your first capture')
        : hasMomentumTarget
        ? targetCopy!.detail
        : (currentOwnedByMe
              ? (targetCopy?.detail ??
                    (riding
                        ? 'Ride to the highlighted target to keep momentum'
                        : 'Move to the highlighted target to keep momentum'))
              : ref.read(gameStateProvider).currentObjective.detail);
    final buttonLabel = preSession
        ? 'Start Session'
        : isFirstCapture
        ? (corridorEntry
              ? (riding ? 'Ride to Trail' : 'Move to Trail')
              : (riding ? 'Ride to Glow' : 'Move to Glow'))
        : hasMomentumTarget
        ? targetCopy!.cta
        : (currentOwnedByMe
              ? (targetCopy?.cta ??
                    (riding ? 'Ride to Target' : 'Move to Target'))
              : (riding ? 'Keep Riding' : 'Keep Moving'));
    return GuidedCtaCopy(
      title: title,
      detail: detail,
      buttonLabel: buttonLabel,
    );
  }

  GuidedCtaCopy _guidedCtaCopyForStickyBar({
    required bool preSession,
    required bool isFirstCapture,
    required bool hasMomentumTarget,
    required bool currentOwnedByMe,
    required String? direction,
    required ({String title, String? detail, String cta})? targetCopy,
    required String? guidedTargetHex,
  }) {
    final corridorEntry = _isCorridorEntryTarget;
    final riding = _isRiding;
    final message = preSession
        ? (corridorEntry
              ? '▶ Tap Start to begin capturing'
              : guidedTargetHex != null
              ? (riding
                    ? '▶ Start session, then ride to the glowing tile'
                    : '▶ Start session, then move to the glowing tile')
              : '▶ Start session to begin capturing tiles')
        : isFirstCapture
        ? (corridorEntry
              ? (riding
                    ? '🎯 Session live — ride to the trail'
                    : '🎯 Session live — move to the trail')
              : direction == null
              ? (riding
                    ? '🎯 Session live — ride to the glowing tile'
                    : '🎯 Session live — move to the glowing tile')
              : (riding
                    ? '🎯 Session live — ride $direction to the glow'
                    : '🎯 Session live — move $direction to the glow'))
        : hasMomentumTarget
        ? targetCopy!.title
        : ref.read(gameStateProvider).currentObjective.title;
    final buttonLabel = preSession
        ? 'Start'
        : isFirstCapture
        ? (riding ? 'Ride' : 'Move')
        : hasMomentumTarget
        ? targetCopy!.cta
        : (currentOwnedByMe
              ? (targetCopy?.cta ?? (riding ? 'Ride' : 'Move'))
              : 'Live');
    return GuidedCtaCopy(title: message, buttonLabel: buttonLabel);
  }

  /// Shared computed state for both CTA variants.
  ({
    bool preSession,
    bool isFirstCapture,
    bool hasMomentumTarget,
    bool currentOwnedByMe,
    String? direction,
    ({String title, String? detail, String cta})? targetCopy,
    String? guidedTargetHex,
  })
  _guidedCtaState() {
    final guidedTargetHex = _guidedPriorityTargetHex();
    final targetCopy = guidedTargetHex == null
        ? null
        : _guidedMovementCopy(guidedTargetHex);
    final onRecommendedTile =
        guidedTargetHex != null &&
        _currentTile.isNotEmpty &&
        guidedTargetHex == _currentTile.toLowerCase();
    final direction = guidedTargetHex == null
        ? null
        : _directionToHex(guidedTargetHex);
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
    return (
      preSession: preSession,
      isFirstCapture: isFirstCapture,
      hasMomentumTarget: hasMomentumTarget,
      currentOwnedByMe: currentOwnedByMe,
      direction: direction,
      targetCopy: targetCopy,
      guidedTargetHex: guidedTargetHex,
    );
  }

  VoidCallback? _guidedCtaButtonCallback({
    required bool preSession,
    required bool isFirstCapture,
    required bool hasMomentumTarget,
    required bool currentOwnedByMe,
    required String? direction,
  }) {
    if (preSession) {
      return () async {
        await _startGuidedSessionFromCta();
      };
    }
    if (_currentTile.isEmpty) return null;
    return () async {
      final shouldMoveFirst = isFirstCapture || hasMomentumTarget;
      if (shouldMoveFirst) {
        final riding = _isRiding;
        final hint = _isFarFromCorridor
            ? (riding
                  ? 'Ride to ${LaunchCorridor.activeTrailName}'
                  : 'Head to ${LaunchCorridor.activeTrailName}')
            : direction == null
            ? (riding ? 'Ride to the glowing tile' : 'Move to the glowing tile')
            : (riding
                  ? 'Ride $direction to the glowing tile'
                  : 'Move $direction to the glowing tile');
        await HapticFeedback.selectionClick();
        _showCaptureFeedback(hint);
        return;
      }

      await HapticFeedback.selectionClick();
      _showCaptureFeedback(
        currentOwnedByMe
            ? (_isRiding
                  ? 'Session live — Captures happen as you ride'
                  : 'Session live - Auto-capture on movement')
            : (_isRiding
                  ? 'Tracking active — Keep riding'
                  : 'Tracking active - Keep moving'),
      );
    };
  }

  Widget _buildGuidedBottomPanel({required bool compactHud}) {
    final s = _guidedCtaState();
    final copy = _guidedCtaCopyForBottomPanel(
      preSession: s.preSession,
      isFirstCapture: s.isFirstCapture,
      hasMomentumTarget: s.hasMomentumTarget,
      currentOwnedByMe: s.currentOwnedByMe,
      direction: s.direction,
      targetCopy: s.targetCopy,
      guidedTargetHex: s.guidedTargetHex,
    );
    final callback = _guidedCtaButtonCallback(
      preSession: s.preSession,
      isFirstCapture: s.isFirstCapture,
      hasMomentumTarget: s.hasMomentumTarget,
      currentOwnedByMe: s.currentOwnedByMe,
      direction: s.direction,
    );

    return GuidedCtaPanel(
      stickyBar: false,
      compactHud: compactHud,
      emphasized: s.isFirstCapture || _capturePulseActive,
      copy: copy,
      aboveButton: s.preSession ? _buildActivityModeSelector() : null,
      onActionButton: callback,
    );
  }

  Widget _buildActivityModeSelector() {
    return SegmentedButton<ActivityMode>(
      segments: const [
        ButtonSegment(
          value: ActivityMode.walkRun,
          label: Text('Walk / Run'),
          icon: Icon(Icons.directions_walk, size: 16),
        ),
        ButtonSegment(
          value: ActivityMode.ride,
          label: Text('Ride'),
          icon: Icon(Icons.directions_bike, size: 16),
        ),
      ],
      selected: {_selectedActivityMode},
      onSelectionChanged: (selected) {
        setState(() => _selectedActivityMode = selected.first);
      },
      showSelectedIcon: false,
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return GameUiTokens.accentPrimary.withAlpha(40);
          }
          return Colors.transparent;
        }),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return GameUiTokens.accentPrimary;
          }
          return GameUiTokens.textMid;
        }),
        side: WidgetStateProperty.all(
          const BorderSide(color: GameUiTokens.panelBorder, width: 1),
        ),
        shape: WidgetStateProperty.all(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        textStyle: WidgetStateProperty.all(
          GameUiText.body(size: 12, weight: FontWeight.w700),
        ),
        padding: WidgetStateProperty.all(
          const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        ),
      ),
    );
  }

  Widget _buildGuidedStickyCtaBar({required bool compactHud}) {
    final s = _guidedCtaState();
    final copy = _guidedCtaCopyForStickyBar(
      preSession: s.preSession,
      isFirstCapture: s.isFirstCapture,
      hasMomentumTarget: s.hasMomentumTarget,
      currentOwnedByMe: s.currentOwnedByMe,
      direction: s.direction,
      targetCopy: s.targetCopy,
      guidedTargetHex: s.guidedTargetHex,
    );
    final callback = _guidedCtaButtonCallback(
      preSession: s.preSession,
      isFirstCapture: s.isFirstCapture,
      hasMomentumTarget: s.hasMomentumTarget,
      currentOwnedByMe: s.currentOwnedByMe,
      direction: s.direction,
    );

    return GuidedCtaPanel(
      stickyBar: true,
      compactHud: compactHud,
      emphasized: s.isFirstCapture || _capturePulseActive,
      copy: copy,
      onActionButton: callback,
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
    ref.read(gameStateProvider.notifier).updateSessionCounters(result);
  }

  void _updateCurrentObjective() {
    final objective = _objectiveEngine.evaluateObjective(
      sessionActive: _sessionActive,
      currentTile: _currentGameTile,
      capturedHexes: _captureService.capturedHexes,
      capturedHexesCount: _captureService.capturedHexes.length,
      protectedUntil: _currentGameTile.protectedUntil,
      trailProgress: _trailProgress,
      sectionProgress: _sectionProgress,
      streakDirectionHint: _streakDirectionHint(),
    );
    ref.read(gameStateProvider.notifier).setCurrentObjective(objective);
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

  Future<void> _showSessionSummaryDialog({
    ActivityMode mode = ActivityMode.walkRun,
  }) async {
    final now = DateTime.now();
    final startedAt = _sessionStartedAt;
    final elapsed = startedAt == null
        ? Duration.zero
        : now.difference(startedAt);
    final minutes = elapsed.inMinutes;
    final seconds = elapsed.inSeconds % 60;
    final distanceKm = _sessionDistanceMeters / 1000.0;
    final distanceMiles = _sessionDistanceMeters / 1609.344;
    final riding = mode == ActivityMode.ride;

    if (!mounted) return;

    final distanceText = distanceMiles >= 0.1
        ? '${distanceMiles.toStringAsFixed(2)} mi'
        : '${(_sessionDistanceMeters * 3.28084).toStringAsFixed(0)} ft';
    // Estimate steps from distance (~1,312 steps / km average stride).
    final estimatedSteps = (distanceKm * 1312).round();
    final title = riding ? 'RIDE COMPLETE' : 'SESSION COMPLETE';
    final subtitle = riding
        ? '$distanceText route · $_sessionTilesCaptured hexes painted'
        : '$_sessionTilesCaptured hexes captured · $distanceText covered';
    final timeText = '${minutes}m ${seconds}s';

    // Snapshot trail-section progress for the primary trail.
    final primaryTrail = _trailProgress.isNotEmpty
        ? (_trailProgress.toList()
                ..sort((a, b) => b.ownedTiles.compareTo(a.ownedTiles)))
              .first
        : null;
    final trailSections = primaryTrail != null
        ? _sectionProgress
              .where((s) => s.section.trailId == primaryTrail.trail.id)
              .toList()
        : <TrailSectionProgress>[];

    // Build stat rows – mode-aware ordering with hero promotion.
    final stats = riding
        ? <_SummaryStat>[
            _SummaryStat(
              Icons.straighten,
              'Distance',
              distanceText,
              hero: true,
            ),
            _SummaryStat(
              Icons.grid_view_rounded,
              'Hexes captured',
              '$_sessionTilesCaptured',
            ),
            _SummaryStat(Icons.timer_outlined, 'Time', timeText),
            if (_sessionTakeovers > 0)
              _SummaryStat(Icons.swap_horiz, 'Takeovers', '$_sessionTakeovers'),
            if (_sessionTilesRefreshed > 0)
              _SummaryStat(
                Icons.refresh,
                'Refreshed',
                '$_sessionTilesRefreshed',
              ),
            if (_sessionRivalBlocked > 0)
              _SummaryStat(
                Icons.block,
                'Rival blocked',
                '$_sessionRivalBlocked',
              ),
            if (_sessionMilestones.isNotEmpty)
              _SummaryStat(
                Icons.emoji_events,
                'Milestones',
                '${_sessionMilestones.length}',
              ),
          ]
        : <_SummaryStat>[
            _SummaryStat(
              Icons.grid_view_rounded,
              'Hexes captured',
              '$_sessionTilesCaptured',
              hero: true,
            ),
            if (_sessionTakeovers > 0)
              _SummaryStat(Icons.swap_horiz, 'Takeovers', '$_sessionTakeovers'),
            if (_sessionTilesRefreshed > 0)
              _SummaryStat(
                Icons.refresh,
                'Protection refreshed',
                '$_sessionTilesRefreshed',
              ),
            if (_sessionRivalBlocked > 0)
              _SummaryStat(
                Icons.block,
                'Rival blocked',
                '$_sessionRivalBlocked',
              ),
            _SummaryStat(Icons.straighten, 'Distance', distanceText),
            _SummaryStat.emoji('👟', 'Est. steps', '$estimatedSteps'),
            _SummaryStat(Icons.timer_outlined, 'Time', timeText),
            if (_sessionMilestones.isNotEmpty)
              _SummaryStat(
                Icons.emoji_events,
                'Milestones',
                '${_sessionMilestones.length}',
              ),
          ];

    await showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) {
        return _AnimatedSessionSummary(
          riding: riding,
          title: title,
          subtitle: subtitle,
          distanceText: distanceText,
          timeText: timeText,
          tilesCaptured: _sessionTilesCaptured,
          stats: stats,
          onShare: () {
            // Delta framing: prefix "+" on capture/takeover counts.
            const deltaLabels = {
              'Hexes captured',
              'Takeovers',
              'Protection refreshed',
              'Refreshed',
              'Rival blocked',
            };
            // Trail waypoints for mini-map.
            List<Offset>? trailWaypoints;
            if (primaryTrail?.trail.id == 'burke_gilman') {
              trailWaypoints = SeattleTrailDefinitions.burkeGilmanWaypoints
                  .map((p) => Offset(p.lng, p.lat))
                  .toList();
            }
            // Player identifier.
            final uid = _captureService.currentUserId;
            final playerName = uid != null
                ? 'Player ${uid.substring(0, 6).toUpperCase()}'
                : null;
            shareSessionCard(
              context,
              SessionShareData(
                riding: riding,
                title: title,
                subtitle: subtitle,
                tilesCaptured: _sessionTilesCaptured,
                distanceText: distanceText,
                timeText: timeText,
                takeovers: _sessionTakeovers,
                trailName: primaryTrail != null ? '${primaryTrail.trail.name} Trail' : null,
                trailPercent: primaryTrail?.completionPercent,
                leaderboardRank: _leaderboardRank,
                totalPlayers: _leaderboardTotalPlayers,
                playerName: playerName,
                hexStreak: primaryTrail?.longestOwnedSegmentTiles,
                trailWaypoints: trailWaypoints,
                sessionDate: DateTime.now(),
                stats: stats.map((s) {
                  final isDelta = deltaLabels.contains(s.label);
                  final v = isDelta ? '+${s.value}' : s.value;
                  return s.emoji != null
                      ? ShareStat.emoji(s.emoji!, s.label, v, hero: s.hero)
                      : ShareStat(s.icon, s.label, v, hero: s.hero);
                }).toList(),
              ),
            );
          },
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
      includePreviewEnemyTiles: ref
          .read(gameStateProvider)
          .showPreviewEnemyTiles,
      trailOnlyRendering: !_isFarFromCorridor,
      corridorHexes: LaunchCorridor.hexes.toList(),
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

    if (!result.synced) {
      debugPrint('[ManualCapture] ⚠️ didCapture but NOT synced for $cellHex');
      _logCaptureEvent(result, cellHex, auto: false);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Capture failed to sync — try again')));
      _updateCurrentObjective();
      return;
    }

    // Immediately redraw the just-captured hex green without waiting
    // for the next periodic refresh cycle.
    final capturedTile = _captureService.getTileByHex(cellHex);
    if (capturedTile != null) {
      unawaited(_mapRenderService.forceRedrawHex(capturedTile));
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
        'Takeover captured ✅',
      CaptureAttemptStatus.protectionRefreshed =>
        'Protection refreshed ✅',
      _ =>
        'Tile captured ✅',
    };

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(successMessage)));
  }

  Future<void> _toggleSession() async {
    if (_sessionActive) {
      // Snapshot counters for log/summary before stopping.
      final gs = ref.read(gameStateProvider);
      final captured = gs.sessionTilesCaptured;
      final refreshed = gs.sessionTilesRefreshed;
      final blocked = gs.sessionRivalBlocked;
      final takeovers = gs.sessionTakeovers;
      final distance = gs.sessionDistanceMeters;
      final mode = gs.sessionActivityMode;

      ref.read(gameStateProvider.notifier).stopSession();
      _selectedActivityMode = ActivityMode.walkRun;
      _pendingAutoCaptureHex = null;
      _enteredPendingTileAt = null;
      _stopLeaderboardRefreshTimer();
      setState(() {});

      await _saveSessionState();
      _eventLog.log(
        MapEventType.sessionStopped,
        'Session stopped',
        metadata: {
          'captured': captured,
          'refreshed': refreshed,
          'blocked': blocked,
          'takeovers': takeovers,
          'distanceMeters': distance,
        },
      );

      await _showSessionSummaryDialog(mode: mode);
      _updateCurrentObjective();
      await _clearRecommendedTileGlow();
      return;
    }

    // Start session via provider (single source of truth).
    ref
        .read(gameStateProvider.notifier)
        .startSession(
          lastLat: _lastLat,
          lastLng: _lastLng,
          activityMode: _selectedActivityMode,
        );

    // Reset auto-capture local state.
    _lastSessionCaptureAttemptHex = null;
    _lastAutoCaptureAttemptAt = null;
    _recentAutoCaptureByHex.clear();
    _pendingAutoCaptureHex = null;
    _enteredPendingTileAt = null;

    setState(() {});

    await _saveSessionState();
    await _unlockMilestones([
      (id: 'first_session_start', title: '🎬 First session started'),
    ]);
    _eventLog.log(MapEventType.sessionStarted, 'Session started');
    _startLeaderboardRefreshTimer();
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
    switch (ref.read(gameStateProvider).hudPreference) {
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

  Future<void> _setHudPreference(HudPreference preference) async {
    if (ref.read(gameStateProvider).hudPreference == preference) return;
    ref.read(gameStateProvider.notifier).setHudPreference(preference);
    await _saveSessionState();
    await _syncRecommendedTileGlow();
  }

  Future<void> _setShowPreviewEnemyTiles(bool value) async {
    if (ref.read(gameStateProvider).showPreviewEnemyTiles == value) return;
    ref.read(gameStateProvider.notifier).setShowPreviewEnemyTiles(value);
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
        // MVP: Guided is the visible primary mode.
        // Auto/Pro remain accessible via the "More actions" overflow menu.
        const CheckedPopupMenuItem(
          value: HudPreference.guided,
          checked: true,
          child: Text('Guided HUD'),
        ),
        if (_sessionActive) ...[
          const PopupMenuDivider(),
          PopupMenuItem<HudPreference>(
            onTap: () {
              unawaited(_toggleSession());
            },
            child: const Text('End Session'),
          ),
        ],
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
    final direction = guidedTargetHex == null
        ? null
        : _directionToHex(guidedTargetHex);
    final objective = ref.read(gameStateProvider).currentObjective;
    final onRecommendedTile =
        guidedTargetHex != null &&
        _currentTile.isNotEmpty &&
        guidedTargetHex == _currentTile.toLowerCase();

    GuidedTopHudCopy? normalCopy;
    if (_sessionActive &&
        !_isGuidedFirstCaptureMode &&
        !_showPostCaptureGuidance) {
      normalCopy = GuidedTopHudCopy(
        title: (!onRecommendedTile && guidedTargetHex != null)
            ? targetCopy!.title
            : objective.title,
        detail: (!onRecommendedTile && guidedTargetHex != null)
            ? targetCopy!.detail
            : objective.detail,
      );
    }

    return GuidedTopHud(
      compactHud: compactHud,
      sessionActive: _sessionActive,
      isFirstCaptureMode: _isGuidedFirstCaptureMode,
      showPostCaptureGuidance: _showPostCaptureGuidance,
      capturePulseActive: _capturePulseActive,
      hasSectionPressure: _sectionProgress.any(
        (s) => s.controlState == SectionControlState.contested,
      ),
      direction: direction,
      hasGlowTarget: guidedTargetHex != null,
      corridorName: (_showLaunchBanner || _isFarFromCorridor)
          ? LaunchCorridor.activeTrailName
          : null,
      corridorDistance:
          (_showLaunchBanner || _isFarFromCorridor) &&
              _corridorEntryDistanceMeters > 0
          ? _formatDistanceMiles(_corridorEntryDistanceMeters)
          : null,
      modeMenuButton: _buildGuidedModeMenuButton(),
      activityMode: ref.read(gameStateProvider).sessionActivityMode,
      onEndSession: _sessionActive ? () => _toggleSession() : null,
      onLeaderboard: _showLeaderboard,
      leaderboardRank: _leaderboardRank,
      leaderboardTiles: _leaderboardTiles,
      mineCount: _captureService.capturedHexes.length,
      normalCopy: normalCopy,
      sessionElapsedText: _sessionElapsedText(),
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

  Widget _buildLaunchCorridorBanner() {
    return GestureDetector(
      onTap: () {
        if (!mounted) return;
        setState(() {
          _showLaunchBanner = false;
          // launchEntryMode is driven by _isFarFromCorridor in the refresh
          // loop — do not force it off on banner tap.
        });
      },
      child: FrostedOverlayCard(
        emphasized: true,
        borderRadius: const BorderRadius.all(Radius.circular(14)),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '🗺️ ${LaunchCorridor.activeTrailName} is live',
              style: GameUiText.body(
                color: GameUiTokens.accentPrimary,
                size: 13,
                weight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              'More Seattle trails opening soon',
              style: GameUiText.meta(color: GameUiTokens.textLow, size: 11),
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
                            _setShowPreviewEnemyTiles(
                              !ref
                                  .read(gameStateProvider)
                                  .showPreviewEnemyTiles,
                            ),
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
                        checked:
                            ref.read(gameStateProvider).hudPreference ==
                            HudPreference.auto,
                        child: const Text('Auto HUD'),
                      ),
                      CheckedPopupMenuItem(
                        value: 'guided',
                        checked:
                            ref.read(gameStateProvider).hudPreference ==
                            HudPreference.guided,
                        child: const Text('Guided HUD'),
                      ),
                      CheckedPopupMenuItem(
                        value: 'pro',
                        checked:
                            ref.read(gameStateProvider).hudPreference ==
                            HudPreference.pro,
                        child: const Text('Pro HUD'),
                      ),
                      const PopupMenuDivider(),
                      CheckedPopupMenuItem(
                        value: 'preview_enemy_tiles',
                        checked: ref
                            .read(gameStateProvider)
                            .showPreviewEnemyTiles,
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
                  HudPill(
                    label: 'Tracking',
                    value: _tracking ? 'On' : 'Off',
                    color: _tracking ? GameColors.statusTracking : Colors.grey,
                  ),
                  HudPill(
                    label: 'Session',
                    value: _sessionActive ? 'Active' : 'Paused',
                    color: _sessionActive
                        ? GameColors.statusSessionOn
                        : Colors.grey,
                  ),
                  HudPill(label: 'Captured', value: '$mineCount'),
                  if (!compactHud)
                    HudPill(label: 'Nearby', value: '$visibleCount'),
                  HudPill(
                    label: 'Achievements',
                    value:
                        '${_unlockedMilestoneIds.length}/$_totalMilestoneCount',
                    color: Colors.amberAccent,
                  ),
                  if (!compactHud)
                    HudPill(label: 'Time', value: _sessionElapsedText()),
                  HudPill(
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

    // Subscribe to provider so notifier-only mutations trigger rebuilds.
    final gs = ref.watch(gameStateProvider);

    final compactHud = _compactHud;
    final topInset = MediaQuery.paddingOf(context).top;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
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

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: Scaffold(
        body: Stack(
        children: [
          mb.MapWidget(
            key: const ValueKey('mapWidget'),
            styleUri: kMapboxDarkStyleUri,
            onTapListener: _onMapTap,
            cameraOptions: mb.CameraOptions(
              center: mb.Point(coordinates: mb.Position(-122.3321, 47.6062)),
              zoom: 11.5,
              pitch: 45,
            ),
            onMapCreated: (mapboxMap) async {
              _map = mapboxMap;
              await _mapRenderService.attachMap(mapboxMap);

              // Enable the native location puck so the user's live position
              // is visible on the map as a blue dot.
              await mapboxMap.location.updateSettings(
                mb.LocationComponentSettings(
                  enabled: true,
                  pulsingEnabled: true,
                  puckBearingEnabled: true,
                  puckBearing: mb.PuckBearing.HEADING,
                ),
              );

              // Defer provider-mutating work so it does not run while the
              // widget tree is still building (Riverpod guard).
              WidgetsBinding.instance.addPostFrameCallback((_) async {
                if (!mounted) return;

                // Draw corridor lane as soon as map is ready.
                unawaited(_drawCorridorLaneIfNeeded());

                if (_lastLat != null && _lastLng != null) {
                  await _refreshMapForCoordinates(
                    _lastLat!,
                    _lastLng!,
                    moveCamera: false,
                    accuracy: _lastAccuracy,
                  );
                }

                await _syncRecommendedTileGlow(
                  currentLat: _lastLat,
                  currentLng: _lastLng,
                );
              });
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
              bottom:
                  bottomInset +
                  (guidedMode
                      ? (compactHud ? 84 : 98)
                      : (compactHud ? 90 : 110)),
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
          if (gs.selectedTile != null)
            Positioned(
              left: 16,
              right: 16,
              bottom:
                  bottomInset +
                  (guidedMode
                      ? (useGuidedStickyBar ? 100 : 174)
                      : 188),
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 180),
                opacity: _bottomHudVisible ? 1 : 0,
                child: firstCaptureGuidedMode
                    ? const SizedBox.shrink()
                    : SelectedTileInfoCard(
                        tile: gs.selectedTile!,
                        guidedMode: guidedMode,
                        compactHud: compactHud,
                        h3Resolution: h3Resolution,
                        onDismiss: _dismissSelection,
                      ),
              ),
            ),
          // Launch corridor banner (one-trail-first state)
          // Suppressed while a tile is selected so the tile card has priority.
          if (_showLaunchBanner && guidedMode && gs.selectedTile == null)
            Positioned(
              left: 16,
              right: 16,
              bottom: bottomInset + (compactHud ? 180 : 210),
              child: _buildLaunchCorridorBanner(),
            ),
          Positioned(
            left: 16,
            right: 16,
            bottom: bottomInset + 16,
            child: AnimatedSlide(
              duration: bottomSlideDuration,
              curve: Curves.easeOutCubic,
              offset: _bottomHudVisible ? Offset.zero : const Offset(0, 0.2),
              child: AnimatedOpacity(
                duration: bottomFadeDuration,
                opacity: _bottomHudVisible ? 1 : 0,
                child: AnimatedScale(
                  duration: bottomScaleDuration,
                  scale: _capturePulseActive ? 1.012 : 1,
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
                  child: CaptureFeedbackOverlay(
                    text: _captureFeedbackText!,
                    success: _captureFeedbackSuccess,
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
    );
  }
}
