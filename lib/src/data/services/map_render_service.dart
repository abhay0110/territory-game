import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mb;
import 'package:h3_flutter/h3_flutter.dart' as h3lib;

import '../../../core/constants/game_colors.dart';
import '../../../core/constants/launch_corridor.dart';
import '../../../models/game_tile.dart';

class MapRenderService {
  MapRenderService({required this.h3Instance, required this.h3Resolution});

  final h3lib.H3 h3Instance;
  final int h3Resolution;

  mb.MapboxMap? _map;
  mb.PolygonAnnotationManager? _corridorMgr;
  mb.PolylineAnnotationManager? _trailLineMgr;
  mb.PolygonAnnotationManager? _currentHaloMgr;
  mb.PolygonAnnotationManager? _currentMgr;
  mb.PolygonAnnotationManager? _capturedMgr;
  mb.PolygonAnnotationManager? _selectionMgr;
  mb.PolygonAnnotationManager? _recommendationHaloMgr;
  mb.PolygonAnnotationManager? _recommendationMgr;
  mb.PolygonAnnotation? _currentPoly;
  mb.PolygonAnnotation? _currentHaloPoly;
  mb.PolygonAnnotation? _selectionPoly;
  mb.PolygonAnnotation? _recommendationHaloPoly;
  mb.PolygonAnnotation? _recommendationPoly;
  final List<mb.PolygonAnnotation> _corridorPolys = [];
  bool _corridorLaneDrawn = false;

  final List<mb.PolylineAnnotation> _trailLines = [];
  bool _trailLineDrawn = false;

  final Map<String, mb.PolygonAnnotation> _capturedPolyByHex = {};
  final Set<String> _visibleCapturedHex = {};
  final Map<String, ({TileOwnership ownership, bool isProtected})>
  _visibleCapturedState = {};
  final Map<String, ({double lat, double lng})> _centroidCache = {};

  /// When true, off-corridor captured tiles are rendered very faintly and the
  /// corridor lane is drawn with stronger emphasis.  Set by the map screen
  /// when the user is in the far-from-trail launch-entry state.
  bool launchEntryMode = false;

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

  // ── Launch-entry muting ────────────────────────────────────────────────

  static const int _mutedFillColor = 0xFF555555; // desaturated grey
  static const int _mutedOutlineColor = 0xFF333333;
  static const double _mutedOpacityScale =
      0.08; // 8% of normal — strongly muted
  static const int _mutedCurrentOutlineColor =
      0xFF777777; // dimmed outline for user tile when muted

