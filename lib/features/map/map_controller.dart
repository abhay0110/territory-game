import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:h3_flutter/h3_flutter.dart' as h3lib;

import '../../models/game_tile.dart';
import '../../src/data/services/capture_service.dart';
import '../../src/data/services/location_service.dart';
import '../../src/data/services/map_render_service.dart';

class MapController {
  static const double maxAllowedAccuracyMeters = 30;
  static const double maxCaptureDistanceMeters = 80;
  static const double defaultCameraZoom = 15.2;
  static const int defaultCameraDurationMs = 650;
  static const Duration defaultRefreshInterval = Duration(seconds: 15);
  static const double simulationStepMeters = 260;
  static const double simulationLngOffset = 0.0020;
  static const geo.LocationSettings defaultTrackingSettings =
      geo.LocationSettings(
        accuracy: geo.LocationAccuracy.high,
        distanceFilter: 15,
      );

  final LocationService locationService;
  final CaptureService captureService;
  final MapRenderService mapRenderService;
  final h3lib.H3 _h3 = const h3lib.H3Factory().load();

  MapController({
    required this.locationService,
    required this.captureService,
    required this.mapRenderService,
  });

  String? get currentUserId => captureService.currentUserId;

  Future<MapBootstrapResult> initialize() async {
    await captureService.loadFromPrefs();

    try {
      await captureService.ensureSignedIn();
      final uid = captureService.currentUserId;
      if (uid != null) {
        await captureService.loadFromSupabase(uid);
      }
      return const MapBootstrapResult(synced: true);
    } catch (error) {
      return MapBootstrapResult(synced: false, error: error);
    }
  }

  MapCameraUpdate? buildCameraUpdate(
    double latitude,
    double longitude, {
    required bool moveCamera,
  }) {
    if (!moveCamera) return null;

    return MapCameraUpdate(
      latitude: latitude,
      longitude: longitude,
      zoom: defaultCameraZoom,
      durationMs: defaultCameraDurationMs,
    );
  }

  Future<MapRefreshResult> refreshMapForCoordinates(
    double latitude,
    double longitude, {
    double radiusMeters = 1500,
    int nearbyRingSize = 7,
    bool includePreviewEnemyTiles = true,
  }) async {
    final currentHex = await captureService.getCurrentHexForPosition(
      latitude,
      longitude,
    );

    await captureService.refreshNearbyOwnersForHex(
      currentHex,
      ringSize: nearbyRingSize,
    );

    final capturedTiles = await captureService.getCapturedTilesForCurrentUser();
    final nearbyTiles = await captureService.getNearbyTiles();
    final currentCell = BigInt.parse(currentHex, radix: 16);
    final neighborHexes = _h3
        .gridDisk(currentCell, nearbyRingSize)
        .map((c) => c.toRadixString(16).toLowerCase())
        .toList();

    final tileByHex = <String, GameTile>{
      for (final tile in capturedTiles) tile.h3Index.toLowerCase(): tile,
      for (final tile in nearbyTiles) tile.h3Index.toLowerCase(): tile,
    };

    for (final hex in neighborHexes) {
      tileByHex.putIfAbsent(
        hex,
        () => GameTile(h3Index: hex, ownership: TileOwnership.neutral),
      );
    }

    if (includePreviewEnemyTiles &&
        !tileByHex.values.any((t) => t.ownership == TileOwnership.enemy)) {
      final previewHexes = neighborHexes
          .where((hex) {
            if (hex == currentHex) return false;
            final tile = tileByHex[hex];
            return tile != null && tile.ownership == TileOwnership.neutral;
          })
          .take(3);

      final now = DateTime.now();
      for (final hex in previewHexes) {
        tileByHex[hex] = GameTile(
          h3Index: hex,
          ownership: TileOwnership.enemy,
          ownerId: '__preview_rival__',
          capturedAt: now.subtract(const Duration(minutes: 20)),
          lastRefreshedAt: now.subtract(const Duration(minutes: 1)),
          protectedUntil: now.add(const Duration(minutes: 30)),
        );
      }
    }

    final visibleTiles = tileByHex.values.toList();
    final currentTile = visibleTiles.cast<GameTile?>().firstWhere(
      (tile) => tile?.h3Index == currentHex,
      orElse: () =>
          GameTile(h3Index: currentHex, ownership: TileOwnership.neutral),
    )!;
    final isCaptured = currentTile.ownership == TileOwnership.mine;

    await mapRenderService.drawCurrentTile(currentTile);

    await mapRenderService.updateVisibleCapturedTilesByHex(
      currentHex: currentHex,
      tiles: visibleTiles,
      radiusMeters: radiusMeters,
    );

    return MapRefreshResult(
      currentHex: currentHex,
      capturedTiles: capturedTiles,
      visibleTiles: visibleTiles,
      currentTile: currentTile,
      isCaptured: isCaptured,
    );
  }

