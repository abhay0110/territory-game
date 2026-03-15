import 'dart:math' as math;

import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mb;
import 'package:h3_flutter/h3_flutter.dart' as h3lib;

import '../../../models/game_tile.dart';

class MapRenderService {
  MapRenderService({
    required this.h3Instance,
    required this.h3Resolution,
  });

  final h3lib.H3 h3Instance;
  final int h3Resolution;

  mb.MapboxMap? _map;
  mb.PolygonAnnotationManager? _currentMgr;
  mb.PolygonAnnotationManager? _capturedMgr;
  mb.PolygonAnnotation? _currentPoly;

  final Map<String, mb.PolygonAnnotation> _capturedPolyByHex = {};
  final Set<String> _visibleCapturedHex = {};
  final Map<String, ({double lat, double lng})> _centroidCache = {};

  Set<String> get visibleCapturedHex => _visibleCapturedHex;

  static const int _colorUncaptured = 0xFF3498DB;
  static const int _colorCaptured = 0xFF2ECC71;
  static const int _colorOtherCaptured = 0xFFE67E22;
  static const int _outlineColor = 0xFF000000;

  /// Attach the underlying Mapbox map instance to this service.
  ///
  /// Must be called once the map is created, before using drawing APIs.
  Future<void> attachMap(mb.MapboxMap map) async {
    _map = map;
    await _ensureManagers();
  }

  Future<void> _ensureManagers() async {
    if (_map == null) return;

    _currentMgr ??= await _map!.annotations.createPolygonAnnotationManager();
    _capturedMgr ??= await _map!.annotations.createPolygonAnnotationManager();
  }

  mb.PolygonAnnotationOptions _polygonOptionsForCell(
    h3lib.H3Index cell, {
    required int fillColor,
    double opacity = 0.25,
  }) {
    final boundary = h3Instance.cellToBoundary(cell);
    final ring = boundary.map((c) => mb.Position(c.lon, c.lat)).toList();
    if (ring.isNotEmpty) ring.add(ring.first);

    return mb.PolygonAnnotationOptions(
      geometry: mb.Polygon(coordinates: [ring]),
      fillOpacity: opacity,
      fillColor: fillColor,
      fillOutlineColor: _outlineColor,
    );
  }

  Future<void> drawCurrentCell(h3lib.H3Index cell, {required bool captured}) async {
    await _ensureManagers();
    if (_currentMgr == null) return;

    if (_currentPoly != null) {
      await _currentMgr!.delete(_currentPoly!);
      _currentPoly = null;
    }

    final options = _polygonOptionsForCell(
      cell,
      fillColor: captured ? _colorCaptured : _colorUncaptured,
      opacity: 0.40,
    );

    _currentPoly = await _currentMgr!.create(options);
  }

