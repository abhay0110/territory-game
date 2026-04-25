import 'package:flutter/material.dart';

import '../../../core/theme/game_ui_tokens.dart';
import '../../data/services/player_stats_service.dart';
import 'frosted_overlay_card.dart';

/// Opens the player stats bottom sheet.
Future<void> showPlayerStatsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black54,
    builder: (context) => const _PlayerStatsSheet(),
  );
}

class _PlayerStatsSheet extends StatefulWidget {
  const _PlayerStatsSheet();

  @override
  State<_PlayerStatsSheet> createState() => _PlayerStatsSheetState();
}

class _PlayerStatsSheetState extends State<_PlayerStatsSheet> {
  PlayerStats? _stats;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final stats = await PlayerStatsService().loadStats();
    if (!mounted) return;
    setState(() {
      _stats = stats;
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
                    const Text('⬡', style: TextStyle(fontSize: 18)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'YOUR HEXTRAIL RECORD',
                        style: GameUiText.command(
                          color: GameUiTokens.accentPrimary,
                          size: 14,
                          letterSpacing: 1.2,
                        ),
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
              Expanded(
                child: _loading
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(32),
                          child: CircularProgressIndicator(
                            color: GameUiTokens.accentPrimary,
                            strokeWidth: 2,
                          ),
                        ),
                      )
                    : _buildStats(scrollController),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildStats(ScrollController scrollController) {
    final s = _stats!;
    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      children: [
        // ── Player summary ──
        _SectionHeader(label: 'TERRITORY'),
        const SizedBox(height: 10),
        Row(
          children: [
            _BigStat(value: '${s.totalHexesCaptured}', label: 'Hexes owned'),
            const SizedBox(width: 12),
            _BigStat(
              value: '${s.trailCompletionPercent.toStringAsFixed(1)}%',
              label: s.trailName ?? 'Trail',
            ),
          ],
        ),
        if (s.sectionsControlled > 0) ...[
          const SizedBox(height: 8),
          _StatRow(
            label: 'Sections controlled',
            value: '${s.sectionsControlled}',
          ),
        ],
        const SizedBox(height: 20),

        // ── Personal bests ──
        _SectionHeader(label: 'PERSONAL BESTS'),
        const SizedBox(height: 10),
        Row(
          children: [
            _BigStat(
              value: '${s.longestTrailStreak}',
              label: 'Longest streak',
            ),
            const SizedBox(width: 12),
            _BigStat(
              value: '${s.bestDayCaptures}',
              label: 'Best day',
            ),
            if (s.bestSessionCaptures > 0) ...[              const SizedBox(width: 12),
              _BigStat(
                value: '${s.bestSessionCaptures}',
                label: 'Best session',
              ),
            ],
          ],
        ),
        if (s.bestDayDate != null) ...[
          const SizedBox(height: 4),
          Text(
            s.bestDayDate!,
            style: GameUiText.meta(
              color: GameUiTokens.textLow,
              size: 11,
            ),
          ),
        ],
        const SizedBox(height: 20),

        // ── Activity ──
        _SectionHeader(label: 'ACTIVITY'),
        const SizedBox(height: 10),
        if (s.dayStreak > 0) ...[          _StatRow(label: 'Day streak', value: '${s.dayStreak} day${s.dayStreak == 1 ? '' : 's'}'),
          const SizedBox(height: 6),
        ],
        if (s.daysActive > 0) ...[          _StatRow(label: 'Days active', value: '${s.daysActive}'),
          const SizedBox(height: 6),
        ],
        _StatRow(label: 'Sessions', value: '${s.totalSessions}'),
        if (s.totalDistanceMeters > 0) ...[
          const SizedBox(height: 6),
          _StatRow(
            label: 'Total distance',
            value: _formatDistance(s.totalDistanceMeters),
          ),
          if (s.walkRunDistanceMeters > 0 && s.rideDistanceMeters > 0) ...[
            const SizedBox(height: 6),
            _StatRow(
              label: 'Walk / Run',
              value: _formatDistance(s.walkRunDistanceMeters),
            ),
            const SizedBox(height: 6),
            _StatRow(
              label: 'Ride',
              value: _formatDistance(s.rideDistanceMeters),
            ),
          ],
        ],
        if (s.totalSessions > 0 && s.totalHexesCaptured > 0) ...[
          const SizedBox(height: 6),
          _StatRow(
            label: 'Avg hexes / session',
            value: (s.totalHexesCaptured / s.totalSessions)
                .toStringAsFixed(1),
          ),
        ],
      ],
    );
  }

  static String _formatDistance(double meters) {
    if (meters >= 1609.34) {
      return '${(meters / 1609.34).toStringAsFixed(1)} mi';
    }
    return '${meters.toInt()} ft';
  }
}

// ── Reusable stat components ──────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: GameUiText.command(
        color: GameUiTokens.textLow,
        size: 10,
        weight: FontWeight.w700,
        letterSpacing: 1.5,
      ),
    );
  }
}

class _BigStat extends StatelessWidget {
  final String value;
  final String label;
  const _BigStat({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.04),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: GameUiTokens.panelBorder.withOpacity(0.5)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              value,
              style: GameUiText.body(
                color: GameUiTokens.accentSecondary,
                size: 22,
                weight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: GameUiText.meta(
                color: GameUiTokens.textMid,
                size: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  final String label;
  final String value;
  const _StatRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: GameUiText.meta(
            color: GameUiTokens.textMid,
            size: 13,
          ),
        ),
        Text(
          value,
          style: GameUiText.body(
            color: GameUiTokens.textHi,
            size: 14,
            weight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}
