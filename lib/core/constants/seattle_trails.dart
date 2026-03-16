import 'package:h3_flutter/h3_flutter.dart' as h3lib;

import '../../models/trail_progress.dart';

typedef TrailPoint = ({double lat, double lng});

class SeattleTrailDefinitions {
  static final h3lib.H3 _h3 = const h3lib.H3Factory().load();
  static const int _h3Resolution = 9;

  static final List<TrailDefinition> trails = [
    TrailDefinition(
      id: 'burke_gilman',
      name: 'Burke-Gilman',
      orderedH3Indexes: _buildOrderedH3Sequence(
        _burkeGilmanWaypoints,
        samplesPerSegment: 12,
      ),
    ),
    TrailDefinition(
      id: 'sammamish_river',
      name: 'Sammamish River',
      orderedH3Indexes: _buildOrderedH3Sequence(
        _sammamishRiverWaypoints,
        samplesPerSegment: 12,
      ),
    ),
  ];

  static const List<TrailPoint> _burkeGilmanWaypoints = [
    (lat: 47.6680, lng: -122.3870),
    (lat: 47.6665, lng: -122.3650),
    (lat: 47.6640, lng: -122.3450),
    (lat: 47.6620, lng: -122.3250),
    (lat: 47.6625, lng: -122.3050),
    (lat: 47.6645, lng: -122.2850),
    (lat: 47.6675, lng: -122.2650),
    (lat: 47.6715, lng: -122.2450),
    (lat: 47.6760, lng: -122.2250),
    (lat: 47.6810, lng: -122.2050),
    (lat: 47.6860, lng: -122.1850),
  ];

  static const List<TrailPoint> _sammamishRiverWaypoints = [
    (lat: 47.7590, lng: -122.1900),
    (lat: 47.7440, lng: -122.1760),
    (lat: 47.7300, lng: -122.1640),
    (lat: 47.7160, lng: -122.1520),
    (lat: 47.7000, lng: -122.1420),
    (lat: 47.6840, lng: -122.1310),
    (lat: 47.6680, lng: -122.1240),
  ];

  static List<String> _buildOrderedH3Sequence(
    List<TrailPoint> waypoints, {
    int samplesPerSegment = 10,
  }) {
    if (waypoints.length < 2) return const [];

    final ordered = <String>[];
    final seen = <String>{};

    for (var i = 0; i < waypoints.length - 1; i++) {
      final a = waypoints[i];
      final b = waypoints[i + 1];

      for (var s = 0; s <= samplesPerSegment; s++) {
        final t = s / samplesPerSegment;
        final lat = a.lat + (b.lat - a.lat) * t;
        final lng = a.lng + (b.lng - a.lng) * t;

        final cell = _h3.geoToCell(
          h3lib.GeoCoord(lat: lat, lon: lng),
          _h3Resolution,
        );
        final hex = cell.toRadixString(16).toLowerCase();

        if (seen.add(hex)) {
          ordered.add(hex);
        }
      }
    }

    return ordered;
  }
}
