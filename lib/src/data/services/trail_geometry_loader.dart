import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

/// A single (lat, lng) pair used by the visual polyline overlay.
typedef TrailLatLng = ({double lat, double lng});

/// One contiguous polyline segment.  A trail may consist of multiple segments
/// if the source data has gaps the renderer should NOT bridge with a chord
/// (e.g. waterfront curves or unmapped bridge approaches).
typedef TrailSegment = List<TrailLatLng>;

/// Loads high-fidelity trail geometry (sourced from OpenStreetMap via
/// `tool/fetch_trail_geometry.dart` and bundled as GeoJSON assets) for use
/// by the visual polyline overlay only.
///
/// Gameplay-critical geometry (capture eligibility, leaderboard, section
/// ordering, recommendation) continues to flow from
/// `SeattleTrailDefinitions.burkeGilmanWaypoints` and is intentionally NOT
/// served from this loader.
class TrailGeometryLoader {
  TrailGeometryLoader._();
  static final TrailGeometryLoader instance = TrailGeometryLoader._();

  static const String _burkeGilmanAsset = 'assets/trails/burke_gilman.geojson';

  List<TrailSegment>? _burkeGilmanCache;
  Future<List<TrailSegment>>? _burkeGilmanInFlight;

  /// Loads the Burke-Gilman polyline as one or more segments.  Returns an
  /// empty list if the asset is missing or malformed; callers should treat
  /// that as "skip overlay" rather than fall back to lower-fidelity sources
  /// (we do not want to silently render the old straight-chord polyline).
  Future<List<TrailSegment>> burkeGilmanRendered() {
    final cached = _burkeGilmanCache;
    if (cached != null) return Future.value(cached);
    return _burkeGilmanInFlight ??= _load(_burkeGilmanAsset).then((segs) {
      _burkeGilmanCache = segs;
      _burkeGilmanInFlight = null;
      return segs;
    });
  }

  Future<List<TrailSegment>> _load(String assetPath) async {
    try {
      final raw = await rootBundle.loadString(assetPath);
      final decoded = jsonDecode(raw);
      final geometry = (decoded as Map)['geometry'];
      if (geometry is! Map) {
        if (kDebugMode) {
          debugPrint('TrailGeometryLoader: $assetPath missing geometry.');
        }
        return const [];
      }
      final type = geometry['type'];
      final rawCoords = geometry['coordinates'];
      if (rawCoords is! List) return const [];

      // Accept both LineString (single segment) and MultiLineString (many).
      List<List<dynamic>> rawSegments;
      if (type == 'LineString') {
        rawSegments = [rawCoords];
      } else if (type == 'MultiLineString') {
        rawSegments = rawCoords.cast<List<dynamic>>();
      } else {
        if (kDebugMode) {
          debugPrint(
            'TrailGeometryLoader: $assetPath unsupported geometry type $type.',
          );
        }
        return const [];
      }

      final segments = <TrailSegment>[];
      for (final segCoords in rawSegments) {
        final pts = <TrailLatLng>[];
        for (final pair in segCoords) {
          if (pair is! List || pair.length < 2) continue;
          final lng = (pair[0] as num).toDouble();
          final lat = (pair[1] as num).toDouble();
          pts.add((lat: lat, lng: lng));
        }
        if (pts.length >= 2) segments.add(List<TrailLatLng>.unmodifiable(pts));
      }
      return List<TrailSegment>.unmodifiable(segments);
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('TrailGeometryLoader: failed to load $assetPath: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
      return const [];
    }
  }
}
