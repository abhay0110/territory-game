import 'package:flutter/material.dart';

import '../../../core/feature_flags.dart';
import '../../../core/theme/game_ui_tokens.dart';
import '../../data/services/badge_service.dart';
import '../../data/services/player_stats_service.dart';
import '../../data/services/streak_service.dart';
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
  StreakState? _streak;
  // Phase 1.4: list is non-null only when the feature flag is on AND
  // the fetch completed.  When the flag is off we never construct
  // BadgeService so no Supabase round-trip is made.
  List<PeriodicBadge>? _badges;
  bool _showFreezeBanner = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final statsFuture = PlayerStatsService().loadStats();
    // Streak load is best-effort: a failure here must not blank out
    // the whole sheet (the streak pill is a header decoration, not
    // load-critical).
    StreakState? streak;
    bool banner = false;
    if (FeatureFlags.streakSystemEnabled) {
      try {
        final svc = StreakService();
        streak = await svc.readCurrentState();
        banner = await svc.consumeFreezeBanner();
      } catch (_) {
        streak = null;
      }
    }
    // Phase 1.4: badges fetch is also best-effort and entirely skipped
    // when the flag is off.  fetchMine() already swallows errors and
    // returns [] on failure, so this never throws.
    List<PeriodicBadge>? badges;
    if (FeatureFlags.periodicBadgesUiEnabled) {
      badges = await BadgeService().fetchMine();
    }
    final stats = await statsFuture;
    if (!mounted) return;
    setState(() {
      _stats = stats;
      _streak = streak;
      _badges = badges;
      _showFreezeBanner = banner;
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
                    if (_StreakPill.shouldShow(_streak, _showFreezeBanner))
                      _StreakPill(
                        state: _streak!,
                        showFreezeUsedBanner: _showFreezeBanner,
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

        // ── Achievements (Phase 1.4) ──
        // Rendered ONLY when the flag is on AND the fetch returned at
        // least one badge.  An empty list silently hides the section
        // so a freshly-installed account doesn't see a placeholder
        // "no achievements yet" line (no-op = invisible).
        if (FeatureFlags.periodicBadgesUiEnabled &&
            _badges != null &&
            _badges!.isNotEmpty) ...[
          const SizedBox(height: 20),
          _SectionHeader(label: 'ACHIEVEMENTS'),
          const SizedBox(height: 10),
          for (final badge in _badges!) ...[
            _AchievementRow(badge: badge),
            const SizedBox(height: 6),
          ],
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

/// One row in the ACHIEVEMENTS section (Phase 1.4).  Permanent badge
/// awarded by the server cron; the row is read-only.
///
/// Layout mirrors `_StatRow` (label-left / value-right) so the section
/// reads as a continuation of the stats list rather than a separate
/// gallery — keeps the sheet visually quiet.
class _AchievementRow extends StatelessWidget {
  final PeriodicBadge badge;
  const _AchievementRow({required this.badge});

  @override
  Widget build(BuildContext context) {
    // Rank-driven medal glyph.  Falls back to the generic trophy for
    // any future ranks beyond top-3.
    final medal = switch (badge.rank) {
      1 => '🥇',
      2 => '🥈',
      3 => '🥉',
      _ => '🏆',
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1, right: 8),
          child: Text(medal, style: const TextStyle(fontSize: 16)),
        ),
        Expanded(
          child: Text(
            badge.label,
            style: GameUiText.body(
              color: GameUiTokens.textHi,
              size: 13,
              weight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

/// Compact streak indicator that lives in the Stats sheet header.
/// Replaces the standalone home-screen StreakCard so the home stays
/// focused on the battle CTA + leaderboard hooks.
///
/// Visibility rule (see [shouldShow]): only render when there is an
/// active streak OR a one-shot freeze-used banner is pending. Avoids
/// surfacing a 0-day pill that reads as failure on fresh installs.
class _StreakPill extends StatelessWidget {
  final StreakState state;
  final bool showFreezeUsedBanner;

  const _StreakPill({
    required this.state,
    required this.showFreezeUsedBanner,
  });

  static bool shouldShow(StreakState? state, bool showFreezeUsedBanner) {
    if (state == null) return false;
    if (state.currentStreak > 0) return true;
    if (showFreezeUsedBanner) return true;
    return false;
  }

  @override
  Widget build(BuildContext context) {
    // Defensive: if shouldShow logic ever drifts from build, render
    // nothing rather than a confusing "0-day" pill.
    if (!shouldShow(state, showFreezeUsedBanner)) {
      return const SizedBox.shrink();
    }

    final accent = showFreezeUsedBanner
        ? const Color(0xFF60A5FA) // blue: freeze-used warning tone
        : const Color(0xFFF59E0B); // amber: active streak tone

    final label = showFreezeUsedBanner
        ? '🧊 freeze used'
        : state.freezesAvailable > 0
            ? '🔥 ${state.currentStreak} • 🧊 1'
            : '🔥 ${state.currentStreak}';

    return Tooltip(
      message: showFreezeUsedBanner
          ? 'Streak freeze used — capture today to keep your '
              '${state.currentStreak}-day streak.'
          : 'Current streak: ${state.currentStreak} day'
              '${state.currentStreak == 1 ? '' : 's'}'
              '${state.longestEver > state.currentStreak ? ' • best ${state.longestEver}' : ''}'
              '${state.freezesAvailable > 0 ? ' • 1 freeze banked' : ''}',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: accent.withOpacity(0.16),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: accent.withOpacity(0.55)),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: accent,
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.3,
          ),
        ),
      ),
    );
  }
}
