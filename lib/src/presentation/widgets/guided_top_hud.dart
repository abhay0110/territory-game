import 'package:flutter/material.dart';

import '../../../core/theme/game_ui_tokens.dart';
import '../../state/game_state.dart';
import 'frosted_overlay_card.dart';
import 'guided_overlay_card.dart';
import 'hud_pill.dart';

/// Pre-computed copy for the guided top HUD normal mode.
class GuidedTopHudCopy {
  final String title;
  final String? detail;

  const GuidedTopHudCopy({required this.title, this.detail});
}

class GuidedTopHud extends StatelessWidget {
  final bool compactHud;
  final bool sessionActive;
  final bool isFirstCaptureMode;
  final bool showPostCaptureGuidance;
  final bool capturePulseActive;
  final bool hasSectionPressure;
  final String? direction;
  final bool hasGlowTarget;

  /// When non-null, the user is far from the active corridor and pre-session
  /// copy references the corridor name instead of "glowing tile".
  final String? corridorName;

  /// Formatted distance string (e.g. "2.6 mi") to the corridor entry.
  final String? corridorDistance;
  final Widget modeMenuButton;

  /// Current session activity mode (used for mode pill + ride copy).
  final ActivityMode activityMode;

  /// Callback to open the leaderboard sheet. When non-null a compact
  /// leaderboard affordance is rendered in the pill row.
  final VoidCallback? onLeaderboard;

  /// Prefetched rank (1-based) for inline display. Null = not yet loaded.
  final int? leaderboardRank;

  /// Prefetched owned-tile count for inline display.
  final int? leaderboardTiles;

  // Normal-mode props
  final int mineCount;
  final GuidedTopHudCopy? normalCopy;
  final String sessionElapsedText;

  const GuidedTopHud({
    super.key,
    required this.compactHud,
    required this.sessionActive,
    required this.isFirstCaptureMode,
    required this.showPostCaptureGuidance,
    required this.capturePulseActive,
    required this.hasSectionPressure,
    this.direction,
    required this.hasGlowTarget,
    this.corridorName,
    this.corridorDistance,
    required this.modeMenuButton,
    required this.activityMode,
    this.onLeaderboard,
    this.leaderboardRank,
    this.leaderboardTiles,
    required this.mineCount,
    this.normalCopy,
    required this.sessionElapsedText,
  });

  @override
  Widget build(BuildContext context) {
    final riding = activityMode == ActivityMode.ride;

    // Leaderboard pill — reused across pre-session and active-session states.
    Widget? leaderboardPill() {
      if (onLeaderboard == null) return null;
      return GestureDetector(
        onTap: onLeaderboard,
        child: HudPill(
          label: '🏆',
          value: leaderboardRank != null
              ? '#$leaderboardRank · $leaderboardTiles tiles'
              : 'Leaderboard',
          color: GameUiTokens.accentPrimary,
        ),
      );
    }

    if (!sessionActive) {
      // When user is far from the active corridor, pre-session copy
      // references the corridor name to orient them.
      if (corridorName != null) {
        final distLine = corridorDistance != null
            ? '$corridorDistance to the active battlefield'
            : null;
        final card = GuidedOverlayCard(
          message: direction == null
              ? (riding ? 'Ride to $corridorName' : 'Head to $corridorName')
              : (riding
                    ? 'Ride $direction to $corridorName'
                    : 'Head $direction to $corridorName'),
          subtitle: distLine,
          trailing: modeMenuButton,
        );
        final pill = leaderboardPill();
        if (pill == null) return card;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [card, const SizedBox(height: 6), pill],
        );
      }
      final card = GuidedOverlayCard(
        message: direction == null
            ? (hasGlowTarget
                  ? (riding
                        ? '▶ Start session, then ride to the glowing tile'
                        : '▶ Start session, then move to the glowing tile')
                  : '▶ Start session to begin capturing tiles')
            : (hasGlowTarget
                  ? (riding
                        ? '▶ Start session, then ride $direction to the glow'
                        : '▶ Start session, then move $direction to the glow')
                  : (riding
                        ? '▶ Start session, then ride $direction'
                        : '▶ Start session, then move $direction')),
        trailing: modeMenuButton,
      );
      final pill = leaderboardPill();
      if (pill == null) return card;
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [card, const SizedBox(height: 6), pill],
      );
    }

    if (isFirstCaptureMode) {
      return GuidedOverlayCard(
        message: corridorName != null
            ? (riding
                  ? '⚡ Session live — ride to $corridorName'
                  : '⚡ Session live — head to $corridorName')
            : direction == null
            ? (riding
                  ? '⚡ Session live — ride to the glowing tile'
                  : '⚡ Session live — move to the glowing tile')
            : (riding
                  ? '⚡ Session live — ride $direction to the glow'
                  : '⚡ Session live — move $direction to the glow'),
        subtitle: corridorName != null && corridorDistance != null
            ? '$corridorDistance to the active battlefield'
            : null,
        trailing: modeMenuButton,
      );
    }

    if (showPostCaptureGuidance) {
      return GuidedOverlayCard(
        message: direction == null
            ? (hasSectionPressure
                  ? '🔥 Great capture. One more tile can swing this section'
                  : '🔥 Great capture. Take the next glowing tile')
            : (riding
                  ? '🔥 Great capture. Ride $direction to extend your streak'
                  : '🔥 Great capture. Capture $direction to extend your streak'),
        trailing: modeMenuButton,
      );
    }

    // Normal guided mode: objective-aware compact HUD.
    final copy = normalCopy;
    final title = copy?.title ?? '';
    final detail = copy?.detail;

    return FrostedOverlayCard(
      emphasized: capturePulseActive,
      borderRadius: const BorderRadius.all(Radius.circular(16)),
      padding: EdgeInsets.fromLTRB(
        12,
        compactHud ? 8 : 10,
        12,
        compactHud ? 8 : 10,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.gps_fixed,
                size: 14,
                color: sessionActive
                    ? GameUiTokens.accentSecondary
                    : GameUiTokens.textMid,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: GameUiText.body(
                    color: GameUiTokens.textHi,
                    size: 13,
                    weight: FontWeight.w800,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              modeMenuButton,
            ],
          ),
          if (detail != null) ...[
            const SizedBox(height: 3),
            Text(
              detail,
              style: GameUiText.meta(color: GameUiTokens.textMid, size: 11),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              HudPill(
                label: 'Tiles',
                value: '$mineCount',
                color: mineCount > 0
                    ? GameUiTokens.accentSecondary
                    : GameUiTokens.textMid,
              ),
              HudPill(
                label: 'Session',
                value: sessionActive ? 'Live $sessionElapsedText' : 'Ready',
                color: sessionActive
                    ? GameUiTokens.accentPrimary
                    : GameUiTokens.textMid,
              ),
              if (sessionActive)
                HudPill(
                  label: 'Mode',
                  value: riding ? 'Riding' : 'Walking',
                  color: GameUiTokens.textMid,
                ),
              if (leaderboardPill() != null) leaderboardPill()!,
            ],
          ),
        ],
      ),
    );
  }
}
