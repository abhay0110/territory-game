import 'package:flutter/material.dart';

import '../../data/services/streak_service.dart';

/// Daily-capture streak indicator shown on the home screen.  Pure
/// presentational: caller supplies the [StreakState].
///
/// Visual rules:
///  - Hidden entirely (returns [SizedBox.shrink]) when state is null
///    OR currentStreak == 0 AND no banner pending — fresh installs
///    see nothing instead of "0-day streak" which feels like failure.
///  - Single line layout matching the pressure card style.
///  - Flame icon + "{N}-day streak".
///  - Sub-line shows freeze status: "🧊 1 freeze available" when one is
///    banked, or "🧊 Freeze used — capture today to keep your streak"
///    when [showFreezeUsedBanner] is true.
///
/// Intentionally fail-safe: any exception collapses to SizedBox.shrink.
class StreakCard extends StatelessWidget {
  final StreakState? state;
  final bool showFreezeUsedBanner;
  final VoidCallback? onTap;

  const StreakCard({
    super.key,
    required this.state,
    this.showFreezeUsedBanner = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    try {
      final s = state;
      if (s == null) return const SizedBox.shrink();
      if (s.currentStreak == 0 && !showFreezeUsedBanner) {
        return const SizedBox.shrink();
      }

      final streakText = s.currentStreak == 1
          ? '1-day streak'
          : '${s.currentStreak}-day streak';

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
            _StreakRow(
              icon: '🔥',
              text: streakText,
              color: const Color(0xFFF59E0B),
              trailing: s.longestEver > s.currentStreak
                  ? 'best ${s.longestEver}'
                  : null,
            ),
            if (showFreezeUsedBanner) ...[
              const SizedBox(height: 8),
              const _StreakRow(
                icon: '🧊',
                text: 'Freeze used — capture today to keep your streak',
                color: Color(0xFF60A5FA),
              ),
            ] else if (s.freezesAvailable > 0 && s.currentStreak > 0) ...[
              const SizedBox(height: 8),
              const _StreakRow(
                icon: '🧊',
                text: '1 freeze banked',
                color: Color(0xFF60A5FA),
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
    } catch (_) {
      return const SizedBox.shrink();
    }
  }
}

class _StreakRow extends StatelessWidget {
  final String icon;
  final String text;
  final Color color;
  final String? trailing;

  const _StreakRow({
    required this.icon,
    required this.text,
    required this.color,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(icon, style: const TextStyle(fontSize: 20)),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 8),
          Text(
            trailing!,
            style: const TextStyle(
              color: Color(0xFF6B7280),
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ],
    );
  }
}
