import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../core/theme/game_ui_tokens.dart';

class FrostedOverlayCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final BorderRadius borderRadius;
  final bool emphasized;

  const FrostedOverlayCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(12),
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
    this.emphasized = false,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                GameUiTokens.bg1.withOpacity(0.86),
                GameUiTokens.bg2.withOpacity(0.80),
              ],
            ),
            borderRadius: borderRadius,
            border: Border.all(
              color: emphasized
                  ? GameUiTokens.accentPrimary.withOpacity(0.60)
                  : GameUiTokens.panelBorder.withOpacity(0.76),
              width: emphasized ? 1.5 : 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.30),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
              if (emphasized)
                BoxShadow(
                  color: GameUiTokens.panelGlow,
                  blurRadius: 18,
                  spreadRadius: 1,
                ),
            ],
          ),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}
