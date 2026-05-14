import 'package:flutter/material.dart';

import '../../core/theme/game_ui_tokens.dart';
import '../../src/presentation/widgets/frosted_overlay_card.dart';
import 'recap_data_loader.dart';
import 'recap_summary.dart';

/// Full-screen recap of the most-recently-completed ISO week.
///
/// Phase 1.5, build +21.  Reachable today only via the FCM-tap deep
/// link or by manually instantiating the route while
/// `FeatureFlags.weeklyRecapEnabled` is on.  The screen is loader-
/// driven so we can present a graceful "no recap available" state
/// when called for a week with no content.
class RecapScreen extends StatefulWidget {
  const RecapScreen({super.key, this.loader});

  /// Override the loader for tests.  Defaults to [RecapDataLoader].
  final RecapDataLoader? loader;

  static const String routeName = '/recap';

  @override
  State<RecapScreen> createState() => _RecapScreenState();
}

class _RecapScreenState extends State<RecapScreen> {
  RecapSummary? _summary;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final loader = widget.loader ?? RecapDataLoader();
    final summary = await loader.loadCurrentRecap();
    if (!mounted) return;
    setState(() {
      _summary = summary;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: GameUiTokens.bg0,
      appBar: AppBar(
        title: const Text('Weekly Recap'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SafeArea(
        child: _loading
            ? const Center(
                child: CircularProgressIndicator(
                  color: GameUiTokens.accentPrimary,
                  strokeWidth: 2,
                ),
              )
            : _summary == null
                ? const _EmptyRecap()
                : _RecapBody(summary: _summary!),
      ),
    );
  }
}

class _EmptyRecap extends StatelessWidget {
  const _EmptyRecap();

  @override
  Widget build(BuildContext context) {
    // Reached when the loader returns null (no captures + no badges
    // this week, OR no signed-in session, OR fetch failed).  We do
    // NOT distinguish these cases — the recap is decoration, not an
    // error console.
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Text(
          'No recap this week.\nCapture a hex to start your story.',
          textAlign: TextAlign.center,
          style: GameUiText.body(color: GameUiTokens.textMid, size: 14),
        ),
      ),
    );
  }
}

class _RecapBody extends StatelessWidget {
  const _RecapBody({required this.summary});

  final RecapSummary summary;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        FrostedOverlayCard(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _weekLabel(summary),
                style: GameUiText.command(
                  color: GameUiTokens.textLow,
                  size: 11,
                  letterSpacing: 1.5,
                ),
              ),
              const SizedBox(height: 14),
              _BigNumber(
                value: '${summary.hexesCapturedThisWeek}',
                label: summary.hexesCapturedThisWeek == 1
                    ? 'hex captured'
                    : 'hexes captured',
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: _MiniStat(
                      value: '${summary.daysActiveThisWeek}',
                      label: 'active days',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _MiniStat(
                      value: summary.currentStreakDays > 0
                          ? '🔥 ${summary.currentStreakDays}'
                          : '—',
                      label: 'day streak',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (summary.newBadgesThisWeek.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text(
            'NEW THIS WEEK',
            style: GameUiText.command(
              color: GameUiTokens.textLow,
              size: 10,
              letterSpacing: 1.5,
              weight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          for (final b in summary.newBadgesThisWeek) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2, right: 8),
                  child: Text(
                    switch (b.rank) {
                      1 => '🥇',
                      2 => '🥈',
                      3 => '🥉',
                      _ => '🏆',
                    },
                    style: const TextStyle(fontSize: 18),
                  ),
                ),
                Expanded(
                  child: Text(
                    b.label,
                    style: GameUiText.body(
                      color: GameUiTokens.textHi,
                      size: 14,
                      weight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ],
      ],
    );
  }

  static String _weekLabel(RecapSummary s) {
    String fmt(DateTime d) {
      const months = [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
      ];
      return '${months[d.month - 1]} ${d.day}';
    }

    return 'Week of ${fmt(s.weekStart)}—${fmt(s.weekEnd)}, ${s.weekEnd.year}';
  }
}

class _BigNumber extends StatelessWidget {
  const _BigNumber({required this.value, required this.label});
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: GameUiText.command(
            color: GameUiTokens.accentPrimary,
            size: 44,
            weight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: GameUiText.meta(color: GameUiTokens.textMid, size: 13),
        ),
      ],
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.value, required this.label});
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      decoration: BoxDecoration(
        color: GameUiTokens.bg2,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: GameUiTokens.panelBorder.withOpacity(0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: GameUiText.body(
              color: GameUiTokens.textHi,
              size: 18,
              weight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: GameUiText.meta(color: GameUiTokens.textMid, size: 11),
          ),
        ],
      ),
    );
  }
}