  Future<MapRefreshResult> refreshMapForPosition(geo.Position position) async {
    return refreshMapForCoordinates(position.latitude, position.longitude);
  }

  Future<geo.Position?> getCurrentPosition(BuildContext context) async {
    final ok = await locationService.ensurePermission(context: context);
    if (!ok) return null;
    return locationService.getCurrentPosition();
  }

  Future<StreamSubscription<geo.Position>?> startTracking({
    required BuildContext context,
    required Future<void> Function(geo.Position position) onPosition,
    required void Function(Object error) onError,
    geo.LocationSettings settings = defaultTrackingSettings,
  }) async {
    final ok = await locationService.ensurePermission(context: context);
    if (!ok) return null;

    return locationService.getPositionStream(settings: settings).listen((
      position,
    ) async {
      await onPosition(position);
    }, onError: onError);
  }

  Future<void> stopTracking(
    StreamSubscription<geo.Position>? subscription,
  ) async {
    await subscription?.cancel();
  }

  Timer startPeriodicRefresh({
    required Future<void> Function() onRefresh,
    Duration interval = defaultRefreshInterval,
  }) {
    return Timer.periodic(interval, (_) {
      unawaited(onRefresh());
    });
  }

  Future<SimulatedMoveResult?> nextSimulatedMove({
    BuildContext? context,
    required int currentStep,
    double? baseLat,
    double? baseLng,
  }) async {
    var resolvedBaseLat = baseLat;
    var resolvedBaseLng = baseLng;
    var resolvedStep = currentStep;

    if (resolvedBaseLat == null || resolvedBaseLng == null) {
      if (context == null) return null;
      final position = await getCurrentPosition(context);
      if (position == null) return null;

      resolvedBaseLat = position.latitude;
      resolvedBaseLng = position.longitude;
      resolvedStep = 0;
    }

    const dLat = simulationStepMeters / 111000.0;
    final nextStep = resolvedStep + 1;

    return SimulatedMoveResult(
      baseLat: resolvedBaseLat,
      baseLng: resolvedBaseLng,
      step: nextStep,
      latitude: resolvedBaseLat + (nextStep * dLat),
      longitude:
          resolvedBaseLng +
          (nextStep.isEven ? simulationLngOffset : -simulationLngOffset),
      accuracy: 5.0,
      stepMeters: simulationStepMeters,
    );
  }

