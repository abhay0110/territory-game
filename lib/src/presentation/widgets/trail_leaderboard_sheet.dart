import 'package:flutter/material.dart';

import '../../../core/theme/game_ui_tokens.dart';
import '../../../models/trail_section.dart';
import '../../data/services/trail_leaderboard_service.dart';
import 'frosted_overlay_card.dart';

/// Premium Burke-Gilman leaderboard bottom sheet.
///
/// Fetches data on open and supports pull-to-refresh.
Future<void> showTrailLeaderboardSheet(
  BuildContext context, {
  required TrailLeaderboardService service,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black54,
    builder: (context) => _TrailLeaderboardSheet(service: service),
  );
}

class _TrailLeaderboardSheet extends StatefulWidget {
  final TrailLeaderboardService service;
  const _TrailLeaderboardSheet({required this.service});

  @override
  State<_TrailLeaderboardSheet> createState() => _TrailLeaderboardSheetState();
}

class _TrailLeaderboardSheetState extends State<_TrailLeaderboardSheet> {
  TrailLeaderboardSnapshot? _snapshot;
  bool _loading = true;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _fetchLeaderboard();
  }

  Future<void> _fetchLeaderboard() async {
    if (!_loading) setState(() => _loading = true);
    final result = await widget.service.fetchBurkeGilman();
    if (!mounted) return;
    setState(() {
      _snapshot = result;
      _error = result == null;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.55,
      minChildSize: 0.35,
      maxChildSize: 0.80,
      builder: (context, scrollController) {
        return FrostedOverlayCard(
          emphasized: true,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              // ── Drag handle ──
              Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 6),
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: GameUiTokens.textLow.withOpacity(0.40),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              // ── Header ──
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: Row(
                  children: [
                    Icon(
                      Icons.military_tech,
                      color: GameUiTokens.accentPrimary,
                      size: 22,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _snapshot != null
                            ? _snapshot!.trailName.toUpperCase()
                            : 'BURKE-GILMAN',
                        style: GameUiText.command(
                          color: GameUiTokens.accentPrimary,
                          size: 15,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                    if (_snapshot != null)
                      Text(
                        '${_snapshot!.trailTotalTiles} hexes',
                        style: GameUiText.meta(
                          color: GameUiTokens.textLow,
                          size: 11,
                        ),
                      ),
                  ],
                ),
              ),
              Container(
                height: 1,
                color: GameUiTokens.panelBorder.withOpacity(0.40),
              ),
              // ── Content ──
              Expanded(child: _buildContent(scrollController)),
            ],
          ),
        );
      },
    );
  }

  Widget _buildContent(ScrollController scrollController) {
    if (_loading && _snapshot == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: CircularProgressIndicator(
            color: GameUiTokens.accentPrimary,
            strokeWidth: 2,
          ),
        ),
      );
    }

    if (_error && _snapshot == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Could not load leaderboard.',
                style: GameUiText.body(color: GameUiTokens.textMid, size: 13),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: _fetchLeaderboard,
                child: Text(
                  'RETRY',
                  style: GameUiText.command(
                    color: GameUiTokens.accentPrimary,
                    size: 12,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final snapshot = _snapshot!;
    return RefreshIndicator(
      onRefresh: _fetchLeaderboard,
      color: GameUiTokens.accentPrimary,
      backgroundColor: GameUiTokens.bg1,
      child: ListView(
        controller: scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        children: [
          // ── Your position ──
          if (snapshot.yourRank != null) ...[
            _YourPositionCard(snapshot: snapshot),
            const SizedBox(height: 16),
          ],
          // ── Top Players ──
          Text(
            'TOP PLAYERS',
            style: GameUiText.meta(
              color: GameUiTokens.textLow,
              size: 10,
              weight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          ...List.generate(
            snapshot.topPlayers.length,
            (i) => _PlayerRow(
              rank: i + 1,
              entry: snapshot.topPlayers[i],
              trailTotal: snapshot.trailTotalTiles,
            ),
          ),
          if (snapshot.topPlayers.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'No players on this trail yet.',
                style: GameUiText.meta(color: GameUiTokens.textLow, size: 12),
              ),
            ),
          const SizedBox(height: 20),
          // ── Section Control ──
          Text(
            'SECTION CONTROL',
            style: GameUiText.meta(
              color: GameUiTokens.textLow,
              size: 10,
              weight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          ...snapshot.sections.map((s) => _SectionControlRow(section: s)),
        ],
      ),
    );
  }
}

// ── Your Position Card ──

class _YourPositionCard extends StatelessWidget {
  final TrailLeaderboardSnapshot snapshot;
  const _YourPositionCard({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    final percent = snapshot.trailTotalTiles > 0
        ? (snapshot.yourTotalTiles / snapshot.trailTotalTiles * 100)
              .toStringAsFixed(0)
        : '0';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: GameUiTokens.accentPrimary.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: GameUiTokens.accentPrimary.withOpacity(0.25)),
      ),
      child: Row(
        children: [
          // Rank badge
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: GameUiTokens.accentPrimary.withOpacity(0.15),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              '#${snapshot.yourRank}',
              style: GameUiText.body(
                color: GameUiTokens.accentPrimary,
                size: 12,
                weight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Your Position',
                  style: GameUiText.body(
                    color: GameUiTokens.textHi,
                    size: 13,
                    weight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${snapshot.yourTotalTiles} hexes · $percent% of trail',
                  style: GameUiText.meta(color: GameUiTokens.textMid, size: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Player Row ──

class _PlayerRow extends StatelessWidget {
  final int rank;
  final TrailLeaderboardEntry entry;
  final int trailTotal;

  const _PlayerRow({
    required this.rank,
    required this.entry,
    required this.trailTotal,
  });

  @override
  Widget build(BuildContext context) {
    final isTop3 = rank <= 3;
    final rankColor = switch (rank) {
      1 => const Color(0xFFFFD700),
      2 => const Color(0xFFC0C0C0),
      3 => const Color(0xFFCD7F32),
      _ => GameUiTokens.textLow,
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          // Rank
          SizedBox(
            width: 28,
            child: Text(
              '$rank',
              style: GameUiText.body(
                color: rankColor,
                size: isTop3 ? 14 : 12,
                weight: isTop3 ? FontWeight.w800 : FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(width: 10),
          // Name
          Expanded(
            child: Text(
              entry.displayName,
              style: GameUiText.body(
                color: entry.isYou
                    ? GameUiTokens.accentPrimary
                    : GameUiTokens.textHi,
                size: 13,
                weight: entry.isYou ? FontWeight.w800 : FontWeight.w600,
              ),
            ),
          ),
          // Hex count
          Text(
            '${entry.ownedTiles}',
            style: GameUiText.body(
              color: entry.isYou
                  ? GameUiTokens.accentPrimary
                  : GameUiTokens.textHi,
              size: 13,
              weight: FontWeight.w800,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            'hexes',
            style: GameUiText.meta(color: GameUiTokens.textLow, size: 10),
          ),
        ],
      ),
    );
  }
}

// ── Section Control Row ──

class _SectionControlRow extends StatelessWidget {
  final SectionLeaderSnapshot section;
  const _SectionControlRow({required this.section});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (section.controlState) {
      SectionControlState.you => ('YOU', GameUiTokens.accentSecondary),
      SectionControlState.rival => ('RIVAL', GameUiTokens.danger),
      SectionControlState.contested => ('CONTESTED', GameUiTokens.warning),
      SectionControlState.unclaimed => ('OPEN', GameUiTokens.textLow),
    };

    // Short section name (strip trail name prefix).
    final shortName = section.section.name.replaceFirst(
      RegExp(r'^Burke-Gilman\s+'),
      '',
    );

    final yourPct = section.yourPercent.toStringAsFixed(0);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          // Section name
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  shortName,
                  style: GameUiText.body(
                    color: GameUiTokens.textHi,
                    size: 13,
                    weight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${section.yourTiles} / ${section.totalTiles} hexes · $yourPct%',
                  style: GameUiText.meta(color: GameUiTokens.textMid, size: 10),
                ),
              ],
            ),
          ),
          // Control chip
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: color.withOpacity(0.15),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: color.withOpacity(0.35)),
            ),
            child: Text(
              label,
              style: GameUiText.meta(
                color: color,
                size: 10,
                weight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
