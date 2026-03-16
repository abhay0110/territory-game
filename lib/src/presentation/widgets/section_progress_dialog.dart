import 'package:flutter/material.dart';

import '../../../models/trail_progress.dart';
import '../../../models/trail_section.dart';

Future<void> showSectionProgressDialog(
  BuildContext context, {
  required List<TrailSectionProgress> sections,
}) {
  String formatDistance(double meters) {
    if (meters < 1000) return '${meters.toStringAsFixed(0)}m';
    return '${(meters / 1000).toStringAsFixed(2)}km';
  }

  String reasonLabel(TrailNextTileReason? reason) {
    return switch (reason) {
      TrailNextTileReason.extendStreak => 'Extends streak',
      TrailNextTileReason.bridgeGap => 'Bridges gap',
      TrailNextTileReason.startTrail => 'Starts section',
      TrailNextTileReason.nearestMissing => 'Nearest missing fallback',
      null => 'No objective',
    };
  }

  String controlLabel(SectionControlState state) {
    return switch (state) {
      SectionControlState.you => 'Controlled by you',
      SectionControlState.rival => 'Rival-controlled',
      SectionControlState.contested => 'Contested',
      SectionControlState.unclaimed => 'Unclaimed',
    };
  }

  String leadingOwnerLabel(String? ownerId) {
    if (ownerId == null || ownerId.isEmpty) return '--';
    if (ownerId == '__local_player__') return 'You';
    final short = ownerId.length > 6 ? ownerId.substring(0, 6) : ownerId;
    return 'Player$short';
  }

  String controlPressureLine(TrailSectionProgress p) {
    if (p.controlState == SectionControlState.contested) {
      return 'Contested section • Next capture flips section';
    }
    if (p.isAtRisk) {
      return '${p.section.name}: at risk';
    }
    if (p.tilesToTakeControl > 0) {
      final plural = p.tilesToTakeControl == 1 ? '' : 's';
      return '${p.tilesToTakeControl} tile$plural to take control';
    }
    if (p.canFlipWithNextCapture) {
      return 'Next capture flips section';
    }
    if (p.tilesToLoseControl > 0) {
      final plural = p.tilesToLoseControl == 1 ? '' : 's';
      return 'Lose lead in ${p.tilesToLoseControl} capture$plural';
    }
    return 'Control stable';
  }

  final ordered = sections.toList()
    ..sort((a, b) {
      final trailCmp = a.section.trailName.compareTo(b.section.trailName);
      if (trailCmp != 0) return trailCmp;
      return a.section.startIndex.compareTo(b.section.startIndex);
    });

  Widget sectionRow(TrailSectionProgress p) {
    final percent = p.completionPercent.toStringAsFixed(0);
    final objectiveDistance = p.bestNextTileDistanceMeters == null
        ? '--'
        : formatDistance(p.bestNextTileDistanceMeters!);
    final objectiveLine = p.bestNextTileH3 == null
        ? (p.isComplete ? 'Next objective: complete' : 'Next objective: --')
        : 'Next objective: ${p.section.name} • $objectiveDistance';

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            p.section.name,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          Text(
            '${p.section.trailName} • ${controlLabel(p.controlState)} • Leader: ${leadingOwnerLabel(p.leadingOwnerId)}',
            style: const TextStyle(fontSize: 12),
          ),
          Text('${p.ownedTiles} / ${p.totalTiles} • $percent%'),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              height: 7,
              child: LinearProgressIndicator(
                value: (p.completionPercent / 100).clamp(0.0, 1.0).toDouble(),
                backgroundColor: Colors.black12,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(objectiveLine, style: const TextStyle(fontSize: 12)),
          Text(
            '${reasonLabel(p.bestNextTileReason)} • streak ${p.longestOwnedSegmentTiles} → ${p.projectedOwnedSegmentTiles} (+${p.projectedGainTiles})',
            style: const TextStyle(fontSize: 12),
          ),
          Text(
            controlPressureLine(p),
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Trail Sections'),
      content: SizedBox(
        width: 340,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (ordered.isEmpty)
                const Text('No section data yet.')
              else
                ...ordered.map(sectionRow),
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
