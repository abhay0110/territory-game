import 'dart:async';

import 'package:flutter/material.dart';

import '../../../models/game_tile.dart';

Future<void> showTileDetailsDialog(
  BuildContext context, {
  required String ownerLabel,
  required String capturedSince,
  required TileOwnership ownership,
  required DateTime? protectedUntil,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => _TileDetailsDialog(
      ownerLabel: ownerLabel,
      capturedSince: capturedSince,
      ownership: ownership,
      protectedUntil: protectedUntil,
    ),
  );
}

class _TileDetailsDialog extends StatefulWidget {
  const _TileDetailsDialog({
    required this.ownerLabel,
    required this.capturedSince,
    required this.ownership,
    required this.protectedUntil,
  });

  final String ownerLabel;
  final String capturedSince;
  final TileOwnership ownership;
  final DateTime? protectedUntil;

  @override
  State<_TileDetailsDialog> createState() => _TileDetailsDialogState();
}

class _TileDetailsDialogState extends State<_TileDetailsDialog> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  String _statusLabel() {
    if (widget.ownership == TileOwnership.neutral) return 'Neutral';
    final until = widget.protectedUntil;
    if (until == null || !until.isAfter(DateTime.now())) return 'Capturable';
    return 'Protected';
  }

  String _remainingProtectionLabel() {
    if (widget.ownership == TileOwnership.neutral) return '--';
    final until = widget.protectedUntil;
    if (until == null) return 'Unknown';

    final remaining = until.difference(DateTime.now());
    if (!remaining.isNegative && remaining.inSeconds > 0) {
      final hours = remaining.inHours;
      final minutes = remaining.inMinutes.remainder(60);
      final seconds = remaining.inSeconds.remainder(60);
      if (hours > 0) {
        return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
      }
      return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '00:00';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Tile Details'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Owner: ${widget.ownerLabel}'),
          const SizedBox(height: 6),
          Text('Status: ${_statusLabel()}'),
          const SizedBox(height: 6),
          Text('Remaining protection: ${_remainingProtectionLabel()}'),
          const SizedBox(height: 6),
          Text('Captured: ${widget.capturedSince}'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('OK'),
        ),
      ],
    );
  }
}
