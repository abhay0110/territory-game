import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mb;
import 'package:h3_flutter/h3_flutter.dart' as h3;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/constants/game_colors.dart';
import '../../../core/constants/game_rules.dart';
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
import '../widgets/frosted_overlay_card.dart';
import '../widgets/leaderboard_dialog.dart';
import '../widgets/map_legend.dart';
import '../widgets/section_progress_dialog.dart';
import '../widgets/tile_details_dialog.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  mb.MapboxMap? _map;

  final h3.H3 _h3 = const h3.H3Factory().load();
  h3.H3Index? _currentCell;

  String _currentTile = 'unknown';
  bool _captured = false;
  GameTile _currentGameTile = const GameTile(
    h3Index: 'unknown',
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
  static const Duration _autoCaptureDebounce = Duration(seconds: 4);
  static const Duration _autoCaptureTileCooldown = Duration(seconds: 12);
  static const Duration _autoCaptureDwellTime = Duration(seconds: 5);
  static const String _prefsSessionActive = 'session_active_v1';
  static const String _prefsSessionLastHex = 'session_last_hex_v1';
  static const String _prefsSessionStartedAt = 'session_started_at_v1';
  static const String _prefsUnlockedMilestones = 'unlocked_milestones_v1';

  late final CaptureService _captureService;
  late final MapRenderService _mapRenderService;
  late final MapController _mapController;
  late final TrailProgressService _trailProgressService;
  late final TrailSectionProgressService _trailSectionProgressService;
  final MapEventLogService _eventLog = MapEventLogService();
  List<TrailProgress> _trailProgress = const [];
  List<TrailSectionProgress> _sectionProgress = const [];
  final Set<String> _unlockedMilestoneIds = <String>{};
  final List<String> _sessionMilestones = <String>[];
  bool _capturePulseActive = false;
  Timer? _capturePulseTimer;

  Timer? _nearbyRefreshTimer;

  int _simStep = 0;
  double? _simBaseLat;
  double? _simBaseLng;

  @override
  void initState() {
    super.initState();
    mb.MapboxOptions.setAccessToken(kMapboxAccessToken);

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
    _loadSessionState();
    _loadMilestoneState();
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _nearbyRefreshTimer?.cancel();
    _capturePulseTimer?.cancel();
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

  Future<void> _initializeMapController() async {
    final result = await _mapController.initialize();
    if (mounted) setState(() {});

    if (!result.synced && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Supabase not ready (offline mode): ${result.error}')),
      );
    }
  }

  Future<void> _loadSessionState() async {
    final prefs = await SharedPreferences.getInstance();
    final active = prefs.getBool(_prefsSessionActive) ?? false;
    final lastHex = prefs.getString(_prefsSessionLastHex);
    final startedAtRaw = prefs.getString(_prefsSessionStartedAt);

    if (!mounted) return;
    setState(() {
      _sessionActive = active;
      _lastSessionCaptureAttemptHex = lastHex;
      _sessionStartedAt =
          startedAtRaw == null ? null : DateTime.tryParse(startedAtRaw);
    });

    if (_sessionActive) {
      _eventLog.log(
        MapEventType.sessionStarted,
        'Session restored after app resume/reopen',
        metadata: {'lastHex': _lastSessionCaptureAttemptHex},
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Session restored ▶️')),
      );
    }
  }

  Future<void> _saveSessionState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsSessionActive, _sessionActive);
    if (_lastSessionCaptureAttemptHex == null) {
      await prefs.remove(_prefsSessionLastHex);
    } else {
      await prefs.setString(_prefsSessionLastHex, _lastSessionCaptureAttemptHex!);
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
    );
    _applyRefreshResult(
      result,
      currentLat: lat,
      currentLng: lng,
    );

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

    _nearbyRefreshTimer ??= _mapController.startPeriodicRefresh(onRefresh: () async {
      final lat = _lastLat;
      final lng = _lastLng;
      if (lat == null || lng == null) return;
      await _refreshMapForCoordinates(lat, lng, moveCamera: false);
    });
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
    if (enteredAt == null || now.difference(enteredAt) < _autoCaptureDwellTime) {
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

      _updateSessionSummaryCounters(result);

      final message = switch (result.status) {
        CaptureAttemptStatus.takeoverCaptured => result.synced
            ? 'Auto-capture takeover ✅ (synced)'
            : 'Auto-capture takeover ✅ (saved locally)',
        CaptureAttemptStatus.protectionRefreshed => result.synced
            ? 'Auto-capture refreshed protection ✅ (synced)'
            : 'Auto-capture refreshed protection ✅ (saved locally)',
        _ => result.synced
            ? 'Auto-capture success ✅ (synced)'
            : 'Auto-capture success ✅ (saved locally)',
      };

      _logCaptureEvent(result, currentHex, auto: true);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      return;
    }

    if (result.status == CaptureAttemptStatus.protectedByRival) {
      _updateSessionSummaryCounters(result);
      _logCaptureEvent(result, currentHex, auto: true);

      final protectedHint = result.protectedUntil == null
          ? 'Auto-capture blocked: rival protection active'
          : 'Auto-capture blocked: protected for ${_formatDuration(result.protectedUntil!.difference(DateTime.now()))}';

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(protectedHint),
        ),
      );
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
      _currentTile = 'H3-$h3Resolution:${result.currentHex}';
      _captured = result.isCaptured;
      _currentGameTile = result.currentTile;
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

    unawaited(_evaluateMilestones());
  }

  Future<void> _evaluateMilestones() async {
    final burke = _trailProgress.where((p) => p.trail.id == 'burke_gilman').toList();
    final burkeProgress = burke.isEmpty ? null : burke.first;

    final checks = <({String id, String title, bool unlockedNow})>[
      (
        id: 'first_tile',
        title: '🏁 First trail tile captured',
        unlockedNow: _captureService.capturedHexes.isNotEmpty,
      ),
      (
        id: 'streak_5',
        title: '🔥 5-tile streak reached',
        unlockedNow: _trailProgress.any((p) => p.longestOwnedSegmentTiles >= 5),
      ),
      (
        id: 'streak_10',
        title: '⚡ 10-tile streak reached',
        unlockedNow: _trailProgress.any((p) => p.longestOwnedSegmentTiles >= 10),
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
    ];

    final newlyUnlocked = <String>[];
    for (final check in checks) {
      if (check.unlockedNow && !_unlockedMilestoneIds.contains(check.id)) {
        _unlockedMilestoneIds.add(check.id);
        newlyUnlocked.add(check.title);
      }
    }

    if (newlyUnlocked.isEmpty) return;

    await _saveMilestoneState();

    if (mounted) {
      setState(() {
        _sessionMilestones.addAll(newlyUnlocked);
      });
    }

    for (final title in newlyUnlocked) {
      _eventLog.log(
        MapEventType.milestoneUnlocked,
        'Milestone unlocked',
        metadata: {'milestone': title},
      );

      if (!mounted) continue;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Milestone unlocked: $title')),
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));
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
    if (!mounted || _currentTile == 'unknown') return;

    await showTileDetailsDialog(
      context,
      ownerLabel: _ownerLabel(_currentGameTile),
      capturedSince: _formatSince(_currentGameTile.capturedAt),
      protectionLabel: _protectionLabel(_currentGameTile),
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
      final captureLike = e.type == MapEventType.tileCaptured ||
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
    if (ownerId == '__local_player__' || ownerId == _captureService.currentUserId) {
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

    final candidates = _sectionProgress
        .where((s) => !s.isComplete && s.bestNextTileH3 != null)
        .toList()
      ..sort((a, b) => (a.bestNextTileDistanceMeters ?? double.infinity)
          .compareTo(b.bestNextTileDistanceMeters ?? double.infinity));

    if (candidates.isEmpty) return 'Section objective: complete';
    final next = candidates.first;
    final dist = next.bestNextTileDistanceMeters == null
        ? '--'
        : _formatDistanceMeters(next.bestNextTileDistanceMeters!);

    return 'Section objective: ${next.section.name} • $dist • +${next.projectedGainTiles} streak';
  }

  String _sectionControlPressureText() {
    if (_sectionProgress.isEmpty) return 'Section control: --';

    final contested = _sectionProgress.where((s) => s.controlState == SectionControlState.contested).toList();
    if (contested.isNotEmpty) {
      contested.sort((a, b) => a.section.name.compareTo(b.section.name));
      return '${contested.first.section.name}: Contested section • Next capture flips section';
    }

    final takeControl = _sectionProgress.where((s) => s.tilesToTakeControl > 0).toList()
      ..sort((a, b) => a.tilesToTakeControl.compareTo(b.tilesToTakeControl));
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

    final flippable = _sectionProgress.where((s) => s.canFlipWithNextCapture).toList();
    if (flippable.isNotEmpty) {
      flippable.sort((a, b) => a.section.name.compareTo(b.section.name));
      return '${flippable.first.section.name}: Next capture flips section';
    }

    return 'Section control stable';
  }

  Future<void> _showSectionProgress() async {
    if (!mounted) return;
    await showSectionProgressDialog(
      context,
      sections: _sectionProgress,
    );
  }

  String _formatDistanceMeters(double meters) {
    if (meters < 1000) return '${meters.toStringAsFixed(0)}m';
    return '${(meters / 1000).toStringAsFixed(2)}km';
  }

  String _nearestTrailHintText() {
    String reasonLabel(TrailNextTileReason? reason) {
      return switch (reason) {
        TrailNextTileReason.extendStreak => 'Extends streak',
        TrailNextTileReason.bridgeGap => 'Bridges gap',
        TrailNextTileReason.startTrail => 'Starts trail',
        TrailNextTileReason.nearestMissing => 'Nearest missing fallback',
        null => 'No objective',
      };
    }

    if (_trailProgress.isEmpty) return 'Next objective: --';

    final objectiveCandidates = _trailProgress
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
      return 'Next objective: ${next.trail.name} • $dist (${reasonLabel(next.bestNextTileReason)})';
    }

    final fallbackCandidates = _trailProgress
        .where(
          (p) => !p.isComplete && p.nearestMissingTileDistanceMeters != null,
        )
        .toList()
      ..sort(
        (a, b) => a.nearestMissingTileDistanceMeters!
            .compareTo(b.nearestMissingTileDistanceMeters!),
      );

    if (fallbackCandidates.isNotEmpty) {
      final next = fallbackCandidates.first;
      return 'Next objective: ${next.trail.name} • ${_formatDistanceMeters(next.nearestMissingTileDistanceMeters!)} (Nearest missing)';
    }

    final hasIncomplete = _trailProgress.any((p) => !p.isComplete);
    if (hasIncomplete) {
      return 'Next objective: move closer to a tracked trail';
    }

    return 'All tracked trails complete 🎉';
  }

  String _nextObjectiveDetailText() {
    String reasonLabel(TrailNextTileReason? reason) {
      return switch (reason) {
        TrailNextTileReason.extendStreak => 'Extends streak',
        TrailNextTileReason.bridgeGap => 'Bridges gap',
        TrailNextTileReason.startTrail => 'Starts trail',
        TrailNextTileReason.nearestMissing => 'Nearest missing',
        null => 'No objective',
      };
    }

    final objectiveCandidates = _trailProgress
        .where((p) => !p.isComplete && p.bestNextTileH3 != null)
        .toList()
      ..sort(
        (a, b) => (a.bestNextTileDistanceMeters ?? double.infinity)
            .compareTo(b.bestNextTileDistanceMeters ?? double.infinity),
      );

    if (objectiveCandidates.isEmpty) return 'Objective detail: --';
    final next = objectiveCandidates.first;

    if (next.projectedGainTiles > 0) {
      return '${reasonLabel(next.bestNextTileReason)} • streak becomes ${next.projectedOwnedSegmentTiles} (+${next.projectedGainTiles})';
    }

    return '${reasonLabel(next.bestNextTileReason)} • streak stays ${next.projectedOwnedSegmentTiles}';
  }

  Future<void> _cycleVisibleRadius() async {
    const options = <double>[500, 600, 700];
    final currentIndex = options.indexOf(_visibleRadiusMeters);
    final nextIndex = currentIndex == -1 ? 1 : (currentIndex + 1) % options.length;

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

  void _logCaptureEvent(
    CaptureAttemptResult result,
    String hex,
    {
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
          metadata: {'hex': hex, 'protectedUntil': result.protectedUntil?.toIso8601String()},
        );
      case CaptureAttemptStatus.protectedByRival:
        _eventLog.log(
          MapEventType.blockedByRivalProtection,
          '$mode capture blocked by rival protection',
          metadata: {'hex': hex, 'protectedUntil': result.protectedUntil?.toIso8601String()},
        );
      case CaptureAttemptStatus.lowAccuracy:
      case CaptureAttemptStatus.tooFarFromCenter:
        break;
    }
  }

  Future<void> _showSessionSummaryDialog() async {
    final now = DateTime.now();
    final startedAt = _sessionStartedAt;
    final elapsed = startedAt == null ? Duration.zero : now.difference(startedAt);
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Location stream error: $e')),
        );
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

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
      return;
    }

    final refresh = flowResult.refresh;
    if (refresh != null) {
      _applyRefreshResult(
        refresh,
        currentLat: _lastLat,
        currentLng: _lastLng,
      );
    }

    _triggerCapturePulse();

    _updateSessionSummaryCounters(result);
    _logCaptureEvent(result, cellHex, auto: false);

    if (!mounted) return;
    final successMessage = switch (result.status) {
      CaptureAttemptStatus.takeoverCaptured => result.synced
          ? 'Takeover captured ✅ (synced)'
          : 'Takeover captured ✅ (saved locally)',
      CaptureAttemptStatus.protectionRefreshed => result.synced
          ? 'Protection refreshed ✅ (synced)'
          : 'Protection refreshed ✅ (saved locally)',
      CaptureAttemptStatus.captured => result.synced
          ? 'Tile captured ✅ (synced)'
          : 'Tile captured ✅ (saved locally)',
      _ => result.synced
          ? 'Tile captured ✅ (synced)'
          : 'Tile captured ✅ (saved locally)',
    };

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(successMessage),
      ),
    );
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
      return;
    }

    setState(() {
      _sessionActive = true;
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
    _eventLog.log(MapEventType.sessionStarted, 'Session started');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Session started ▶️')),
    );
  }

  Color _ownershipBadgeColor(GameTile tile) {
    final now = DateTime.now();
    final isProtected =
        tile.protectedUntil != null && tile.protectedUntil!.isAfter(now);

    return switch (tile.ownership) {
      TileOwnership.mine => isProtected
          ? GameColors.neonGreen
          : GameColors.myTileGreen,
      TileOwnership.enemy => isProtected
          ? GameColors.rivalRed
          : GameColors.rivalRedDark,
      TileOwnership.neutral => GameColors.neutralGray,
    };
  }

  String _captureStatusText() {
    if (_lastAccuracy == null) return 'Accuracy: --';
    return 'Accuracy: ${_lastAccuracy!.toStringAsFixed(0)}m';
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

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 8,
        toolbarHeight: 64,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'HEXTRAIL',
              style: TextStyle(
                color: GameColors.neonGreen,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.1,
              ),
            ),
            Text(
              _sessionActive ? 'Seattle • Session: Active' : 'Capture the city',
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            onPressed: _centerOnMeOnce,
            icon: const Icon(Icons.place),
            tooltip: 'Center once',
          ),
          IconButton(
            onPressed: _toggleTracking,
            icon: Icon(_tracking ? Icons.explore : Icons.explore_outlined),
            tooltip: _tracking ? 'Stop tracking' : 'Start tracking',
          ),
          IconButton(
            onPressed: () => setState(() => _followMe = !_followMe),
            icon: Icon(_followMe ? Icons.navigation : Icons.navigation_outlined),
            tooltip: _followMe ? 'Follow: ON' : 'Follow: OFF',
          ),
          IconButton(
            onPressed: _toggleSession,
            icon: Icon(_sessionActive ? Icons.stop_circle : Icons.play_circle_fill),
            tooltip: _sessionActive ? 'Stop session' : 'Start session',
          ),
          IconButton(
            onPressed: _cycleVisibleRadius,
            icon: const Icon(Icons.alt_route),
            tooltip: 'Visible radius: ${_visibleRadiusMeters.toInt()}m',
          ),
          IconButton(
            onPressed: _showLeaderboard,
            icon: const Icon(Icons.military_tech),
            tooltip: 'Local leaderboard',
          ),
          IconButton(
            onPressed: _showSectionProgress,
            icon: const Icon(Icons.route),
            tooltip: 'Trail sections',
          ),
          IconButton(
            onPressed: _simulateMove,
            icon: const Icon(Icons.directions_run),
            tooltip: 'Simulate walk path',
          ),
          IconButton(
            onPressed: _testMovementAcrossTiles,
            icon: const Icon(Icons.route),
            tooltip: 'Test movement across tiles',
          ),
        ],
      ),
      body: Stack(
        children: [
          mb.MapWidget(
            key: const ValueKey('mapWidget'),
            styleUri: kMapboxDarkStyleUri,
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
          Positioned(
            left: 12,
            top: 12,
            child: const MapLegend(),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: FrostedOverlayCard(
              child: DefaultTextStyle.merge(
                style: const TextStyle(color: Colors.white70),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  const Text(
                                    'Current tile',
                                    style: TextStyle(fontWeight: FontWeight.w600),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    _tracking ? 'TRACKING' : 'IDLE',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: _tracking ? GameColors.statusTracking : Colors.grey,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    _sessionActive ? 'SESSION ON' : 'SESSION OFF',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: _sessionActive ? GameColors.statusSessionOn : Colors.grey,
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
                                  const SizedBox(width: 10),
                                  Text(
                                    'Visible: ${_mapRenderService.visibleCapturedHex.length}',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    '🏆 ${_unlockedMilestoneIds.length}/5',
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
                                    duration: const Duration(milliseconds: 220),
                                    scale: _capturePulseActive ? 1.7 : 1.0,
                                    child: AnimatedOpacity(
                                      duration: const Duration(milliseconds: 220),
                                      opacity: _capturePulseActive ? 0.9 : 1,
                                      child: Container(
                                        width: 10,
                                        height: 10,
                                        decoration: BoxDecoration(
                                          color: _ownershipBadgeColor(_currentGameTile),
                                          shape: BoxShape.circle,
                                          boxShadow: _capturePulseActive
                                              ? [
                                                  BoxShadow(
                                                    color: _ownershipBadgeColor(_currentGameTile)
                                                        .withOpacity(0.85),
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
                                      style: const TextStyle(fontSize: 12, color: Colors.white),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _protectionLabel(_currentGameTile),
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${_captureStatusText()} • Radius ${_visibleRadiusMeters.toInt()}m',
                                style: const TextStyle(fontSize: 12),
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
                          ),
                        ),
                        IconButton(
                          onPressed: _showCurrentTileDetails,
                          color: Colors.white,
                          icon: const Icon(Icons.assistant_navigation),
                          tooltip: 'Tile details',
                        ),
                        const SizedBox(width: 12),
                        AnimatedScale(
                          duration: const Duration(milliseconds: 220),
                          scale: _capturePulseActive ? 1.06 : 1.0,
                          child: FilledButton(
                            onPressed: _currentTile == 'unknown' ? null : _captureCurrentTile,
                            style: FilledButton.styleFrom(
                              backgroundColor: GameColors.neonGreen,
                              foregroundColor: Colors.black,
                            ),
                            child: Text(_captured ? 'Captured' : 'Capture'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}