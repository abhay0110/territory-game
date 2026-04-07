import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../../core/theme/game_ui_tokens.dart';
import '../../../models/game_tile.dart';
import 'frosted_overlay_card.dart';
import 'hud_pill.dart';

class SelectedTileInfoCard extends StatelessWidget {
  final GameTile tile;
  final bool guidedMode;
  final bool compactHud;
  final int h3Resolution;
  final VoidCallback onDismiss;

  const SelectedTileInfoCard({
    super.key,
    required this.tile,
    required this.guidedMode,
    required this.compactHud,
    required this.h3Resolution,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final owner = _ownerLabel(tile);
    final status = statusLabel(tile);
    final countdown = protectionCountdown(tile);
    final helper = helperLine(tile);

    return FrostedOverlayCard(
      emphasized: true,
      borderRadius: const BorderRadius.all(Radius.circular(16)),
      padding: EdgeInsets.symmetric(
        horizontal: 12,
        vertical: guidedMode ? 8 : (compactHud ? 8 : 10),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Selected hex',
                  style: GameUiText.body(
                    color: GameUiTokens.textHi,
                    size: 13,
                    weight: FontWeight.w700,
                  ),
                ),
              ),
              InkWell(
                onTap: onDismiss,
                child: Padding(
                  padding: EdgeInsets.all(2),
                  child: Icon(
                    Icons.close,
                    color: GameUiTokens.textMid,
                    size: 18,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              HudPill(label: 'Owner', value: owner),
              HudPill(label: 'Status', value: status),
            ],
          ),
          if (status == 'Protected') ...[
            const SizedBox(height: 6),
            Text(
              'Protection: $countdown',
              style: GameUiText.meta(color: GameUiTokens.textMid, size: 12),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            helper,
            style: GameUiText.body(
              color: GameUiTokens.accentPrimary,
              size: 13,
              weight: FontWeight.w700,
            ),
            maxLines: guidedMode ? 1 : 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (!guidedMode) ...[
            const SizedBox(height: 4),
            Text(
              'H3-$h3Resolution:${tile.h3Index}',
              style: GameUiText.meta(color: GameUiTokens.textLow, size: 10),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  static String _ownerLabel(GameTile tile) {
    return switch (tile.ownership) {
      TileOwnership.mine => 'You',
      TileOwnership.neutral => 'Neutral',
      TileOwnership.enemy => 'Rival',
    };
  }

  @visibleForTesting
  static String statusLabel(GameTile tile) {
    if (tile.ownership == TileOwnership.neutral) return 'Neutral';
    final until = tile.protectedUntil;
    if (until == null || !until.isAfter(DateTime.now())) {
      return 'Capturable now';
    }
    return 'Protected';
  }

  @visibleForTesting
  static String protectionCountdown(GameTile tile) {
    final until = tile.protectedUntil;
    if (until == null || !until.isAfter(DateTime.now())) return '--';

    final remaining = until.difference(DateTime.now());
    final hours = remaining.inHours;
    final minutes = remaining.inMinutes.remainder(60);
    final seconds = remaining.inSeconds.remainder(60);
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @visibleForTesting
  static String helperLine(GameTile tile) {
    if (tile.ownership == TileOwnership.neutral) return 'Capturable now';
    final until = tile.protectedUntil;
    if (until == null || !until.isAfter(DateTime.now())) {
      return 'Capturable now';
    }

    if (tile.ownership == TileOwnership.enemy) return 'Cannot be taken yet';

    return 'Your protection: ${protectionCountdown(tile)}';
  }
}
