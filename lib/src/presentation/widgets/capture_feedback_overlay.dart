import 'package:flutter/material.dart';

import '../../../core/theme/game_ui_tokens.dart';

class CaptureFeedbackOverlay extends StatelessWidget {
  final String text;
  final bool success;

  const CaptureFeedbackOverlay({super.key, required this.text, this.success = false});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) {
        final rise = 12 * (1 - t);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, rise),
            child: Transform.scale(scale: 0.94 + (0.06 * t), child: child),
          ),
        );
      },
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          if (success)
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: GameUiTokens.accentSecondary.withOpacity(0.32),
                  ),
                ),
                child: const SizedBox(width: 54, height: 54),
              ),
            ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(success ? 0.78 : 0.72),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: success
                    ? GameUiTokens.accentSecondary.withOpacity(0.92)
                    : GameUiTokens.accentPrimary.withOpacity(0.62),
              ),
              boxShadow: [
                BoxShadow(
                  color:
                      (success
                              ? GameUiTokens.accentSecondary
                              : GameUiTokens.accentPrimary)
                          .withOpacity(success ? 0.32 : 0.2),
                  blurRadius: success ? 18 : 14,
                  spreadRadius: success ? 2 : 1,
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (success) ...[
                  Icon(
                    Icons.check_circle,
                    size: 14,
                    color: GameUiTokens.accentSecondary,
                  ),
                  const SizedBox(width: 6),
                ],
                Text(
                  text,
                  style: GameUiText.command(
                    color: success
                        ? GameUiTokens.accentSecondary
                        : GameUiTokens.accentPrimary,
                    size: 12,
                    weight: FontWeight.w800,
                    letterSpacing: 0.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
