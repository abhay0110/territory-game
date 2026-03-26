import 'package:flutter/material.dart';

import '../../../core/theme/game_ui_tokens.dart';

class HudPill extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const HudPill({
    super.key,
    required this.label,
    required this.value,
    this.color = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: GameUiTokens.bg2.withOpacity(0.48),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: GameUiTokens.panelBorder.withOpacity(0.75)),
      ),
      child: RichText(
        text: TextSpan(
          style: GameUiText.meta(
            color: GameUiTokens.textMid,
            size: 11,
            weight: FontWeight.w600,
          ),
          children: [
            TextSpan(text: '$label '),
            TextSpan(
              text: value,
              style: GameUiText.body(
                color: color,
                size: 12,
                weight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
