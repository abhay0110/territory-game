import 'dart:math' as math;

import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mb;
import 'package:h3_flutter/h3_flutter.dart' as h3lib;

import '../../../core/constants/game_colors.dart';
import '../../../models/game_tile.dart';

class MapRenderService {
  MapRenderService({required this.h3Instance, required this.h3Resolution});

  final h3lib.H3 h3Instance;
  final int h3Resolution;

  mb.MapboxMap? _map;
  mb.PolygonAnnotationManager? _currentMgr;
  mb.PolygonAnnotationManager? _capturedMgr;
  mb.PolygonAnnotationManager? _selectionMgr;
  mb.PolygonAnnotationManager? _recommendationHaloMgr;
  mb.PolygonAnnotationManager? _recommendationMgr;
  mb.PolygonAnnotation? _currentPoly;
  mb.PolygonAnnotation? _selectionPoly;
  mb.PolygonAnnotation? _recommendationHaloPoly;
  mb.PolygonAnnotation? _recommendationPoly;

  final Map<String, mb.PolygonAnnotation> _capturedPolyByHex = {};
  final Set<String> _visibleCapturedHex = {};
  final Map<String, ({double lat, double lng})> _centroidCache = {};

  Set<String> get visibleCapturedHex => _visibleCapturedHex;

  static const int _colorMineProtected = GameColors.neonGreenArgb;
  static const int _colorMineExpired = GameColors.myTileGreenArgb;
  static const int _colorEnemyProtected = GameColors.rivalRedArgb;
  static const int _colorEnemyCapturable = GameColors.rivalRedDarkArgb;
  static const int _colorNeutral = GameColors.neutralGrayArgb;
  static const int _outlineColor = GameColors.outlineDarkArgb;
  static const int _enemyCapturableOutlineColor =
      GameColors.rivalOutlineDarkArgb;
  static const int _currentOutlineColor = GameColors.currentBorderArgb;

