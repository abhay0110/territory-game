import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mb;
import 'package:h3_flutter/h3_flutter.dart' as h3;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/mapbox.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  mb.MapboxMap? _map;

  mb.PolygonAnnotationManager? _polyManager;
  mb.PolygonAnnotation? _currentPoly;

  // H3
  final h3.H3 _h3 = const h3.H3Factory().load();
  h3.H3Index? _currentCell;

  String _currentTile = 'unknown';
  bool _captured = false;

  // v0.3 tracking
  StreamSubscription<geo.Position>? _posSub;
  bool _tracking = false;
  bool _followMe = true;

  // v0.4 persistence
  static const String _prefsKeyCaptured = 'captured_h3_cells_v1';
  final Set<String> _capturedCellsHex = {}; // store H3 cell hex strings (lowercase)

  // ~100m-ish grid for walking
  static const int walkResolution = 10;

  // Mapbox expects ARGB int colors
  static const int _colorUncaptured = 0xFF3498DB; // blue
  static const int _colorCaptured = 0xFF2ECC71; // green
  static const int _outlineColor = 0xFF000000;

  @override
  void initState() {
    super.initState();
    mb.MapboxOptions.setAccessToken(kMapboxAccessToken);
    _loadCapturedFromPrefs();
  }

  @override
  void dispose() {
    _posSub?.cancel();
    super.dispose();
  }

  Future<void> _loadCapturedFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKeyCaptured);

    if (raw == null || raw.trim().isEmpty) return;

    try {
      final List<dynamic> list = jsonDecode(raw) as List<dynamic>;
      for (final item in list) {
        if (item is String && item.isNotEmpty) {
          _capturedCellsHex.add(item.toLowerCase());
        }
      }
      if (mounted) {
        // no UI change required right now except future tiles will show captured
        setState(() {});
      }
    } catch (_) {
      // If something got corrupted, ignore it (we can reset later)
    }
  }

  Future<void> _saveCapturedToPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _capturedCellsHex.toList()..sort();
    await prefs.setString(_prefsKeyCaptured, jsonEncode(list));
  }

  Future<void> _ensurePolygonManager() async {
    if (_map == null) return;
    if (_polyManager != null) return;
    _polyManager = await _map!.annotations.createPolygonAnnotationManager();
  }

  Future<void> _drawCellPolygon(h3.H3Index cell, {required bool captured}) async {
    await _ensurePolygonManager();
    if (_polyManager == null) return;

    if (_currentPoly != null) {
      await _polyManager!.delete(_currentPoly!);
      _currentPoly = null;
    }

    final boundary = _h3.cellToBoundary(cell);
    if (boundary.isEmpty) return;

    final ring = boundary.map((c) => mb.Position(c.lon, c.lat)).toList();
    ring.add(ring.first); // close ring

    final options = mb.PolygonAnnotationOptions(
      geometry: mb.Polygon(coordinates: [ring]),
      fillOpacity: 0.35,
      fillColor: captured ? _colorCaptured : _colorUncaptured,
      fillOutlineColor: _outlineColor,
    );

    _currentPoly = await _polyManager!.create(options);
  }

  Future<bool> _ensureLocationPermission() async {
    final serviceEnabled = await geo.Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Turn on Location Services on your phone.')),
      );
      return false;
    }

    geo.LocationPermission perm = await geo.Geolocator.checkPermission();
    if (perm == geo.LocationPermission.denied) {
      perm = await geo.Geolocator.requestPermission();
    }

    if (perm == geo.LocationPermission.denied ||
        perm == geo.LocationPermission.deniedForever) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Location permission denied.')),
      );
      return false;
    }

    return true;
  }

  Future<void> _applyLatLng(double lat, double lng, {required bool moveCamera}) async {
    final cell = _h3.geoToCell(h3.GeoCoord(lat: lat, lon: lng), walkResolution);
    final cellHex = cell.toRadixString(16).toLowerCase();

    // If tile unchanged, do nothing
    final prevHex = _currentCell?.toRadixString(16).toLowerCase();
    if (prevHex != null && prevHex == cellHex) return;

    final isAlreadyCaptured = _capturedCellsHex.contains(cellHex);

    setState(() {
      _currentCell = cell;
      _currentTile = 'H3-$walkResolution:$cellHex';
      _captured = isAlreadyCaptured;
    });

    await _drawCellPolygon(cell, captured: isAlreadyCaptured);

    if (moveCamera) {
      _map?.flyTo(
        mb.CameraOptions(
          center: mb.Point(coordinates: mb.Position(lng, lat)),
          zoom: 16.0,
        ),
        mb.MapAnimationOptions(duration: 650),
      );
    }
  }

  Future<void> _centerOnMeOnce() async {
    final ok = await _ensureLocationPermission();
    if (!ok) return;

    final pos = await geo.Geolocator.getCurrentPosition(
      desiredAccuracy: geo.LocationAccuracy.high,
    );

    await _applyLatLng(pos.latitude, pos.longitude, moveCamera: true);
  }

  Future<void> _startTracking() async {
    final ok = await _ensureLocationPermission();
    if (!ok) return;

    await _posSub?.cancel();

    setState(() => _tracking = true);

    const settings = geo.LocationSettings(
      accuracy: geo.LocationAccuracy.high,
      distanceFilter: 10, // meters
    );

    _posSub = geo.Geolocator.getPositionStream(locationSettings: settings).listen(
      (pos) async {
        await _applyLatLng(pos.latitude, pos.longitude, moveCamera: _followMe);
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

    final pos = await geo.Geolocator.getCurrentPosition(
      desiredAccuracy: geo.LocationAccuracy.high,
    );

    // Nudge ~15 meters north (rough)
    final simLat = pos.latitude + 0.000135;
    final simLng = pos.longitude;

    await _applyLatLng(simLat, simLng, moveCamera: true);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Simulated ~15m move')),
    );
  }

  Future<void> _captureCurrentTile() async {
    if (_currentCell == null) return;

    final cellHex = _currentCell!.toRadixString(16).toLowerCase();

    // Already captured -> just show message
    if (_capturedCellsHex.contains(cellHex)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Already captured ✅')),
      );
      return;
    }

    _capturedCellsHex.add(cellHex);
    await _saveCapturedToPrefs();

    setState(() => _captured = true);
    await _drawCellPolygon(_currentCell!, captured: true);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Tile captured ✅ (saved)')),
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
            tooltip: 'Simulate move (~15m)',
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
              await _ensurePolygonManager();
            },
          ),

          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
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
                              const SizedBox(width: 8),
                              Text(
                                'Saved: ${_capturedCellsHex.length}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(_currentTile),
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
              ),
            ),
          ),
        ],
      ),
    );
  }
}