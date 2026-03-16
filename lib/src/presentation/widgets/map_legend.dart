import 'package:flutter/material.dart';

import '../../../core/constants/game_colors.dart';
import 'frosted_overlay_card.dart';

class MapLegend extends StatelessWidget {
  const MapLegend({super.key});

  Widget _legendItem(Color color, String label, {bool outlined = false}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
            border: outlined ? Border.all(color: Colors.white, width: 1.2) : null,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: FrostedOverlayCard(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Wrap(
          spacing: 10,
          runSpacing: 6,
          children: [
            _legendItem(GameColors.neonGreen, 'Mine protected'),
            _legendItem(GameColors.myTileGreen, 'Mine expired'),
            _legendItem(GameColors.rivalRed, 'Rival protected'),
            _legendItem(GameColors.rivalRedDark, 'Rival capturable'),
            _legendItem(GameColors.neutralGray, 'Neutral'),
            _legendItem(
              Colors.black,
              'Current tile',
              outlined: true,
            ),
          ],
        ),
      ),
    );
  }
}
