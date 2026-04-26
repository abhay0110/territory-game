import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../core/theme/game_ui_tokens.dart';

/// Shows the first-run onboarding dialog explaining HexTrail's concept.
///
/// Returns `true` if the dialog was dismissed normally (user tapped CTA).
Future<bool> showWelcomeDialog(BuildContext context) async {
  final result = await showGeneralDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    barrierColor: Colors.black.withValues(alpha: 0.7),
    transitionDuration: const Duration(milliseconds: 350),
    transitionBuilder: (context, anim, secondaryAnim, child) {
      return FadeTransition(
        opacity: CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
        child: ScaleTransition(
          scale: Tween<double>(
            begin: 0.92,
            end: 1,
          ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
          child: child,
        ),
      );
    },
    pageBuilder: (context, anim, secondaryAnim) {
      return const _WelcomeDialogContent();
    },
  );
  return result ?? true;
}

class _WelcomeDialogContent extends StatelessWidget {
  const _WelcomeDialogContent();

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;

    return Center(
      child: Padding(
        padding: EdgeInsets.fromLTRB(24, topInset + 24, 24, 24),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 360),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [GameUiTokens.bg1, GameUiTokens.bg2],
                ),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: GameUiTokens.accentPrimary.withValues(alpha: 0.5),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.4),
                    blurRadius: 30,
                    offset: const Offset(0, 12),
                  ),
                  const BoxShadow(
                    color: GameUiTokens.panelGlow,
                    blurRadius: 24,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: Material(
                color: Colors.transparent,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'HEXTRAIL',
                        style: GameUiText.command(
                          color: GameUiTokens.accentPrimary,
                          size: 22,
                          weight: FontWeight.w800,
                          letterSpacing: 2.5,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Burke-Gilman Battlefield',
                        style: GameUiText.body(
                          color: GameUiTokens.textMid,
                          size: 13,
                          weight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 20),
                      _infoRow(
                        Icons.directions_walk,
                        'Walk, run, or bike the Burke-Gilman trail to claim hexes.',
                      ),
                      const SizedBox(height: 12),
                      _infoRow(
                        Icons.hexagon_outlined,
                        'Hexes auto-capture when you enter a glowing hex during a session.',
                      ),
                      const SizedBox(height: 12),
                      _infoRow(
                        Icons.military_tech,
                        'Compete for sections. Leaderboard tracks who controls each stretch.',
                      ),
                      const SizedBox(height: 12),
                      _infoRow(
                        Icons.gps_fixed,
                        'Follow the guided prompts — we\'ll highlight your next target.',
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: () => Navigator.of(context).pop(true),
                          style: FilledButton.styleFrom(
                            backgroundColor: GameUiTokens.accentPrimary,
                            foregroundColor: GameUiTokens.bg0,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: Text(
                            'LET\'S GO',
                            style: GameUiText.command(
                              color: GameUiTokens.bg0,
                              size: 14,
                              weight: FontWeight.w800,
                              letterSpacing: 1.5,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static Widget _infoRow(IconData icon, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: GameUiTokens.accentPrimary),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
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
