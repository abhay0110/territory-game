import 'package:flutter/material.dart';

Future<void> showTileDetailsDialog(
  BuildContext context, {
  required String ownerLabel,
  required String capturedSince,
  required String protectionLabel,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Tile Details'),
      content: Text(
        'Owned by $ownerLabel\n'
        'Captured $capturedSince\n'
        '$protectionLabel',
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
