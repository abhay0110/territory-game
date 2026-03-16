import 'trail_progress.dart';

class TrailSectionDefinition {
  final String id;
  final String trailId;
  final String trailName;
  final String name;
  final int startIndex;
  final int endIndex;
  final List<String> orderedH3Indexes;

  const TrailSectionDefinition({
    required this.id,
    required this.trailId,
    required this.trailName,
    required this.name,
    required this.startIndex,
    required this.endIndex,
    required this.orderedH3Indexes,
  });

  int get totalTiles => orderedH3Indexes.length;
}

enum SectionControlState {
  you,
  rival,
  contested,
  unclaimed,
}

class TrailSectionProgress {
  final TrailSectionDefinition section;
  final int ownedTiles;
  final int rivalTiles;
  final String? leadingOwnerId;
  final int tilesToTakeControl;
  final int tilesToLoseControl;
  final bool isAtRisk;
  final bool canFlipWithNextCapture;
  final int longestOwnedSegmentTiles;
  final int projectedOwnedSegmentTiles;
  final int projectedGainTiles;
  final String? bestNextTileH3;
  final double? bestNextTileDistanceMeters;
  final TrailNextTileReason? bestNextTileReason;
  final String? nearestMissingTileHex;
  final double? nearestMissingTileDistanceMeters;
  final SectionControlState controlState;

  const TrailSectionProgress({
    required this.section,
    required this.ownedTiles,
    required this.rivalTiles,
    required this.leadingOwnerId,
    required this.tilesToTakeControl,
    required this.tilesToLoseControl,
    required this.isAtRisk,
    required this.canFlipWithNextCapture,
    required this.longestOwnedSegmentTiles,
    required this.projectedOwnedSegmentTiles,
    required this.projectedGainTiles,
    required this.controlState,
    this.bestNextTileH3,
    this.bestNextTileDistanceMeters,
    this.bestNextTileReason,
    this.nearestMissingTileHex,
    this.nearestMissingTileDistanceMeters,
  });

  int get totalTiles => section.totalTiles;

  bool get isComplete => ownedTiles >= totalTiles && totalTiles > 0;

  double get completionPercent {
    if (totalTiles <= 0) return 0;
    return (ownedTiles / totalTiles) * 100.0;
  }
}
