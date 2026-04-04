import 'package:flutter/material.dart';

import '../../../core/constants/game_colors.dart';
import '../../../core/theme/game_ui_tokens.dart';
import 'frosted_overlay_card.dart';

/// Pre-computed copy for the guided CTA panel.
class GuidedCtaCopy {
  /// Message line (sticky bar) or title line (bottom panel).
  final String title;

  /// Detail line (bottom panel only; ignored in sticky bar).
  final String? detail;

  /// Button label.
  final String buttonLabel;

  const GuidedCtaCopy({
    required this.title,
    this.detail,
    required this.buttonLabel,
  });
}

class GuidedCtaPanel extends StatelessWidget {
  /// When true, renders the compact single-row sticky bar variant.
  /// When false, renders the taller bottom panel variant.
  final bool stickyBar;
  final bool compactHud;
  final bool emphasized;
  final GuidedCtaCopy copy;

  /// Optional widget rendered above the action button in the bottom-panel
  /// variant (ignored in sticky-bar mode). Used for the activity-mode selector.
  final Widget? aboveButton;

  // Callbacks
  final VoidCallback? onStartSession;
  final VoidCallback? onActionButton;

  const GuidedCtaPanel({
    super.key,
    required this.stickyBar,
    required this.compactHud,
    required this.emphasized,
    required this.copy,
    this.aboveButton,
    this.onStartSession,
    this.onActionButton,
  });

  @override
  Widget build(BuildContext context) {
    return stickyBar ? _buildStickyBar() : _buildBottomPanel();
  }

  Widget _buildStickyBar() {
    return FrostedOverlayCard(
      emphasized: emphasized,
      padding: EdgeInsets.symmetric(
        horizontal: 10,
        vertical: compactHud ? 6 : 8,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              copy.title,
              style: GameUiText.body(
                color: GameUiTokens.textHi,
                size: 12,
                weight: FontWeight.w700,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 10),
          FilledButton(
            onPressed: onStartSession ?? onActionButton,
            style: FilledButton.styleFrom(
              backgroundColor: GameColors.neonGreen,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            child: Text(
              copy.buttonLabel,
              style: GameUiText.body(
                color: Colors.black,
                weight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomPanel() {
    return FrostedOverlayCard(
      emphasized: emphasized,
      padding: EdgeInsets.symmetric(
        horizontal: 12,
        vertical: compactHud ? 8 : 10,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            copy.title,
            style: GameUiText.body(
              color: GameUiTokens.textHi,
              size: 13,
              weight: FontWeight.w700,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (copy.detail != null) ...[
            const SizedBox(height: 2),
            Text(
              copy.detail!,
              style: GameUiText.meta(color: GameUiTokens.textMid, size: 11),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          if (aboveButton != null) ...[const SizedBox(height: 8), aboveButton!],
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: onStartSession ?? onActionButton,
              style: FilledButton.styleFrom(
                backgroundColor: GameColors.neonGreen,
                foregroundColor: Colors.black,
              ),
              child: Text(copy.buttonLabel),
            ),
          ),
        ],
      ),
    );
  }
}