  Future<CaptureAttemptResult> captureTile({
    required String currentHex,
    required double latitude,
    required double longitude,
    required double? accuracy,
    String? userId,
  }) async {
    final existingTile = captureService.getTileByHex(currentHex);
    final now = DateTime.now();

    if (existingTile != null &&
        existingTile.ownership == TileOwnership.enemy &&
        existingTile.protectedUntil != null &&
        existingTile.protectedUntil!.isAfter(now)) {
      return CaptureAttemptResult(
        status: CaptureAttemptStatus.protectedByRival,
        protectedUntil: existingTile.protectedUntil,
      );
    }

    if (accuracy == null || accuracy > maxAllowedAccuracyMeters) {
      return CaptureAttemptResult(
        status: CaptureAttemptStatus.lowAccuracy,
        accuracy: accuracy,
      );
    }

    final cell = BigInt.parse(currentHex, radix: 16);
    final centroid = mapRenderService.cellCentroid(cell, currentHex);
    final distanceToCenter = MapRenderService.haversineMeters(
      latitude,
      longitude,
      centroid.lat,
      centroid.lng,
    );

    if (distanceToCenter > maxCaptureDistanceMeters) {
      return CaptureAttemptResult(
        status: CaptureAttemptStatus.tooFarFromCenter,
        distanceToCenter: distanceToCenter,
      );
    }

    final captureResult = await captureService.captureTile(currentHex);

    final status = switch (existingTile?.ownership) {
      TileOwnership.mine => CaptureAttemptStatus.protectionRefreshed,
      TileOwnership.enemy => CaptureAttemptStatus.takeoverCaptured,
      _ => CaptureAttemptStatus.captured,
    };

    return CaptureAttemptResult(
      status: status,
      synced: captureResult.synced,
      protectedUntil: captureResult.tile.protectedUntil,
    );
  }

  Future<CaptureFlowResult> captureAndRefreshForCoordinates({
    required String currentHex,
    required double latitude,
    required double longitude,
    required double? accuracy,
    String? userId,
    double radiusMeters = 1500,
    int nearbyRingSize = 7,
    bool includePreviewEnemyTiles = true,
  }) async {
    final captureAttempt = await captureTile(
      currentHex: currentHex,
      latitude: latitude,
      longitude: longitude,
      accuracy: accuracy,
      userId: userId,
    );

    if (!captureAttempt.didCapture) {
      return CaptureFlowResult(captureAttempt: captureAttempt);
    }

    final refresh = await refreshMapForCoordinates(
      latitude,
      longitude,
      radiusMeters: radiusMeters,
      nearbyRingSize: nearbyRingSize,
      includePreviewEnemyTiles: includePreviewEnemyTiles,
    );

    return CaptureFlowResult(captureAttempt: captureAttempt, refresh: refresh);
  }
}

enum CaptureAttemptStatus {
  captured,
  takeoverCaptured,
  protectionRefreshed,
  lowAccuracy,
  tooFarFromCenter,
  protectedByRival,
}

class CaptureAttemptResult {
  final CaptureAttemptStatus status;
  final double? accuracy;
  final double? distanceToCenter;
  final bool synced;
  final DateTime? protectedUntil;

  const CaptureAttemptResult({
    required this.status,
    this.accuracy,
    this.distanceToCenter,
    this.synced = false,
    this.protectedUntil,
  });

  bool get didCapture =>
      status == CaptureAttemptStatus.captured ||
      status == CaptureAttemptStatus.takeoverCaptured ||
      status == CaptureAttemptStatus.protectionRefreshed;
}

class CaptureFlowResult {
  final CaptureAttemptResult captureAttempt;
  final MapRefreshResult? refresh;

  const CaptureFlowResult({required this.captureAttempt, this.refresh});
}

class MapBootstrapResult {
  final bool synced;
  final Object? error;

  const MapBootstrapResult({required this.synced, this.error});
}

class MapCameraUpdate {
  final double latitude;
  final double longitude;
  final double zoom;
  final int durationMs;

  const MapCameraUpdate({
    required this.latitude,
    required this.longitude,
    required this.zoom,
    required this.durationMs,
  });
}

class MapRefreshResult {
  final String currentHex;
  final List<GameTile> capturedTiles;
  final List<GameTile> visibleTiles;
  final GameTile currentTile;
  final bool isCaptured;

  MapRefreshResult({
    required this.currentHex,
    required this.capturedTiles,
    required this.visibleTiles,
    required this.currentTile,
    required this.isCaptured,
  });
}

class SimulatedMoveResult {
  final double baseLat;
  final double baseLng;
  final int step;
  final double latitude;
  final double longitude;
  final double accuracy;
  final double stepMeters;

  const SimulatedMoveResult({
    required this.baseLat,
    required this.baseLng,
    required this.step,
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.stepMeters,
  });
}
