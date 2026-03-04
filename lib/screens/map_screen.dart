import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mb;
import 'package:h3_flutter/h3_flutter.dart' as h3;

import '../config/mapbox.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
    // Simulated position for movement
    geo.Position? _simPosition;
    static const double _moveDelta = 0.0005; // ~55m latitude

    // Simulate movement by shifting position north-east
    void _simulateMovement() {
      setState(() {
        if (_simPosition == null) {
          // Start at Seattle center if not set
          _simPosition = geo.Position(
            latitude: 47.6062,
            longitude: -122.3321,
            timestamp: DateTime.now(),
            accuracy: 1.0,
            altitude: 0.0,
            altitudeAccuracy: 1.0,
            heading: 0.0,
            headingAccuracy: 1.0,
            speed: 0.0,
            speedAccuracy: 1.0,
          );
        } else {
          _simPosition = geo.Position(
            latitude: _simPosition!.latitude + _moveDelta,
            longitude: _simPosition!.longitude + _moveDelta,
            timestamp: DateTime.now(),
            accuracy: _simPosition!.accuracy,
            altitude: _simPosition!.altitude,
            altitudeAccuracy: _simPosition!.altitudeAccuracy,
            heading: _simPosition!.heading,
            headingAccuracy: _simPosition!.headingAccuracy,
            speed: _simPosition!.speed,
            speedAccuracy: _simPosition!.speedAccuracy,
          );
        }
      });
      // Apply the simulated position to the map and H3 logic
      _applyPosition(_simPosition!, moveCamera: true);
    }
  mb.MapboxMap? _map;

  mb.PolygonAnnotationManager? _polyManager;
  mb.PolygonAnnotation? _currentPoly;

  final h3.H3 _h3 = const h3.H3Factory().load();
  h3.H3Index? _currentCell;

  String _currentTile = 'unknown';
  bool _captured = false;

  // v0.3 tracking
  StreamSubscription<geo.Position>? _posSub;
  bool _tracking = false;
  bool _followMe = true;

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
  }

  @override
  void dispose() {
    _posSub?.cancel();
    super.dispose();
  }

  Future<void> _ensurePolygonManager() async {
    if (_map == null) return;
    if (_polyManager != null) return;
    _polyManager = await _map!.annotations.createPolygonAnnotationManager();
  }

  Future<void> _drawCellPolygon(h3.H3Index cell, {required bool captured}) async {
    await _ensurePolygonManager();
    if (_polyManager == null) return;

    // Remove previous polygon
    if (_currentPoly != null) {
      await _polyManager!.delete(_currentPoly!);
      _currentPoly = null;
    }

    final boundary = _h3.cellToBoundary(cell);
    if (boundary.isEmpty) return;

    final ring = boundary.map((c) => mb.Position(c.lon, c.lat)).toList();
    ring.add(ring.first); // close

    final options = mb.PolygonAnnotationOptions(
      geometry: mb.Polygon(coordinates: [ring]),
      fillOpacity: 0.35,
      fillColor: captured ? _colorCaptured : _colorUncaptured,
      fillOutlineColor: _outlineColor,
    );

    _currentPoly = await _polyManager!.create(options);
  }

  // Used by both manual center and stream updates
  Future<void> _applyPosition(geo.Position pos, {required bool moveCamera}) async {
    final h3.H3Index cell = _h3.geoToCell(
      h3.GeoCoord(lat: pos.latitude, lon: pos.longitude),
      walkResolution,
    );

    // Only update when tile changes
    if (_currentCell != null && cell == _currentCell) {
      // Still optionally follow camera smoothly if you want (we skip to save battery).
      return;
    }

    final String cellHex = cell.toRadixString(16);

    setState(() {
      _currentCell = cell;
      _currentTile = 'H3-$walkResolution:$cellHex';
      _captured = false;
    });

    await _drawCellPolygon(cell, captured: false);

    if (moveCamera) {
      _map?.flyTo(
        mb.CameraOptions(
          center: mb.Point(coordinates: mb.Position(pos.longitude, pos.latitude)),
          zoom: 16.0,
        ),
        mb.MapAnimationOptions(duration: 650),
      );
    }
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

  Future<void> _centerOnMeOnce() async {
    final ok = await _ensureLocationPermission();
    if (!ok) return;

    final pos = await geo.Geolocator.getCurrentPosition(
      desiredAccuracy: geo.LocationAccuracy.high,
    );

    await _applyPosition(pos, moveCamera: true);
  }

  Future<void> _startTracking() async {
    final ok = await _ensureLocationPermission();
    if (!ok) return;

    // Cancel any existing stream
    await _posSub?.cancel();

    setState(() => _tracking = true);

    const settings = geo.LocationSettings(
      accuracy: geo.LocationAccuracy.high,
      distanceFilter: 10, // meters; tune later
    );

    _posSub = geo.Geolocator.getPositionStream(locationSettings: settings).listen(
      (pos) async {
        // Update tile; only move camera if followMe is on
        await _applyPosition(pos, moveCamera: _followMe);
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

  Future<void> _captureCurrentTile() async {
    if (_currentCell == null) return;

    setState(() => _captured = true);

    await _drawCellPolygon(_currentCell!, captured: true);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Tile captured ✅')),
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
                    const SizedBox(width: 12),
                    FilledButton(
                      onPressed: _simulateMovement,
                      child: const Text('Simulate Move'),
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