  ({int fillColor, double opacity, int outlineColor}) _styleForTile(
    GameTile tile, {
    required bool isCurrent,
  }) {
    final now = DateTime.now();
    final isProtected =
        tile.protectedUntil != null && tile.protectedUntil!.isAfter(now);

    final fillColor = switch (tile.ownership) {
      TileOwnership.mine =>
        isProtected ? _colorMineProtected : _colorMineExpired,
      TileOwnership.enemy =>
        isProtected ? _colorEnemyProtected : _colorEnemyCapturable,
      TileOwnership.neutral => _colorNeutral,
    };

    final opacity = switch (tile.ownership) {
      TileOwnership.mine =>
        isCurrent ? (isProtected ? 0.52 : 0.42) : (isProtected ? 0.34 : 0.24),
      TileOwnership.enemy =>
        isCurrent ? (isProtected ? 0.50 : 0.40) : (isProtected ? 0.32 : 0.20),
      TileOwnership.neutral => isCurrent ? 0.48 : 0.30,
    };

    final baseOutline = switch (tile.ownership) {
      TileOwnership.enemy =>
        isProtected ? _outlineColor : _enemyCapturableOutlineColor,
      _ => _outlineColor,
    };

    return (
      fillColor: fillColor,
      opacity: opacity,
      outlineColor: isCurrent ? _currentOutlineColor : baseOutline,
    );
  }

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
    _selectionMgr ??= await _map!.annotations.createPolygonAnnotationManager();
    // Halo must be created before ring so ring renders on top.
    _recommendationHaloMgr ??=
      await _map!.annotations.createPolygonAnnotationManager();
    _recommendationMgr ??=
      await _map!.annotations.createPolygonAnnotationManager();
  }

  mb.PolygonAnnotationOptions _polygonOptionsForCell(
    h3lib.H3Index cell, {
    required int fillColor,
    int outlineColor = _outlineColor,
    double opacity = 0.25,
  }) {
    final boundary = h3Instance.cellToBoundary(cell);
    final ring = boundary.map((c) => mb.Position(c.lon, c.lat)).toList();
    if (ring.isNotEmpty) ring.add(ring.first);

    return mb.PolygonAnnotationOptions(
      geometry: mb.Polygon(coordinates: [ring]),
      fillOpacity: opacity,
      fillColor: fillColor,
      fillOutlineColor: outlineColor,
    );
  }

  Future<void> drawCurrentCell(
    h3lib.H3Index cell, {
    required GameTile tile,
  }) async {
    await _ensureManagers();
    if (_currentMgr == null) return;

    if (_currentPoly != null) {
      await _currentMgr!.delete(_currentPoly!);
      _currentPoly = null;
    }

    final style = _styleForTile(tile, isCurrent: true);

    final options = _polygonOptionsForCell(
      cell,
      fillColor: style.fillColor,
      outlineColor: style.outlineColor,
      opacity: style.opacity,
    );

    _currentPoly = await _currentMgr!.create(options);
  }

  Future<void> setCapturedVisible(GameTile tile, bool visible) async {
    await _ensureManagers();
    if (_capturedMgr == null) return;

    final hexLower = tile.h3Index.toLowerCase();

    if (visible) {
      if (_visibleCapturedHex.contains(hexLower)) return;
      final style = _styleForTile(tile, isCurrent: false);

      final cell = BigInt.parse(hexLower, radix: 16);
      final options = _polygonOptionsForCell(
        cell,
        fillColor: style.fillColor,
        outlineColor: style.outlineColor,
        opacity: style.opacity,
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
      await _setHexVisible(hex, false);
    }
  }

  Future<void> _setHexVisible(String hexLower, bool visible) async {
    await _ensureManagers();
    if (_capturedMgr == null) return;

    if (visible) return;
    if (!_visibleCapturedHex.contains(hexLower)) return;

    final poly = _capturedPolyByHex[hexLower];
    if (poly != null) {
      await _capturedMgr!.delete(poly);
      _capturedPolyByHex.remove(hexLower);
    }
    _visibleCapturedHex.remove(hexLower);
  }

  // ── Geometry helpers ──────────────────────────────────────────────────────

  static double _degToRad(double d) => d * math.pi / 180.0;

  static double haversineMeters(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const r = 6371000.0;
    final dLat = _degToRad(lat2 - lat1);
    final dLon = _degToRad(lon2 - lon1);
    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_degToRad(lat1)) *
            math.cos(_degToRad(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  ({double lat, double lng}) cellCentroid(
    h3lib.H3Index cell,
    String cellHexLower,
  ) {
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

    final centroid = (
      lat: latSum / boundary.length,
      lng: lngSum / boundary.length,
    );
    _centroidCache[cellHexLower] = centroid;
    return centroid;
  }

  /// Show/hide all tiles within [radiusMeters] of [centerLat]/[centerLng].
  Future<void> updateVisibleCapturedTiles({
    required double centerLat,
    required double centerLng,
    required double radiusMeters,
    required List<GameTile> tiles,
  }) async {
    await _ensureManagers();
    if (_capturedMgr == null) return;

    final tileByHex = <String, GameTile>{
      for (final tile in tiles) tile.h3Index.toLowerCase(): tile,
    };
    final allKnownHexes = tileByHex.keys.toSet();

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
      final tile = tileByHex[hex];
      if (tile != null) {
        await setCapturedVisible(tile, true);
      }
    }

    for (final hex
        in _visibleCapturedHex.difference(shouldBeVisible).toList()) {
      await _setHexVisible(hex, false);
    }
  }

  /// Draws the current tile based on [GameTile] ownership/protection state.
  Future<void> drawCurrentTile(GameTile tile) async {
    final cell = BigInt.parse(tile.h3Index, radix: 16);
    await drawCurrentCell(cell, tile: tile);
  }

  /// [MapController]-friendly overload: derives centre from [currentHex] and
  /// uses a [List<GameTile>] to determine ownership colouring.
  Future<void> updateVisibleCapturedTilesByHex({
    required String currentHex,
    required List<GameTile> tiles,
    double radiusMeters = 1500,
  }) async {
    final hexBigInt = BigInt.parse(currentHex, radix: 16);
    final center = cellCentroid(hexBigInt, currentHex);

    await updateVisibleCapturedTiles(
      centerLat: center.lat,
      centerLng: center.lng,
      radiusMeters: radiusMeters,
      tiles: tiles,
    );
  }

  /// Draws a selection ring (bright white/cyan outline, faint fill) around the
  /// given [h3Index] to highlight the user-tapped tile.
  Future<void> drawSelectionHex(String h3Index) async {
    await _ensureManagers();
    if (_selectionMgr == null) return;

    if (_selectionPoly != null) {
      await _selectionMgr!.delete(_selectionPoly!);
      _selectionPoly = null;
    }

    try {
      final cell = BigInt.parse(h3Index.toLowerCase(), radix: 16);
      // Faint white fill + solid white outline to make the hex pop.
      final options = _polygonOptionsForCell(
        cell,
        fillColor: 0x33FFFFFF,
        outlineColor: 0xFFFFFFFF,
        opacity: 0.20,
      );
      _selectionPoly = await _selectionMgr!.create(options);
    } catch (_) {}
  }

  /// Removes the selection ring added by [drawSelectionHex].
  Future<void> clearSelectionHex() async {
    if (_selectionPoly == null || _selectionMgr == null) return;
    await _selectionMgr!.delete(_selectionPoly!);
    _selectionPoly = null;
  }

  // accentPrimary cyan: 0xFF49D6FF
  static const int _accentPrimaryCyan = 0xFF49D6FF;
  static const int _accentPrimaryCyanMuted = 0xFF2BAFD4;

  /// Draws a two-layer glowing target ring for the recommended tile.
  ///
  /// Layer 1 (halo): soft cyan fill wash — provides glow halo feel.
  /// Layer 2 (ring): brighter fill + crisp bright outline — the unmistakable ring.
  Future<void> drawRecommendedHex(
    String h3Index, {
    required bool pulseOn,
    bool strong = true,
  }) async {
    await _ensureManagers();
    if (_recommendationMgr == null || _recommendationHaloMgr == null) return;

    // Clear previous polys on both layers.
    if (_recommendationHaloPoly != null) {
      await _recommendationHaloMgr!.delete(_recommendationHaloPoly!);
      _recommendationHaloPoly = null;
    }
    if (_recommendationPoly != null) {
      await _recommendationMgr!.delete(_recommendationPoly!);
      _recommendationPoly = null;
    }

    try {
      final cell = BigInt.parse(h3Index.toLowerCase(), radix: 16);

      // ── Layer 1: soft halo wash (below the ring) ────────────────────────
      // Pulses between very transparent and faintly visible to create a
      // gentle breathing glow backdrop beneath the crisp ring.
      final haloOpacity = strong
          ? (pulseOn ? 0.20 : 0.08)
          : (pulseOn ? 0.12 : 0.05);
      final haloOptions = _polygonOptionsForCell(
        cell,
        fillColor: _accentPrimaryCyan,
        outlineColor: _accentPrimaryCyan, // blend outline into fill
        opacity: haloOpacity,
      );
      _recommendationHaloPoly =
          await _recommendationHaloMgr!.create(haloOptions);

      // ── Layer 2: bright ring (on top of halo) ───────────────────────────
      // Strong fill + vivid outline — makes the tile unmistakable as the
      // first-action target even against a dark map background.
      final ringOpacity = strong
          ? (pulseOn ? 0.38 : 0.18)
          : (pulseOn ? 0.22 : 0.10);
      final ringOutline =
          pulseOn ? _accentPrimaryCyan : _accentPrimaryCyanMuted;
      final ringOptions = _polygonOptionsForCell(
        cell,
        fillColor: _accentPrimaryCyan,
        outlineColor: ringOutline,
        opacity: ringOpacity,
      );
      _recommendationPoly = await _recommendationMgr!.create(ringOptions);
    } catch (_) {}
  }

  Future<void> clearRecommendedHex() async {
    if (_recommendationHaloPoly != null && _recommendationHaloMgr != null) {
      await _recommendationHaloMgr!.delete(_recommendationHaloPoly!);
      _recommendationHaloPoly = null;
    }
    if (_recommendationPoly == null || _recommendationMgr == null) return;
    await _recommendationMgr!.delete(_recommendationPoly!);
    _recommendationPoly = null;
  }

  void dispose() {
    _recommendationHaloPoly = null;
    _recommendationPoly = null;
    _selectionPoly = null;
    _currentPoly = null;
    _capturedPolyByHex.clear();
    _visibleCapturedHex.clear();
  }
}
