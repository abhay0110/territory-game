import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../data/services/trail_leaderboard_service.dart';

/// Tone of the pressure-card headline. Drives icon + color.
@visibleForTesting
enum PressureTone { defend, chase, breakIn }

/// Pure summary of what the [TerritoryPressureCard] should render for a
/// given leaderboard snapshot. `null` means nothing actionable — card
/// must collapse to [SizedBox.shrink].
@visibleForTesting
@immutable
class PressureCardSummary {
  final PressureTone tone;
  final String headline;
  final String? subline;

  const PressureCardSummary({
    required this.tone,
    required this.headline,
    this.subline,
  });
}

/// Pure state-machine that turns a leaderboard snapshot into the single
/// most actionable headline for this player right now.
///
/// Branches (in evaluation order):
///   * **defend** — `yourRank == 1` and there is a #2 player.
///   * **chase**  — `yourRank >= 2` and the player above is on the
///     returned `topPlayers` list.
///   * **breakIn** — player is unranked (`yourRank == null`) but has at
///     least one captured tile and we know the lowest top-N score.
///   * `null`     — no actionable signal (fresh install, lonely board,
///     malformed snapshot, etc.).
@visibleForTesting
PressureCardSummary? pressureCardSummary(TrailLeaderboardSnapshot? snapshot) {
  if (snapshot == null) return null;
  try {
    final yourRank = snapshot.yourRank;
    final players = snapshot.topPlayers;
    if (players.isEmpty) return null;

    // ── DEFEND: you are #1 ──
    if (yourRank == 1 && players.length >= 2) {
      // The #2 player is the first non-you entry; defensively skip
      // any stray "isYou" rows to avoid a phantom self-rival.
      TrailLeaderboardEntry? second;
      for (final entry in players) {
        if (!entry.isYou) {
          second = entry;
          break;
        }
      }
      if (second == null) return null;
      final lead = snapshot.yourTotalTiles - second.ownedTiles;
      if (lead < 0) return null; // stale/malformed snapshot
      if (lead == 0) {
        // Tied for #1 — the most tense state in the game. Don't go silent;
        // surface it with defend urgency. See /memories/repo/
        // build25_followups.md item #2.
        return PressureCardSummary(
          tone: PressureTone.defend,
          headline:
              'Tied for #1 with ${second.displayName} — capture 1 more '
              'to break it',
        );
      }
      return PressureCardSummary(
        tone: PressureTone.defend,
        headline:
            '#1 by $lead tile${lead == 1 ? '' : 's'} — defend against '
            '${second.displayName}',
      );
    }

    // ── CHASE: you are on the board, not #1 ──
    if (yourRank != null && yourRank > 1 && players.length >= yourRank) {
      final above = players[yourRank - 2];
      final gap = above.ownedTiles - snapshot.yourTotalTiles + 1;
      if (gap <= 0) return null;
      // Add a leader subline only when the chase target is NOT also
      // the leader (rank > 2). Avoids "overtake X" + "X leads" echo.
      String? subline;
      if (yourRank > 2) {
        final leader = players.first;
        if (!leader.isYou) {
          subline =
              '👑 ${leader.displayName} leads with ${leader.ownedTiles}';
        }
      }
      return PressureCardSummary(
        tone: PressureTone.chase,
        headline:
            '$gap tile${gap == 1 ? '' : 's'} to overtake ${above.displayName}',
        subline: subline,
      );
    }

    // ── BREAK-IN: unranked but has tiles ──
    if (yourRank == null && snapshot.yourTotalTiles > 0) {
      final lowestTop = players.last;
      if (lowestTop.isYou) return null;
      final gap = lowestTop.ownedTiles - snapshot.yourTotalTiles + 1;
      if (gap <= 0) return null;
      return PressureCardSummary(
        tone: PressureTone.breakIn,
        headline:
            'Capture $gap more to break into the top ${players.length}',
      );
    }

    return null;
  } catch (_) {
    return null;
  }
}

/// Between-session "battlefield intelligence" card surfaced on the home
/// screen. Renders the headline produced by [pressureCardSummary] — see
/// that helper for the full state machine and edge-case handling.
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
    final summary = pressureCardSummary(leaderboard);
    if (summary == null) return const SizedBox.shrink();

    final (icon, accent) = switch (summary.tone) {
      PressureTone.defend => ('👑', const Color(0xFFF59E0B)),
      PressureTone.chase => ('📈', const Color(0xFF00C896)),
      PressureTone.breakIn => ('🎯', const Color(0xFF60A5FA)),
    };

    final card = Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        border: Border.all(color: accent.withOpacity(0.45)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header chip so the card reads as its own thing, not a
          // stray row repeated from the leaderboard sheet.
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: accent.withOpacity(0.16),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: accent.withOpacity(0.55)),
                ),
                child: Text(
                  'TERRITORY PRESSURE',
                  style: TextStyle(
                    color: accent,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
              const Spacer(),
              if (onTap != null)
                Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: accent.withOpacity(0.75),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(icon, style: const TextStyle(fontSize: 18)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  summary.headline,
                  style: TextStyle(
                    color: accent,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                  ),
                ),
              ),
            ],
          ),
          if (summary.subline != null) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(left: 28),
              child: Text(
                summary.subline!,
                style: const TextStyle(
                  color: Color(0xFF94A3B8),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
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
  }
}
