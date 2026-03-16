class TrailDefinition {
  final String id;
  final String name;
  final List<String> orderedH3Indexes;

  const TrailDefinition({
    required this.id,
    required this.name,
    required this.orderedH3Indexes,
  });

  int get totalTiles => orderedH3Indexes.length;
}

enum TrailNextTileReason {
  extendStreak,
  startTrail,
  bridgeGap,
  nearestMissing,
}

class TrailProgress {
  final TrailDefinition trail;
  final int ownedTiles;
  final int longestOwnedSegmentTiles;
  final int projectedOwnedSegmentTiles;
  final int projectedGainTiles;
  final String? bestNextTileH3;
  final double? bestNextTileDistanceMeters;
  final TrailNextTileReason? bestNextTileReason;
  final String? nearestMissingTileHex;
  final double? nearestMissingTileDistanceMeters;

  const TrailProgress({
    required this.trail,
    required this.ownedTiles,
    required this.longestOwnedSegmentTiles,
    required this.projectedOwnedSegmentTiles,
    required this.projectedGainTiles,
    this.bestNextTileH3,
    this.bestNextTileDistanceMeters,
    this.bestNextTileReason,
    this.nearestMissingTileHex,
    this.nearestMissingTileDistanceMeters,
  });

  int get totalTiles => trail.totalTiles;

  bool get isComplete => ownedTiles >= totalTiles && totalTiles > 0;

  double get completionPercent {
    if (totalTiles <= 0) return 0;
    return (ownedTiles / totalTiles) * 100.0;
  }

  String get label => '${trail.name}: $ownedTiles / $totalTiles tiles';
}