  Future<void> setCapturedVisible(
    String hexLower,
    bool visible, {
    required bool isMine,
    required bool isLocalMine,
  }) async {
    await _ensureManagers();
    if (_capturedMgr == null) return;

    if (visible) {
      if (_visibleCapturedHex.contains(hexLower)) return;

      final color = (isMine || isLocalMine) ? _colorCaptured : _colorOtherCaptured;

      final cell = BigInt.parse(hexLower, radix: 16);
      final options = _polygonOptionsForCell(
        cell,
        fillColor: color,
        opacity: 0.22,
      );

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

  /// Clears any visible captured cells.
  Future<void> clearVisibleCaptured() async {
    final list = _visibleCapturedHex.toList();
    for (final hex in list) {
      await setCapturedVisible(hex, false, isMine: false, isLocalMine: false);
    }
  }

  // ── Geometry helpers ──────────────────────────────────────────────────────

  static double _degToRad(double d) => d * math.pi / 180.0;

  static double haversineMeters(
      double lat1, double lon1, double lat2, double lon2) {
    const r = 6371000.0;
    final dLat = _degToRad(lat2 - lat1);
    final dLon = _degToRad(lon2 - lon1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_degToRad(lat1)) *
            math.cos(_degToRad(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  ({double lat, double lng}) cellCentroid(h3lib.H3Index cell, String cellHexLower) {
    final cached = _centroidCache[cellHexLower];
    if (cached != null) return cached;

    final boundary = h3Instance.cellToBoundary(cell);
    if (boundary.isEmpty) {
      const fallback = (lat: 0.0, lng: 0.0);
      _centroidCache[cellHexLower] = fallback;
      return fallback;
    }

    double latSum = 0;
    double lngSum = 0;
    for (final p in boundary) {
      latSum += p.lat;
      lngSum += p.lon;
    }

    final centroid =
        (lat: latSum / boundary.length, lng: lngSum / boundary.length);
    _centroidCache[cellHexLower] = centroid;
    return centroid;
  }

  /// Show/hide all captured tiles within [radiusMeters] of [centerLat]/[centerLng].
  ///
  /// Uses [capturedHexes] and [nearbyOwnerByHex] to determine colour.
  Future<void> updateVisibleCapturedTiles({
    required double centerLat,
    required double centerLng,
    required double radiusMeters,
    required Set<String> capturedHexes,
    required Map<String, String> nearbyOwnerByHex,
    required String? currentUserId,
  }) async {
    await _ensureManagers();
    if (_capturedMgr == null) return;

    final allKnownHexes = <String>{
      ...capturedHexes,
      ...nearbyOwnerByHex.keys,
    };

    final Set<String> shouldBeVisible = {};
    for (final hexLower in allKnownHexes) {
      try {
        final cell = BigInt.parse(hexLower, radix: 16);
        final c = cellCentroid(cell, hexLower);
        if (haversineMeters(centerLat, centerLng, c.lat, c.lng) <=
            radiusMeters) {
          shouldBeVisible.add(hexLower);
        }
      } catch (_) {}
    }

    for (final hex in shouldBeVisible.difference(_visibleCapturedHex)) {
      final owner = nearbyOwnerByHex[hex];
      final isMine = owner != null && owner == currentUserId;
      final isLocalMine = capturedHexes.contains(hex);
      await setCapturedVisible(hex, true, isMine: isMine, isLocalMine: isLocalMine);
    }

    for (final hex in _visibleCapturedHex.difference(shouldBeVisible).toList()) {
      await setCapturedVisible(hex, false, isMine: false, isLocalMine: false);
    }
  }

  /// Draws the current player tile from a hex string.
  ///
  /// [captured] controls whether the tile is coloured as owned or neutral.
  Future<void> drawCurrentTile(String hexLower, {bool captured = false}) async {
    final cell = BigInt.parse(hexLower, radix: 16);
    await drawCurrentCell(cell, captured: captured);
  }

  /// [MapController]-friendly overload: derives centre from [currentHex] and
  /// uses a [List<GameTile>] to determine ownership colouring.
  Future<void> updateVisibleCapturedTilesByHex({
    required String currentHex,
    required List<GameTile> capturedTiles,
    double radiusMeters = 1500,
  }) async {
    final hexBigInt = BigInt.parse(currentHex, radix: 16);
    final center = cellCentroid(hexBigInt, currentHex);

    final capturedHexSet = capturedTiles
        .where((t) => t.ownership == TileOwnership.mine)
        .map((t) => t.h3Index)
        .toSet();

    // Enemy tiles get a placeholder owner so they render in the enemy colour.
    final nearbyOwnerByHex = <String, String>{
      for (final t in capturedTiles.where((t) => t.ownership == TileOwnership.enemy))
        t.h3Index: 'other',
    };

    await updateVisibleCapturedTiles(
      centerLat: center.lat,
      centerLng: center.lng,
      radiusMeters: radiusMeters,
      capturedHexes: capturedHexSet,
      nearbyOwnerByHex: nearbyOwnerByHex,
      currentUserId: null,
    );
  }

  void dispose() {
    _currentPoly = null;
    _capturedPolyByHex.clear();
    _visibleCapturedHex.clear();
  }
}
