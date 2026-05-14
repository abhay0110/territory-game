import 'package:flutter/material.dart';

import '../../data/services/trail_leaderboard_service.dart';

/// Between-session "battlefield intelligence" card surfaced on the home
/// screen.  Shows up to two of:
///   - 📈 tiles needed to overtake the player above you in rank
///   - ⚔️ top rival's territory size for context
///
/// Hidden entirely (returns [SizedBox.shrink]) when no signal is
/// available — fresh installs and unranked players see nothing.
/// Tapping the card opens the trail leaderboard sheet.
///
/// Pure presentational widget: all data must be supplied by the caller.
/// Intentionally fail-safe — any unexpected state collapses to
/// [SizedBox.shrink] so a bad snapshot never breaks the home screen.
class TerritoryPressureCard extends StatelessWidget {
  final TrailLeaderboardSnapshot? leaderboard;
  final VoidCallback? onTap;

  const TerritoryPressureCard({
    super.key,
    required this.leaderboard,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    try {
      final snapshot = leaderboard;
      if (snapshot == null) return const SizedBox.shrink();

      final rows = <Widget>[];

      // Indicator 1: Rank gap — only when the player is on the board
      // (yourRank != null), not already #1, and the player above is in
      // the returned topPlayers list.
      final yourRank = snapshot.yourRank;
      if (yourRank != null &&
          yourRank > 1 &&
          snapshot.topPlayers.length >= yourRank) {
        final above = snapshot.topPlayers[yourRank - 2];
        final gap = above.ownedTiles - snapshot.yourTotalTiles + 1;
        if (gap > 0) {
          rows.add(_PressureRow(
            icon: '📈',
            text: '$gap tiles to overtake ${above.displayName}',
            color: const Color(0xFF00C896),
          ));
        }
      }

      // Indicator 2: Top rival — first non-you entry in topPlayers,
      // shown for context even when the player is unranked.
      if (snapshot.topPlayers.length > 1) {
        TrailLeaderboardEntry? rival;
        for (final entry in snapshot.topPlayers) {
          if (!entry.isYou) {
            rival = entry;
            break;
          }
        }
        if (rival != null) {
          rows.add(_PressureRow(
            icon: '⚔️',
            text:
                '${rival.displayName} leads with ${rival.ownedTiles} tiles',
            color: const Color(0xFFDC2626),
          ));
        }
      }

      if (rows.isEmpty) return const SizedBox.shrink();

      final card = Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF111827),
          border: Border.all(color: const Color(0xFF1F2937)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (int i = 0; i < rows.length; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              rows[i],
            ],
          ],
        ),
      );

      if (onTap == null) return card;
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: card,
      );
    } catch (_) {
      return const SizedBox.shrink();
    }
  }
}

class _PressureRow extends StatelessWidget {
  final String icon;
  final String text;
  final Color color;

  const _PressureRow({
    required this.icon,
    required this.text,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(icon, style: const TextStyle(fontSize: 14)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 13,
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}
