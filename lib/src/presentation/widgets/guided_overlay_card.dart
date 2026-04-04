import 'package:flutter/material.dart';

import '../../../core/theme/game_ui_tokens.dart';
import 'frosted_overlay_card.dart';

class GuidedOverlayCard extends StatelessWidget {
  final String message;
  final String? subtitle;
  final Widget? trailing;

  const GuidedOverlayCard({super.key, required this.message, this.subtitle, this.trailing});

  @override
  Widget build(BuildContext context) {
    return FrostedOverlayCard(
      emphasized: true,
      borderRadius: const BorderRadius.all(Radius.circular(14)),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.gps_fixed, size: 14, color: GameUiTokens.accentPrimary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  style: GameUiText.body(
                    color: GameUiTokens.textHi,
                    size: 13,
                    weight: FontWeight.w800,
                  ),
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 8), trailing!],
            ],
          ),
          if (subtitle != null) ...[          
            const SizedBox(height: 3),
            Padding(
              padding: const EdgeInsets.only(left: 22),
              child: Text(
                subtitle!,
                style: GameUiText.meta(color: GameUiTokens.textMid, size: 11),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
