enum TileOwnership {
  neutral,
  mine,
  enemy,
}

class GameTile {
  final String h3Index;
  final TileOwnership ownership;
  final DateTime? capturedAt;
  final DateTime? protectedUntil;
  final bool isVisible;

  const GameTile({
    required this.h3Index,
    required this.ownership,
    this.capturedAt,
    this.protectedUntil,
    this.isVisible = true,
  });

  GameTile copyWith({
    String? h3Index,
    TileOwnership? ownership,
    DateTime? capturedAt,
    DateTime? protectedUntil,
    bool? isVisible,
  }) {
    return GameTile(
      h3Index: h3Index ?? this.h3Index,
      ownership: ownership ?? this.ownership,
      capturedAt: capturedAt ?? this.capturedAt,
      protectedUntil: protectedUntil ?? this.protectedUntil,
      isVisible: isVisible ?? this.isVisible,
    );
  }
}
