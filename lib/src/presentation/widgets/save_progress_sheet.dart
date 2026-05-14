import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../../core/theme/game_ui_tokens.dart';
import '../../data/services/identity_link_service.dart';
import 'frosted_overlay_card.dart';

/// "Save my progress" sheet shown after a session or from the profile menu.
///
/// Anonymous-by-default users tap a Google or Apple button; on success the
/// underlying Supabase user becomes a permanent identity with the SAME
/// uid — no data migration, all captures/badges/leaderboard entries stay.
///
/// Visually, the sheet is intentionally low-friction: a single short
/// rationale line, two big provider buttons, and a "Maybe later" affordance.
class SaveProgressSheet extends StatefulWidget {
  /// Optional headline override (e.g. milestone-specific celebration copy).
  final String? headline;

  /// Optional one-line rationale shown under the headline.
  final String? subline;

  /// Service injection point (overridden in tests).
  final IdentityLinkService? service;

  /// Number of captures held in the local SharedPreferences cache for
  /// the current anon session.  Forwarded to
  /// [IdentityLinkService.linkApple] / [linkGoogle] so the swap-detection
  /// guard can distinguish "clean install recovery" (0 — swap allowed)
  /// from "rich anon would lose progress" (> 0 — swap refused).
  /// Defaults to 0 so existing call sites without local-cache access do
  /// NOT accidentally claim there is data to lose.
  final int localProgressCount;

  /// When true, the sheet shows the compact inline variant suitable for
  /// inlining inside the post-session summary card (no header chrome,
  /// no internal padding — caller controls outer padding).  When false,
  /// the sheet is a standalone modal/bottom-sheet variant.
  final bool inline;

  const SaveProgressSheet({
    super.key,
    this.headline,
    this.subline,
    this.service,
    this.localProgressCount = 0,
    this.inline = false,
  });

  @override
  State<SaveProgressSheet> createState() => _SaveProgressSheetState();
}

class _SaveProgressSheetState extends State<SaveProgressSheet> {
  late final IdentityLinkService _service =
      widget.service ?? IdentityLinkService();

  bool _busy = false;
  String? _error;

  Future<void> _handle(Future<IdentityLinkResult> Function() op) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await op();
    if (!mounted) return;
    if (result.success) {
      Navigator.of(context).maybePop(true);
      return;
    }
    setState(() {
      _busy = false;
      _error = result.errorMessage ?? 'Could not sign in. Please try again.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final body = _buildBody(context);
    if (widget.inline) return body;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: FrostedOverlayCard(
          emphasized: true,
          borderRadius: const BorderRadius.all(Radius.circular(18)),
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
          child: body,
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final headline = widget.headline ?? 'Save your progress';
    final subline = widget.subline ??
        'Sign in once. Your hexes, badge, and streaks stay if you '
        'switch phones or reinstall HexTrail.';

    final showApple = !kIsWeb && Platform.isIOS && IdentityLinkConfig.hasApple;
    // Google: shown on both platforms per UX norms, but only when the
    // Google client IDs are wired in.  Prevents a "not configured" error
    // popping up on tap for users who would otherwise have no signal that
    // the provider is intentionally absent in this build.
    final showGoogle = IdentityLinkConfig.hasGoogle;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          headline,
          textAlign: TextAlign.center,
          style: GameUiText.command(
            color: GameUiTokens.accentPrimary,
            size: 14,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          subline,
          textAlign: TextAlign.center,
          style: GameUiText.body(
            color: GameUiTokens.textMid,
            size: 12.5,
            weight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 14),
        if (showApple) ...[
          _ProviderButton(
            label: 'Continue with Apple',
            icon: Icons.apple,
            onPressed: _busy
                ? null
                : () => _handle(
                      () => _service.linkApple(
                        localProgressCount: widget.localProgressCount,
                      ),
                    ),
            primary: true,
          ),
          const SizedBox(height: 10),
        ],
        if (showGoogle)
          _ProviderButton(
            label: 'Continue with Google',
            icon: Icons.account_circle_outlined,
            onPressed: _busy
                ? null
                : () => _handle(
                      () => _service.linkGoogle(
                        localProgressCount: widget.localProgressCount,
                      ),
                    ),
            primary: !showApple,
          ),
        if (_busy) ...[
          const SizedBox(height: 12),
          const Center(
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: GameUiText.body(
              color: Colors.redAccent,
              size: 12,
              weight: FontWeight.w600,
            ),
          ),
        ],
        const SizedBox(height: 10),
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).maybePop(false),
          child: Text(
            'MAYBE LATER',
            style: GameUiText.command(
              color: GameUiTokens.textMid,
              size: 11,
              letterSpacing: 0.9,
            ),
          ),
        ),
      ],
    );
  }
}

class _ProviderButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool primary;

  const _ProviderButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    required this.primary,
  });

  @override
  Widget build(BuildContext context) {
    final fg = primary ? GameUiTokens.accentPrimary : GameUiTokens.textHi;
    final bg = primary
        ? GameUiTokens.accentPrimary.withOpacity(0.14)
        : GameUiTokens.bg2.withOpacity(0.60);
    final border = primary
        ? GameUiTokens.accentPrimary.withOpacity(0.40)
        : GameUiTokens.panelBorder.withOpacity(0.60);

    return TextButton(
      style: TextButton.styleFrom(
        backgroundColor: bg,
        foregroundColor: fg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: border),
        ),
        padding: const EdgeInsets.symmetric(vertical: 14),
      ),
      onPressed: onPressed,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 18, color: fg),
          const SizedBox(width: 10),
          Text(
            label.toUpperCase(),
            style: GameUiText.command(
              color: fg,
              size: 12.5,
              letterSpacing: 0.9,
            ),
          ),
        ],
      ),
    );
  }
}


