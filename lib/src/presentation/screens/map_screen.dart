import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mb;
import 'package:h3_flutter/h3_flutter.dart' as h3;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../config/mapbox.dart';
import '../../data/services/capture_service.dart';
import '../../data/services/location_service.dart';
import '../../data/services/map_render_service.dart';

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

  StreamSubscription<geo.Position>? _posSub;
  bool _tracking = false;
  bool _followMe = true;

  double? _lastLat;
  double? _lastLng;
  double? _lastAccuracy;

  static const int h3Resolution = 9;
  static const double renderRadiusMeters = 1500;
  static const double maxAllowedAccuracyMeters = 30;
  static const double maxCaptureDistanceMeters = 80;

  late final CaptureService _captureService;
  late final MapRenderService _mapRenderService;
  final LocationService _locationService = LocationService();

  Timer? _nearbyRefreshTimer;

  int _simStep = 0;
  double? _simBaseLat;
  double? _simBaseLng;

  final SupabaseClient _sb = Supabase.instance.client;
  bool _supabaseReady = false;

  @override
  void initState() {
    super.initState();
    mb.MapboxOptions.setAccessToken(kMapboxAccessToken);

    _captureService = CaptureService(
      supabaseClient: _sb,
      h3Resolution: h3Resolution,
    );

    _mapRenderService = MapRenderService(
      h3Instance: _h3,
      h3Resolution: h3Resolution,
    );

    _loadCapturedFromPrefs();
    _initSupabase();
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _nearbyRefreshTimer?.cancel();
    _mapRenderService.dispose();
    super.dispose();
  }

  Future<void> _initSupabase() async {
    try {
      await _ensureSignedIn();

      final uid = _currentUserId();
      if (uid != null) {
        await _captureService.loadFromSupabase(uid);
      }

      _supabaseReady = true;
      if (mounted) setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Supabase not ready (offline mode): $e')),
      );
    }
  }

  Future<void> _ensureSignedIn() async {
    if (_sb.auth.currentUser != null) return;
    await _sb.auth.signInAnonymously();
  }

  String? _currentUserId() => _sb.auth.currentUser?.id;

  Future<void> _upsertCaptureToSupabase(String hexLower) async {
    final uid = _currentUserId();
    if (uid == null) return;

    await _captureService.upsertCapture(uid, hexLower);
  }

  Future<void> _upsertOwnershipToSupabase(String hexLower) async {
    final uid = _currentUserId();
    if (uid == null) return;

    await _captureService.upsertOwnership(uid, hexLower);
  }

  Future<void> _loadCapturedFromPrefs() async {
    await _captureService.loadFromPrefs();
    if (mounted) setState(() {});
  }

  Future<void> _saveCapturedToPrefs() async {
    await _captureService.saveToPrefs();
  }

  Future<void> _refreshNearbyFromSupabase() async {
    if (_currentCell == null) return;
    final uid = _currentUserId();
    if (uid == null) return;

    const ringSize = 7;
    final neighbors = _h3.gridDisk(_currentCell!, ringSize);
    final hexes =
        neighbors.map((c) => c.toRadixString(16).toLowerCase()).toList();

    await _captureService.refreshNearbyOwners(uid, hexes);

    if (_lastLat != null && _lastLng != null) {
      await _mapRenderService.clearVisibleCaptured();
      await _mapRenderService.updateVisibleCapturedTiles(
        centerLat: _lastLat!,
        centerLng: _lastLng!,
        radiusMeters: renderRadiusMeters,
        capturedHexes: _captureService.capturedHexes,
        nearbyOwnerByHex: _captureService.nearbyOwnerByHex,
        currentUserId: _currentUserId(),
      );
    }
  }

  Future<bool> _ensureLocationPermission() async {
    return _locationService.ensurePermission(context: context);
  }

  Future<void> _applyLatLng(
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

    final cell = _h3.geoToCell(h3.GeoCoord(lat: lat, lon: lng), h3Resolution);
    final cellHex = cell.toRadixString(16).toLowerCase();

    final prevHex = _currentCell?.toRadixString(16).toLowerCase();
    if (prevHex != null && prevHex == cellHex) {
      await _refreshNearbyFromSupabase();
      await _mapRenderService.updateVisibleCapturedTiles(
        centerLat: lat,
        centerLng: lng,
        radiusMeters: renderRadiusMeters,
        capturedHexes: _captureService.capturedHexes,
        nearbyOwnerByHex: _captureService.nearbyOwnerByHex,
        currentUserId: _currentUserId(),
      );
      return;
    }

    final isAlreadyCaptured = _captureService.isCaptured(cellHex);

    setState(() {
      _currentCell = cell;
      _currentTile = 'H3-$h3Resolution:$cellHex';
      _captured = isAlreadyCaptured;
    });

    await _mapRenderService.drawCurrentCell(cell, captured: isAlreadyCaptured);
    await _refreshNearbyFromSupabase();
    await _mapRenderService.updateVisibleCapturedTiles(
      centerLat: lat,
      centerLng: lng,
      radiusMeters: renderRadiusMeters,
      capturedHexes: _captureService.capturedHexes,
      nearbyOwnerByHex: _captureService.nearbyOwnerByHex,
      currentUserId: _currentUserId(),
    );

    if (moveCamera) {
      _map?.flyTo(
        mb.CameraOptions(
          center: mb.Point(coordinates: mb.Position(lng, lat)),
          zoom: 15.2,
        ),
        mb.MapAnimationOptions(duration: 650),
      );
    }

    _nearbyRefreshTimer ??= Timer.periodic(const Duration(seconds: 15), (_) {
      _refreshNearbyFromSupabase();
    });
  }

  Future<void> _centerOnMeOnce() async {
    final ok = await _ensureLocationPermission();
    if (!ok) return;

    final pos = await _locationService.getCurrentPosition();

    await _applyLatLng(
      pos.latitude,
      pos.longitude,
      moveCamera: true,
      accuracy: pos.accuracy,
    );
  }

  Future<void> _startTracking() async {
    final ok = await _ensureLocationPermission();
    if (!ok) return;

    await _posSub?.cancel();
    setState(() => _tracking = true);

    const settings = geo.LocationSettings(
      accuracy: geo.LocationAccuracy.high,
      distanceFilter: 15,
    );

    _posSub = _locationService
        .getPositionStream(settings: settings)
        .listen((pos) async {
        await _applyLatLng(
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
  }

  Future<void> _stopTracking() async {
    await _posSub?.cancel();
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
    final ok = await _ensureLocationPermission();
    if (!ok) return;

    if (_simBaseLat == null || _simBaseLng == null) {
      final pos = await _locationService.getCurrentPosition();
      _simBaseLat = pos.latitude;
      _simBaseLng = pos.longitude;
      _simStep = 0;
    }

    const double stepMeters = 260;
    const double dLat = stepMeters / 111000.0;

    _simStep += 1;

    final lat = _simBaseLat! + (_simStep * dLat);
    final lng = _simBaseLng! + ((_simStep.isEven) ? 0.0020 : -0.0020);

    await _applyLatLng(lat, lng, moveCamera: true, accuracy: 5.0);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Simulated step $_simStep (~${stepMeters.toInt()}m)')),
    );
  }

  Future<void> _captureCurrentTile() async {
    if (_currentCell == null || _lastLat == null || _lastLng == null) return;

    final cellHex = _currentCell!.toRadixString(16).toLowerCase();

    if (_captureService.isCaptured(cellHex)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Already captured ✅')),
      );
      return;
    }

    if (_lastAccuracy == null || _lastAccuracy! > maxAllowedAccuracyMeters) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'GPS accuracy too low for capture. Need ≤ ${maxAllowedAccuracyMeters.toInt()}m.',
          ),
        ),
      );
      return;
    }

    final centroid = _mapRenderService.cellCentroid(_currentCell!, cellHex);
    final distanceToCenter = MapRenderService.haversineMeters(
      _lastLat!,
      _lastLng!,
      centroid.lat,
      centroid.lng,
    );

    if (distanceToCenter > maxCaptureDistanceMeters) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Move closer to tile center to capture. Distance: ${distanceToCenter.toStringAsFixed(0)}m / ${maxCaptureDistanceMeters.toInt()}m allowed.',
          ),
        ),
      );
      return;
    }

    _captureService.capturedHexes.add(cellHex);
    await _saveCapturedToPrefs();

    if (_sb.auth.currentUser != null) {
      try {
        await _upsertCaptureToSupabase(cellHex);
        await _upsertOwnershipToSupabase(cellHex);
      } catch (_) {}
    }

    setState(() => _captured = true);

    await _mapRenderService.drawCurrentCell(_currentCell!, captured: true);

    await _refreshNearbyFromSupabase();
    await _mapRenderService.updateVisibleCapturedTiles(
      centerLat: _lastLat!,
      centerLng: _lastLng!,
      radiusMeters: renderRadiusMeters,
      capturedHexes: _captureService.capturedHexes,
      nearbyOwnerByHex: _captureService.nearbyOwnerByHex,
      currentUserId: _currentUserId(),
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _supabaseReady ? 'Tile captured ✅ (synced)' : 'Tile captured ✅ (saved locally)',
        ),
      ),
    );
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
        title: const Text('Seattle Map'),
        actions: [
          IconButton(
            onPressed: _centerOnMeOnce,
            icon: const Icon(Icons.my_location),
            tooltip: 'Center once',
          ),
          IconButton(
            onPressed: _toggleTracking,
            icon: Icon(_tracking ? Icons.pause_circle : Icons.play_circle),
            tooltip: _tracking ? 'Stop tracking' : 'Start tracking',
          ),
          IconButton(
            onPressed: () => setState(() => _followMe = !_followMe),
            icon: Icon(_followMe ? Icons.gps_fixed : Icons.gps_not_fixed),
            tooltip: _followMe ? 'Follow: ON' : 'Follow: OFF',
          ),
          IconButton(
            onPressed: _simulateMove,
            icon: const Icon(Icons.directions_walk),
            tooltip: 'Simulate walk path',
          ),
        ],
      ),
      body: Stack(
        children: [
          mb.MapWidget(
            key: const ValueKey('mapWidget'),
            cameraOptions: mb.CameraOptions(
              center: mb.Point(coordinates: mb.Position(-122.3321, 47.6062)),
              zoom: 11.5,
            ),
            onMapCreated: (mapboxMap) async {
              _map = mapboxMap;
              await _mapRenderService.attachMap(mapboxMap);

              if (_lastLat != null && _lastLng != null) {
                await _refreshNearbyFromSupabase();
                await _mapRenderService.updateVisibleCapturedTiles(
                  centerLat: _lastLat!,
                  centerLng: _lastLng!,
                  radiusMeters: renderRadiusMeters,
                  capturedHexes: _captureService.capturedHexes,
                  nearbyOwnerByHex: _captureService.nearbyOwnerByHex,
                  currentUserId: _currentUserId(),
                );
              }
            },
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
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
                                      color: _tracking ? Colors.green : Colors.grey,
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
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(_currentTile),
                              const SizedBox(height: 4),
                              Text(
                                _captureStatusText(),
                                style: const TextStyle(fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        FilledButton(
                          onPressed: _currentTile == 'unknown' ? null : _captureCurrentTile,
                          child: Text(_captured ? 'Captured' : 'Capture'),
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