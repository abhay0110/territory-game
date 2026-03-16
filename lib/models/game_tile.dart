enum TileOwnership {
  neutral,
  mine,
  enemy,
}

class GameTile {
  final String h3Index;
  final TileOwnership ownership;
  final String? ownerId;
  final DateTime? capturedAt;
  final DateTime? lastRefreshedAt;
  final DateTime? protectedUntil;
  final bool isVisible;

  const GameTile({
    required this.h3Index,
    required this.ownership,
    this.ownerId,
    this.capturedAt,
    this.lastRefreshedAt,
    this.protectedUntil,
    this.isVisible = true,
  });

  GameTile copyWith({
    String? h3Index,
    TileOwnership? ownership,
    String? ownerId,
    DateTime? capturedAt,
    DateTime? lastRefreshedAt,
    DateTime? protectedUntil,
    bool? isVisible,
  }) {
    return GameTile(
      h3Index: h3Index ?? this.h3Index,
      ownership: ownership ?? this.ownership,
      ownerId: ownerId ?? this.ownerId,
      capturedAt: capturedAt ?? this.capturedAt,
      lastRefreshedAt: lastRefreshedAt ?? this.lastRefreshedAt,
      protectedUntil: protectedUntil ?? this.protectedUntil,
      isVisible: isVisible ?? this.isVisible,
    );
  }
}