  ({int fillColor, double opacity, int outlineColor}) _styleForTile(
    GameTile tile, {
    required bool isCurrent,
  }) {
    final now = DateTime.now();
    final isProtected =
        tile.protectedUntil != null && tile.protectedUntil!.isAfter(now);

    // In launch-entry mode, off-corridor tiles are desaturated and ghosted.
    // Own captures are never muted so the player always sees their progress.
    // Use displayHexes (core + 1-ring expansion) so edge-of-trail enemy
    // captures also render with full colour.
    final isOwn = tile.ownership == TileOwnership.mine;
    final onCorridor = LaunchCorridor.displayHexes.contains(
      tile.h3Index.toLowerCase(),
    );
    final mute = launchEntryMode && !isOwn && !onCorridor;

    final fillColor = mute
        ? _mutedFillColor
        : switch (tile.ownership) {
            TileOwnership.mine =>
              isProtected ? _colorMineProtected : _colorMineExpired,
            TileOwnership.enemy =>
              isProtected ? _colorEnemyProtected : _colorEnemyCapturable,
            TileOwnership.neutral => _colorNeutral,
          };

    final baseOpacity = switch (tile.ownership) {
      TileOwnership.mine =>
        isCurrent ? (isProtected ? 0.52 : 0.42) : (isProtected ? 0.55 : 0.45),
      TileOwnership.enemy =>
        isCurrent ? (isProtected ? 0.50 : 0.40) : (isProtected ? 0.45 : 0.35),
      TileOwnership.neutral => isCurrent ? 0.48 : 0.30,
    };
    final opacity = mute ? baseOpacity * _mutedOpacityScale : baseOpacity;

    final baseOutline = mute
        ? _mutedOutlineColor
        : switch (tile.ownership) {
            TileOwnership.enemy =>
              isProtected ? _outlineColor : _enemyCapturableOutlineColor,
            _ => _outlineColor,
          };

    final outlineColor = isCurrent
        ? (mute ? _mutedCurrentOutlineColor : _currentOutlineColor)
        : baseOutline;

    return (fillColor: fillColor, opacity: opacity, outlineColor: outlineColor);
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

    // Corridor lane is created first so it renders below everything.
    _corridorMgr ??= await _map!.annotations.createPolygonAnnotationManager();
    // Trail polyline sits on top of the corridor lane but under tiles.
    _trailLineMgr ??= await _map!.annotations.createPolylineAnnotationManager();
    // Active-hex halo sits BENEATH the current hex so the main fill stays
    // crisp on top of the pulsing glow wash.
    _currentHaloMgr ??= await _map!.annotations
        .createPolygonAnnotationManager();
    _currentMgr ??= await _map!.annotations.createPolygonAnnotationManager();
    _capturedMgr ??= await _map!.annotations.createPolygonAnnotationManager();
    _selectionMgr ??= await _map!.annotations.createPolygonAnnotationManager();
    // Halo must be created before ring so ring renders on top.
    _recommendationHaloMgr ??= await _map!.annotations
        .createPolygonAnnotationManager();
    _recommendationMgr ??= await _map!.annotations
        .createPolygonAnnotationManager();
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
      final now = DateTime.now();
      _visibleCapturedState[hexLower] = (
        ownership: tile.ownership,
        isProtected:
            tile.protectedUntil != null && tile.protectedUntil!.isAfter(now),
      );
    } else {
      if (!_visibleCapturedHex.contains(hexLower)) return;

      final poly = _capturedPolyByHex[hexLower];
      if (poly != null) {
        await _capturedMgr!.delete(poly);
        _capturedPolyByHex.remove(hexLower);
      }
      _visibleCapturedHex.remove(hexLower);
      _visibleCapturedState.remove(hexLower);
    }
  }

  /// Re-draw an already-visible hex if its ownership or protection changed.
  Future<void> _updateCapturedIfChanged(GameTile tile) async {
    final hexLower = tile.h3Index.toLowerCase();
    final prev = _visibleCapturedState[hexLower];
    if (prev == null) return; // not visible — nothing to update

    final now = DateTime.now();
    final isProtected =
        tile.protectedUntil != null && tile.protectedUntil!.isAfter(now);

    if (prev.ownership == tile.ownership && prev.isProtected == isProtected) {
      return; // no change
    }

    // Delete old polygon and re-create with updated style.
    await setCapturedVisible(tile, false);
    await setCapturedVisible(tile, true);
  }

  /// Force-redraw a single hex with updated tile data.
  ///
  /// Called immediately after a confirmed capture so the tile turns green
  /// without waiting for the next periodic refresh cycle.
  Future<void> forceRedrawHex(GameTile tile) async {
    final hexLower = tile.h3Index.toLowerCase();
    if (_visibleCapturedHex.contains(hexLower)) {
      await setCapturedVisible(tile, false);
      await setCapturedVisible(tile, true);
    } else {
      await setCapturedVisible(tile, true);
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
    _visibleCapturedState.remove(hexLower);
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
  ///
  /// Hexes listed in [alwaysVisibleHexes] bypass the distance check so
  /// trail ownership is visible regardless of the user's position.
  Future<void> updateVisibleCapturedTiles({
    required double centerLat,
    required double centerLng,
    required double radiusMeters,
    required List<GameTile> tiles,
    Set<String>? alwaysVisibleHexes,
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
        // Corridor hexes with ownership always render.
        if (alwaysVisibleHexes != null &&
            alwaysVisibleHexes.contains(hexLower)) {
          shouldBeVisible.add(hexLower);
          continue;
        }
        final cell = BigInt.parse(hexLower, radix: 16);
        final c = cellCentroid(cell, hexLower);
        if (haversineMeters(centerLat, centerLng, c.lat, c.lng) <=
            radiusMeters) {
          shouldBeVisible.add(hexLower);
        }
      } catch (_) {}
    }

    // Update ownership/protection for already-visible hexes.
    for (final hex in shouldBeVisible.intersection(_visibleCapturedHex)) {
      final tile = tileByHex[hex];
      if (tile != null) {
        await _updateCapturedIfChanged(tile);
      }
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
    Set<String>? alwaysVisibleHexes,
  }) async {
    final hexBigInt = BigInt.parse(currentHex, radix: 16);
    final center = cellCentroid(hexBigInt, currentHex);

    await updateVisibleCapturedTiles(
      centerLat: center.lat,
      centerLng: center.lng,
      radiusMeters: radiusMeters,
      tiles: tiles,
      alwaysVisibleHexes: alwaysVisibleHexes,
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
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint(
          'MapRenderService.drawRecommendedHex failed for $h3Index: $error',
        );
        debugPrintStack(stackTrace: stackTrace);
      }
    }
  }

  /// Removes the selection ring added by [drawSelectionHex].
  Future<void> clearSelectionHex() async {
    if (_selectionPoly == null || _selectionMgr == null) return;
    await _selectionMgr!.delete(_selectionPoly!);
    _selectionPoly = null;
  }

  // ── Corridor lane (active trail highlight) ──

  static const int _corridorLaneColor = 0xFF49D6FF; // cyan, same family as glow
  static const int _corridorLaneOutline =
      0xFF2EC4E6; // brighter outline for active feel
  static const double _corridorLaneOpacity =
      0.25; // prominent enough to anchor the trail visually

  /// Draw the active launch corridor as a subtle lane overlay.
  ///
  /// Each hex is drawn with very low opacity so the trail path is visible
  /// without dominating captured/glow annotations.
  Future<void> drawCorridorLane(List<String> hexes) async {
    if (_corridorLaneDrawn) return;
    await _ensureManagers();
    if (_corridorMgr == null) return;

    for (final hex in hexes) {
      try {
        final cell = BigInt.parse(hex, radix: 16);
        final opts = _polygonOptionsForCell(
          cell,
          fillColor: _corridorLaneColor,
          outlineColor: _corridorLaneOutline,
          opacity: _corridorLaneOpacity,
        );
        final poly = await _corridorMgr!.create(opts);
        _corridorPolys.add(poly);
      } catch (_) {}
    }
    _corridorLaneDrawn = true;
  }

  /// Remove the corridor lane overlay.
  Future<void> clearCorridorLane() async {
    if (!_corridorLaneDrawn || _corridorMgr == null) return;
    for (final poly in _corridorPolys) {
      try {
        await _corridorMgr!.delete(poly);
      } catch (_) {}
    }
    _corridorPolys.clear();
    _corridorLaneDrawn = false;
  }

  // accentPrimary cyan: 0xFF49D6FF
  static const int _accentPrimaryCyan = 0xFF49D6FF;
  static const int _accentPrimaryCyanMuted = 0xFF2BAFD4;

  // ── Trail polyline overlay ──

  /// Color & width for the always-on trail guide line.
  /// Uses the same cyan family as the corridor lane / glow so the player
  /// reads them as one continuous "this is your trail" anchor.
  static const int _trailLineColor = 0xFF49D6FF;
  static const double _trailLineWidth = 3.5;
  static const double _trailLineOpacity = 0.55;
  static const double _trailLineBlur = 1.5;

  /// Draws a thin glowing polyline along the active trail.  Idempotent:
  /// subsequent calls are no-ops once drawn.
  ///
  /// Accepts one or more disjoint segments; each segment is rendered as its
  /// own polyline so we never bridge a long gap with a straight chord (e.g.
  /// across water at sharp waterfront curves).  The polyline anchors the
  /// player's mental model so the recommended hex always reads as "the next
  /// step on the line" rather than a hex floating in space.
  Future<void> drawTrailPolyline(
    List<List<({double lat, double lng})>> segments,
  ) async {
    if (_trailLineDrawn) return;
    final usable = segments.where((s) => s.length >= 2).toList();
    if (usable.isEmpty) return;
    await _ensureManagers();
    if (_trailLineMgr == null) return;

    try {
      for (final seg in usable) {
        final coordinates = seg
            .map((p) => mb.Position(p.lng, p.lat))
            .toList(growable: false);
        final opts = mb.PolylineAnnotationOptions(
          geometry: mb.LineString(coordinates: coordinates),
          lineColor: _trailLineColor,
          lineWidth: _trailLineWidth,
          lineOpacity: _trailLineOpacity,
          lineBlur: _trailLineBlur,
          lineJoin: mb.LineJoin.ROUND,
        );
        final line = await _trailLineMgr!.create(opts);
        _trailLines.add(line);
      }
      _trailLineDrawn = true;
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('MapRenderService.drawTrailPolyline failed: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
    }
  }

  /// Removes the trail polyline overlay (if drawn).
  Future<void> clearTrailPolyline() async {
    if (!_trailLineDrawn || _trailLineMgr == null) return;
    for (final line in _trailLines) {
      try {
        await _trailLineMgr!.delete(line);
      } catch (_) {}
    }
    _trailLines.clear();
    _trailLineDrawn = false;
  }

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
      _recommendationHaloPoly = await _recommendationHaloMgr!.create(
        haloOptions,
      );

      // ── Layer 2: bright ring (on top of halo) ───────────────────────────
      // Strong fill + vivid outline — makes the tile unmistakable as the
      // first-action target even against a dark map background.
      final ringOpacity = strong
          ? (pulseOn ? 0.38 : 0.18)
          : (pulseOn ? 0.22 : 0.10);
      final ringOutline = pulseOn
          ? _accentPrimaryCyan
          : _accentPrimaryCyanMuted;
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

  // ── Active-hex halo (player's currently-occupied hex) ──────────────────
  //
  // Glow wash drawn beneath the current-hex annotation.  The map screen
  // toggles [pulseOn] on a slow timer (~1Hz) to produce a calm breathing
  // effect.  Cheap: one delete + one create per tick on a single annotation.
  // Caller is responsible for gating (trail-only, session-active, foreground).
  Future<void> drawActiveHexHalo(
    String h3IndexLower, {
    required bool pulseOn,
  }) async {
    await _ensureManagers();
    if (_currentHaloMgr == null) return;

    if (_currentHaloPoly != null) {
      try {
        await _currentHaloMgr!.delete(_currentHaloPoly!);
      } catch (_) {}
      _currentHaloPoly = null;
    }

    try {
      final cell = BigInt.parse(h3IndexLower, radix: 16);
      // Soft green glow that breathes between barely-visible and warm.
      // Same hue family as the player-owned tile fill so it reads as
      // "your standing tile" rather than as an alert/recommendation.
      final opacity = pulseOn ? 0.55 : 0.20;
      final options = _polygonOptionsForCell(
        cell,
        fillColor: _colorMineProtected,
        outlineColor: _colorMineProtected, // blend outline into fill
        opacity: opacity,
      );
      _currentHaloPoly = await _currentHaloMgr!.create(options);
    } catch (_) {
      // Swallow — halo is purely decorative; main render path is unaffected.
    }
  }

  Future<void> clearActiveHexHalo() async {
    if (_currentHaloPoly == null || _currentHaloMgr == null) return;
    try {
      await _currentHaloMgr!.delete(_currentHaloPoly!);
    } catch (_) {}
    _currentHaloPoly = null;
  }

  void dispose() {
    _recommendationHaloPoly = null;
    _recommendationPoly = null;
    _selectionPoly = null;
    _currentPoly = null;
    _currentHaloPoly = null;
    _capturedPolyByHex.clear();
    _visibleCapturedHex.clear();
  }
}
