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
  mb.MapboxMap? _map;

  mb.PolygonAnnotationManager? _polyManager;
  mb.PolygonAnnotation? _currentPoly;

  // H3
  final h3.H3 _h3 = const h3.H3Factory().load();
  h3.H3Index? _currentCell;

  String _currentTile = 'unknown';
  bool _captured = false;

  // ~100m-ish grid for walking
  static const int walkResolution = 10;

  // Mapbox expects ARGB int colors
  static const int _colorUncaptured = 0xFF3498DB; // blue
  static const int _colorCaptured = 0xFF2ECC71; // green

  @override
  void initState() {
    super.initState();
    mb.MapboxOptions.setAccessToken(kMapboxAccessToken);
  }

  Future<void> _ensurePolygonManager() async {
    if (_map == null) return;
    if (_polyManager != null) return;

    // Create PolygonAnnotationManager once
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

    final boundary = _h3.cellToBoundary(cell); // List<GeoCoord> in degrees
    if (boundary.isEmpty) return;

    // Mapbox polygon ring: list of Position(lon, lat)
    final ring = boundary.map((c) => mb.Position(c.lon, c.lat)).toList();

    // Close the ring
    ring.add(ring.first);

    final options = mb.PolygonAnnotationOptions(
      geometry: mb.Polygon(
        coordinates: [
          ring,
        ],
      ),
      fillOpacity: 0.35,
      fillColor: captured ? _colorCaptured : _colorUncaptured,
      // Optional outline:
      fillOutlineColor: 0xFF000000,
    );

    _currentPoly = await _polyManager!.create(options);
  }

  Future<void> _centerOnMe() async {
    final serviceEnabled = await geo.Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Turn on Location Services on your phone.')),
      );
      return;
    }

    geo.LocationPermission perm = await geo.Geolocator.checkPermission();
    if (perm == geo.LocationPermission.denied) {
      perm = await geo.Geolocator.requestPermission();
    }

    if (perm == geo.LocationPermission.denied ||
        perm == geo.LocationPermission.deniedForever) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Location permission denied.')),
      );
      return;
    }

    final geo.Position pos = await geo.Geolocator.getCurrentPosition(
      desiredAccuracy: geo.LocationAccuracy.high,
    );

    // H3 cell for current location
    final h3.H3Index cell = _h3.geoToCell(
      h3.GeoCoord(lat: pos.latitude, lon: pos.longitude),
      walkResolution,
    );

    // Show readable hex index
    final String cellHex = cell.toRadixString(16);

    setState(() {
      _currentCell = cell;
      _currentTile = 'H3-$walkResolution:$cellHex';
      _captured = false;
    });

    // Draw polygon (uncaptured)
    await _drawCellPolygon(cell, captured: false);

    // Fly camera to user
    _map?.flyTo(
      mb.CameraOptions(
        center: mb.Point(coordinates: mb.Position(pos.longitude, pos.latitude)),
        zoom: 16.0,
      ),
      mb.MapAnimationOptions(duration: 800),
    );
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
            onPressed: _centerOnMe,
            icon: const Icon(Icons.my_location),
            tooltip: 'Center on me',
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

          // Bottom overlay
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
                          const Text(
                            'Current tile',
                            style: TextStyle(fontWeight: FontWeight.w600),
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