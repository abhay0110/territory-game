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

  /// Number of times the current owner has reclaimed this tile after losing
  /// it. 0 for fresh captures and untouched tiles. Populated by the
  /// `user_tile_captures_increment_defend_count` Postgres trigger; see
  /// [Phase 1.2a migration](../../supabase/migrations/add_defend_count_to_user_tile_captures.sql).
  final int defendCount;

  const GameTile({
    required this.h3Index,
    required this.ownership,
    this.ownerId,
    this.capturedAt,
    this.lastRefreshedAt,
    this.protectedUntil,
    this.isVisible = true,
    this.defendCount = 0,
  });

  GameTile copyWith({
    String? h3Index,
    TileOwnership? ownership,
    String? ownerId,
    DateTime? capturedAt,
    DateTime? lastRefreshedAt,
    DateTime? protectedUntil,
    bool? isVisible,
    int? defendCount,
  }) {
    return GameTile(
      h3Index: h3Index ?? this.h3Index,
      ownership: ownership ?? this.ownership,
      ownerId: ownerId ?? this.ownerId,
      capturedAt: capturedAt ?? this.capturedAt,
      lastRefreshedAt: lastRefreshedAt ?? this.lastRefreshedAt,
      protectedUntil: protectedUntil ?? this.protectedUntil,
      isVisible: isVisible ?? this.isVisible,
      defendCount: defendCount ?? this.defendCount,
    );
  }
}
