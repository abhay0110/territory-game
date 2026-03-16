import 'package:flutter/material.dart';

import '../../../models/trail_progress.dart';

class LocalLeaderboardStats {
  final int capturesThisWeek;
  final int currentlyOwned;
  final int longestProtectionStreak;
  final List<TrailProgress> trailProgress;

  const LocalLeaderboardStats({
    required this.capturesThisWeek,
    required this.currentlyOwned,
    required this.longestProtectionStreak,
    required this.trailProgress,
  });
}

Future<void> showLeaderboardDialog(
  BuildContext context, {
  required LocalLeaderboardStats stats,
}) {
  String formatDistance(double meters) {
    if (meters < 1000) return '${meters.toStringAsFixed(0)}m';
    return '${(meters / 1000).toStringAsFixed(2)}km';
  }

  String reasonLabel(TrailNextTileReason? reason) {
    return switch (reason) {
      TrailNextTileReason.extendStreak => 'Extends streak',
      TrailNextTileReason.bridgeGap => 'Bridges gap',
      TrailNextTileReason.startTrail => 'Starts trail',
      TrailNextTileReason.nearestMissing => 'Nearest missing fallback',
      null => 'No objective',
    };
  }

  String projectedLabel(TrailProgress p) {
    if (p.projectedGainTiles > 0) {
      return 'streak becomes ${p.projectedOwnedSegmentTiles} (+${p.projectedGainTiles} tile${p.projectedGainTiles == 1 ? '' : 's'})';
    }
    return 'streak stays ${p.projectedOwnedSegmentTiles}';
  }

  Widget buildTrailRow(TrailProgress p) {
    final progress = (p.completionPercent / 100).clamp(0.0, 1.0).toDouble();
    final percent = p.completionPercent.toStringAsFixed(0);
    final objectiveDistance = p.bestNextTileDistanceMeters == null
      ? '--'
      : formatDistance(p.bestNextTileDistanceMeters!);
    final objectiveLine = p.bestNextTileH3 == null
      ? (p.isComplete ? 'Next objective: complete' : 'Next objective: --')
      : 'Next objective: ${p.trail.name} • $objectiveDistance';
    final nearestFallback = p.nearestMissingTileDistanceMeters == null
      ? '--'
      : formatDistance(p.nearestMissingTileDistanceMeters!);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            p.trail.name,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 2),
          Text('${p.ownedTiles} / ${p.totalTiles} • $percent%'),
          const SizedBox(height: 5),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              height: 7,
              child: LinearProgressIndicator(
                value: progress,
                backgroundColor: Colors.black12,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            objectiveLine,
            style: const TextStyle(fontSize: 12),
          ),
          Text(
            '${reasonLabel(p.bestNextTileReason)} • ${projectedLabel(p)}',
            style: const TextStyle(fontSize: 12),
          ),
          Text(
            'Current longest streak: ${p.longestOwnedSegmentTiles} tiles',
            style: const TextStyle(fontSize: 12),
          ),
          Text(
            'Fallback nearest: $nearestFallback',
            style: const TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }

  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Local Leaderboard'),
      content: SizedBox(
        width: 320,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Tiles captured this week: ${stats.capturesThisWeek}'),
              Text('Tiles currently owned: ${stats.currentlyOwned}'),
              Text('Longest protection streak: ${stats.longestProtectionStreak}'),
              if (stats.trailProgress.isNotEmpty) ...[
                const SizedBox(height: 10),
                const Text(
                  'Trail progress',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                ...stats.trailProgress.map(buildTrailRow),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}
