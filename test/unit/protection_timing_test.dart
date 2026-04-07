import 'package:flutter_test/flutter_test.dart';
import 'package:territory_game/models/game_tile.dart';
import 'package:territory_game/src/presentation/widgets/selected_tile_info_card.dart';

void main() {
  // ── Helpers ──────────────────────────────────────────────

  GameTile tile({
    TileOwnership ownership = TileOwnership.enemy,
    DateTime? protectedUntil,
  }) =>
      GameTile(
        h3Index: 'hex_test',
        ownership: ownership,
        protectedUntil: protectedUntil,
      );

  // ── statusLabel ─────────────────────────────────────────

  group('statusLabel', () {
    test('neutral tile → "Neutral"', () {
      expect(
        SelectedTileInfoCard.statusLabel(
          tile(ownership: TileOwnership.neutral),
        ),
        'Neutral',
      );
    });

    test('enemy tile with active protection → "Protected"', () {
      expect(
        SelectedTileInfoCard.statusLabel(
          tile(protectedUntil: DateTime.now().add(const Duration(hours: 1))),
        ),
        'Protected',
      );
    });

    test('enemy tile with expired protection → "Capturable now"', () {
      expect(
        SelectedTileInfoCard.statusLabel(
          tile(protectedUntil: DateTime.now().subtract(const Duration(seconds: 1))),
        ),
        'Capturable now',
      );
    });

    test('enemy tile with null protectedUntil → "Capturable now"', () {
      expect(
        SelectedTileInfoCard.statusLabel(
          tile(protectedUntil: null),
        ),
        'Capturable now',
      );
    });

    test('own tile with null protectedUntil → "Capturable now"', () {
      expect(
        SelectedTileInfoCard.statusLabel(
          tile(ownership: TileOwnership.mine, protectedUntil: null),
        ),
        'Capturable now',
      );
    });
  });

  // ── protectionCountdown ─────────────────────────────────

  group('protectionCountdown', () {
    test('returns "--" when protectedUntil is null', () {
      expect(
        SelectedTileInfoCard.protectionCountdown(
          tile(protectedUntil: null),
        ),
        '--',
      );
    });

    test('returns "--" when protection has expired', () {
      expect(
        SelectedTileInfoCard.protectionCountdown(
          tile(protectedUntil: DateTime.now().subtract(const Duration(minutes: 5))),
        ),
        '--',
      );
    });

    test('returns mm:ss format for < 1 hour', () {
      // Protection expiring in ~30 min 15 sec
      final result = SelectedTileInfoCard.protectionCountdown(
        tile(
          protectedUntil: DateTime.now().add(const Duration(minutes: 30, seconds: 15)),
        ),
      );

      // Should be in format "mm:ss"
      expect(result, matches(RegExp(r'^\d{2}:\d{2}$')));
      // Minutes portion should be around 30
      final parts = result.split(':');
      expect(int.parse(parts[0]), closeTo(30, 1));
    });

    test('returns hh:mm:ss format for >= 1 hour', () {
      final result = SelectedTileInfoCard.protectionCountdown(
        tile(
          protectedUntil: DateTime.now().add(const Duration(hours: 2, minutes: 15)),
        ),
      );

      // Should be in format "hh:mm:ss"
      expect(result, matches(RegExp(r'^\d{2}:\d{2}:\d{2}$')));
      final parts = result.split(':');
      expect(int.parse(parts[0]), closeTo(2, 1));
    });
  });

  // ── helperLine ──────────────────────────────────────────

  group('helperLine', () {
    test('neutral tile → "Capturable now"', () {
      expect(
        SelectedTileInfoCard.helperLine(
          tile(ownership: TileOwnership.neutral),
        ),
        'Capturable now',
      );
    });

    test('enemy tile with active protection → "Cannot be taken yet"', () {
      expect(
        SelectedTileInfoCard.helperLine(
          tile(protectedUntil: DateTime.now().add(const Duration(hours: 1))),
        ),
        'Cannot be taken yet',
      );
    });

    test('enemy tile with expired protection → "Capturable now"', () {
      expect(
        SelectedTileInfoCard.helperLine(
          tile(protectedUntil: DateTime.now().subtract(const Duration(seconds: 1))),
        ),
        'Capturable now',
      );
    });

    test('own tile with active protection → shows remaining time', () {
      final result = SelectedTileInfoCard.helperLine(
        tile(
          ownership: TileOwnership.mine,
          protectedUntil: DateTime.now().add(const Duration(minutes: 10)),
        ),
      );

      expect(result, startsWith('Protected for'));
      expect(result, contains('m'));
    });

    test('own tile with null protection → "Capturable now"', () {
      expect(
        SelectedTileInfoCard.helperLine(
          tile(ownership: TileOwnership.mine, protectedUntil: null),
        ),
        'Capturable now',
      );
    });
  });
}
