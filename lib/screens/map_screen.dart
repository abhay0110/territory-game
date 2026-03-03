import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mb;
import 'package:h3_flutter/h3_flutter.dart';

import '../config/mapbox.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  mb.MapboxMap? _map;

  late final H3 _h3;

  String _currentTile = 'unknown';
  bool _captured = false;

  @override
  void initState() {
    super.initState();
    mb.MapboxOptions.setAccessToken(kMapboxAccessToken);
    _h3 = H3Factory().load();
  }

  Future<void> _centerOnMe() async {
    final serviceEnabled = await geo.Geolocator.isLocationServiceEnabled();

    if (!serviceEnabled) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Turn on Location Services')),
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
        const SnackBar(content: Text('Location permission denied')),
      );
      return;
    }

    final geo.Position pos = await geo.Geolocator.getCurrentPosition(
      desiredAccuracy: geo.LocationAccuracy.high,
    );

    const int walkResolution = 10;

    final h3Index = _h3.geoToCell(
      GeoCoord(lat: pos.latitude, lon: pos.longitude),
      walkResolution,
    );

    setState(() {
      _currentTile = 'H3-$walkResolution:$h3Index';
      _captured = false;
    });

    _map?.flyTo(
      mb.CameraOptions(
        center: mb.Point(
          coordinates: mb.Position(pos.longitude, pos.latitude),
        ),
        zoom: 16,
      ),
      mb.MapAnimationOptions(duration: 800),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (kMapboxAccessToken.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Map')),
        body: const Center(
          child: Text('Missing Mapbox token'),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Seattle Map'),
        actions: [
          IconButton(
            icon: const Icon(Icons.my_location),
            onPressed: _centerOnMe,
          ),
        ],
      ),
      body: Stack(
        children: [
          mb.MapWidget(
            key: const ValueKey("mapWidget"),
            cameraOptions: mb.CameraOptions(
              center: mb.Point(
                coordinates: mb.Position(-122.3321, 47.6062),
              ),
              zoom: 11.5,
            ),
            onMapCreated: (mapboxMap) {
              _map = mapboxMap;
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
                        children: [
                          const Text(
                            "Current tile",
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(_currentTile),
                        ],
                      ),
                    ),
                    FilledButton(
                      onPressed: _currentTile == 'unknown'
                          ? null
                          : () {
                              setState(() {
                                _captured = true;
                              });

                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text("Tile captured ✅"),
                                ),
                              );
                            },
                      child: Text(_captured ? "Captured" : "Capture"),
                    )
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