import 'package:geolocator/geolocator.dart';

import '../../models/game_tile.dart';
import '../../src/data/services/capture_service.dart';
import '../../src/data/services/location_service.dart';
import '../../src/data/services/map_render_service.dart';

class MapController {
  final LocationService locationService;
  final CaptureService captureService;
  final MapRenderService mapRenderService;

  MapController({
    required this.locationService,
    required this.captureService,
    required this.mapRenderService,
  });

  Future<MapRefreshResult> refreshMapForPosition(Position position) async {
    final currentHex = await captureService.getCurrentHexForPosition(
      position.latitude,
      position.longitude,
    );

    final capturedTiles = await captureService.getCapturedTilesForCurrentUser();

    await mapRenderService.drawCurrentTile(currentHex);

    await mapRenderService.updateVisibleCapturedTilesByHex(
      currentHex: currentHex,
      capturedTiles: capturedTiles,
    );

    return MapRefreshResult(
      currentHex: currentHex,
      capturedTiles: capturedTiles,
    );
  }
}

class MapRefreshResult {
  final String currentHex;
  final List<GameTile> capturedTiles;

  MapRefreshResult({
    required this.currentHex,
    required this.capturedTiles,
  });
}
