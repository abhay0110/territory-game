import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

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

  // Managers
  mb.PolygonAnnotationManager? _currentMgr;
  mb.PolygonAnnotationManager? _capturedMgr;

  // Current tile polygon
  mb.PolygonAnnotation? _currentPoly;

  // Captured polygons cache: hex -> polygon
  final Map<String, mb.PolygonAnnotation> _capturedPolyByHex = {};
  final Set<String> _visibleCapturedHex = {};

  // H3
  final h3.H3 _h3 = const h3.H3Factory().load();
  h3.H3Index? _currentCell;

  String _currentTile = 'unknown';
  bool _captured = false;

  // Tracking
  StreamSubscription<geo.Position>? _posSub;
  bool _tracking = false;
  bool _followMe = true;

  // ---- v0.6 settings ----
  // Option B: larger tiles
  static const int h3Resolution = 9; // ~250m-ish
  static const double renderRadiusMeters = 1500; // only show captured tiles within ~1.5km

  // Persistence (separate key per resolution so res10 data doesn't conflict)
  static const String _prefsKeyCaptured = 'captured_h3_cells_res9_v1';
  final Set<String> _capturedCellsHex = {}; // lowercase hex strings

  // Cache centroids for distance checks: hex -> (lat,lng)
  final Map<String, ({double lat, double lng})> _centroidCache = {};

  // Mapbox expects ARGB int colors
  static const int _colorUncaptured = 0xFF3498DB; // blue
  static const int _colorCaptured = 0xFF2ECC71; // green
  static const int _outlineColor = 0xFF000000;

  // Removed unused _mapReady

  // Simulate-walk path state (so it keeps expanding)
  int _simStep = 0;
  double? _simBaseLat;
  double? _simBaseLng;

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

  // ---------------- Persistence ----------------
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
      if (mounted) setState(() {});
    } catch (_) {
      // ignore corrupted data
    }

    // If map is ready and we already have a position, visible tiles will be drawn on next _applyLatLng
  }

  Future<void> _saveCapturedToPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _capturedCellsHex.toList()..sort();
    await prefs.setString(_prefsKeyCaptured, jsonEncode(list));
  }

  // ---------------- Mapbox managers ----------------
  Future<void> _ensureManagers() async {
    if (_map == null) return;

    if (_currentMgr == null) {
      _currentMgr = await _map!.annotations.createPolygonAnnotationManager();
    }
    if (_capturedMgr == null) {
      _capturedMgr = await _map!.annotations.createPolygonAnnotationManager();
    }
  }

  // ---------------- Geometry helpers ----------------
  static double _degToRad(double d) => d * math.pi / 180.0;

  static double _haversineMeters(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371000.0; // Earth radius meters
    final dLat = _degToRad(lat2 - lat1);
    final dLon = _degToRad(lon2 - lon1);

    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_degToRad(lat1)) *
            math.cos(_degToRad(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);

    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return r * c;
  }

  ({double lat, double lng}) _cellCentroid(h3.H3Index cell, String cellHexLower) {
    final cached = _centroidCache[cellHexLower];
    if (cached != null) return cached;

    final boundary = _h3.cellToBoundary(cell);
    if (boundary.isEmpty) {
      // fallback
      final fallback = (lat: 0.0, lng: 0.0);
      _centroidCache[cellHexLower] = fallback;
      return fallback;
    }

    double latSum = 0, lngSum = 0;
    for (final p in boundary) {
      latSum += p.lat;
      lngSum += p.lon;
    }

    final centroid = (lat: latSum / boundary.length, lng: lngSum / boundary.length);
    _centroidCache[cellHexLower] = centroid;
    return centroid;
  }

  mb.PolygonAnnotationOptions _polygonOptionsForCell(
    h3.H3Index cell, {
    required bool captured,
    double opacity = 0.25,
  }) {
    final boundary = _h3.cellToBoundary(cell);
    final ring = boundary.map((c) => mb.Position(c.lon, c.lat)).toList();
    if (ring.isNotEmpty) ring.add(ring.first);

    return mb.PolygonAnnotationOptions(
      geometry: mb.Polygon(coordinates: [ring]),
      fillOpacity: opacity,
      fillColor: captured ? _colorCaptured : _colorUncaptured,
      fillOutlineColor: _outlineColor,
    );
  }

  Future<void> _drawCurrentCell(h3.H3Index cell, {required bool captured}) async {
    await _ensureManagers();
    if (_currentMgr == null) return;

    if (_currentPoly != null) {
      await _currentMgr!.delete(_currentPoly!);
      _currentPoly = null;
    }

    final options = _polygonOptionsForCell(cell, captured: captured, opacity: 0.40);
    _currentPoly = await _currentMgr!.create(options);
  }

  Future<void> _setCapturedVisible(String hexLower, bool visible) async {
    if (_capturedMgr == null) return;

    if (visible) {
      if (_visibleCapturedHex.contains(hexLower)) return;

      // Create polygon if not already cached
      final existing = _capturedPolyByHex[hexLower];
      if (existing != null) {
        // If we cached one but removed from visible, it means it was deleted.
        // So treat as not existing.
        _capturedPolyByHex.remove(hexLower);
      }

      // Create fresh polygon
      final cell = BigInt.parse(hexLower, radix: 16);
      final options = _polygonOptionsForCell(cell, captured: true, opacity: 0.22);
      final poly = await _capturedMgr!.create(options);

      _capturedPolyByHex[hexLower] = poly;
      _visibleCapturedHex.add(hexLower);
    } else {
      if (!_visibleCapturedHex.contains(hexLower)) return;

      final poly = _capturedPolyByHex[hexLower];
      if (poly != null) {
        await _capturedMgr!.delete(poly);
        _capturedPolyByHex.remove(hexLower);
      }
      _visibleCapturedHex.remove(hexLower);
    }
  }

  Future<void> _updateVisibleCapturedTiles({required double centerLat, required double centerLng}) async {
    await _ensureManagers();
    if (_capturedMgr == null) return;

    // Determine which captured tiles should be visible within radius
    final Set<String> shouldBeVisible = {};

    for (final hexLower in _capturedCellsHex) {
      try {
        final cell = BigInt.parse(hexLower, radix: 16);
        final c = _cellCentroid(cell, hexLower);
          final d = _haversineMeters(centerLat, centerLng, c.lat, c.lng);
        if (d <= renderRadiusMeters) {
          shouldBeVisible.add(hexLower);
        }
      } catch (_) {
        // skip malformed
      }
    }

    // Show new ones
    for (final hex in shouldBeVisible.difference(_visibleCapturedHex)) {
      await _setCapturedVisible(hex, true);
    }

    // Hide far ones
    for (final hex in _visibleCapturedHex.difference(shouldBeVisible).toList()) {
      await _setCapturedVisible(hex, false);
    }
  }

  // ---------------- Location ----------------
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
    final cell = _h3.geoToCell(h3.GeoCoord(lat: lat, lon: lng), h3Resolution);
    final cellHex = cell.toRadixString(16).toLowerCase();

    final prevHex = _currentCell?.toRadixString(16).toLowerCase();
    if (prevHex != null && prevHex == cellHex) {
      // Even if tile didn't change, keep visible set updated (helps follow camera)
      await _updateVisibleCapturedTiles(centerLat: lat, centerLng: lng);
      return;
    }

    final isAlreadyCaptured = _capturedCellsHex.contains(cellHex);

    setState(() {
      _currentCell = cell;
      _currentTile = 'H3-$h3Resolution:$cellHex';
      _captured = isAlreadyCaptured;
    });

    await _drawCurrentCell(cell, captured: isAlreadyCaptured);
    await _updateVisibleCapturedTiles(centerLat: lat, centerLng: lng);

    if (moveCamera) {
      _map?.flyTo(
        mb.CameraOptions(
          center: mb.Point(coordinates: mb.Position(lng, lat)),
          zoom: 15.2,
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
      distanceFilter: 15, // meters (slightly higher with larger tiles)
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

  // Simulate-walk: keeps moving farther each tap (no toggling between a few cells)
  Future<void> _simulateMove() async {
    final ok = await _ensureLocationPermission();
    if (!ok) return;

    if (_simBaseLat == null || _simBaseLng == null) {
      final pos = await geo.Geolocator.getCurrentPosition(
        desiredAccuracy: geo.LocationAccuracy.high,
      );
      _simBaseLat = pos.latitude;
      _simBaseLng = pos.longitude;
      _simStep = 0;
    }

    const double stepMeters = 260; // larger tiles -> bigger step
    const double dLat = stepMeters / 111000.0;

    _simStep += 1;

    final lat = _simBaseLat! + (_simStep * dLat);
    final lng = _simBaseLng! + ((_simStep.isEven) ? 0.0020 : -0.0020);

    await _applyLatLng(lat, lng, moveCamera: true);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Simulated step $_simStep (~${stepMeters.toInt()}m)')),
    );
  }

  Future<void> _captureCurrentTile() async {
    if (_currentCell == null) return;

    final cellHex = _currentCell!.toRadixString(16).toLowerCase();

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

    await _drawCurrentCell(_currentCell!, captured: true);

    // Make sure the newly captured tile is visible if within radius
    // (it will be within radius because it’s the current one)
    await _updateVisibleCapturedTiles(
      centerLat: _h3.cellToBoundary(_currentCell!).first.lat,
      centerLng: _h3.cellToBoundary(_currentCell!).first.lon,
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Tile captured ✅ (saved)')),
    );
  }

  // ---------------- UI ----------------
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
              await _ensureManagers();
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
                              const SizedBox(width: 10),
                              Text(
                                'Saved: ${_capturedCellsHex.length}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Text(
                                'Visible: ${_visibleCapturedHex.length}',
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