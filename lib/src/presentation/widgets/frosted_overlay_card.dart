import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../core/constants/game_colors.dart';

class FrostedOverlayCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final BorderRadius borderRadius;

  const FrostedOverlayCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(12),
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Container(
          decoration: BoxDecoration(
            color: GameColors.hudBlack,
            borderRadius: borderRadius,
            border: Border.all(color: Colors.white24),
          ),
          child: Padding(
            padding: padding,
            child: child,
          ),
        ),
      ),
    );
  }
}
