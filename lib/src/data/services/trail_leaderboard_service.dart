import 'dart:math' as math;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/constants/launch_corridor.dart';
import '../../../core/constants/seattle_trails.dart';
import '../../../core/constants/seattle_trail_sections.dart';
import '../../../models/trail_section.dart';

/// A ranked player on a trail leaderboard.
class TrailLeaderboardEntry {
  final String userId;
  final int ownedTiles;
  final bool isYou;

  const TrailLeaderboardEntry({
    required this.userId,
    required this.ownedTiles,
    required this.isYou,
  });

  String get displayName =>
      isYou ? 'You' : 'Player ${userId.substring(0, 6).toUpperCase()}';
}

/// Control snapshot for a single trail section.
class SectionLeaderSnapshot {
  final TrailSectionDefinition section;
  final SectionControlState controlState;
  final int yourTiles;
  final int topRivalTiles;
  final int totalTiles;

  const SectionLeaderSnapshot({
    required this.section,
    required this.controlState,
    required this.yourTiles,
    required this.topRivalTiles,
    required this.totalTiles,
  });

  double get yourPercent => totalTiles > 0 ? (yourTiles / totalTiles) * 100 : 0;
}

/// Full leaderboard snapshot for a single trail.
class TrailLeaderboardSnapshot {
  final String trailName;
  final List<TrailLeaderboardEntry> topPlayers;
  final int? yourRank; // 1-based, null if not on board
  final int yourTotalTiles;
  final int trailTotalTiles;
  final int totalPlayers;
  final List<SectionLeaderSnapshot> sections;

  const TrailLeaderboardSnapshot({
    required this.trailName,
    required this.topPlayers,
    required this.yourRank,
    required this.yourTotalTiles,
    required this.trailTotalTiles,
    required this.totalPlayers,
    required this.sections,
  });
}

/// Fetches Burke-Gilman trail leaderboard data from Supabase.
class TrailLeaderboardService {
  final SupabaseClient _supabase;

  TrailLeaderboardService({required SupabaseClient supabaseClient})
    : _supabase = supabaseClient;

  /// Fetch leaderboard for Burke-Gilman. Returns null on error.
  Future<TrailLeaderboardSnapshot?> fetchBurkeGilman({int topN = 10}) async {
    final trail = SeattleTrailDefinitions.trails.firstWhere(
      (t) => t.id == 'burke_gilman',
    );
    // Use displayHexes (core + 1-ring visual corridor) so captures on
    // trail-edge hexes count toward the leaderboard.
    final trailHexes = LaunchCorridor.displayHexes;
    final currentUserId = _supabase.auth.currentUser?.id;

    // Fetch all tile_captures rows for corridor hexes.
    // Batch to stay within Supabase REST URL-length limits.
    final hexList = trailHexes.toList();
    final List<dynamic> rows = [];
    try {
      const batchSize = 200;
      for (var i = 0; i < hexList.length; i += batchSize) {
        final batch = hexList.sublist(i, math.min(i + batchSize, hexList.length));
        final batchRows =
            await _supabase
                    .from('tile_captures')
                    .select('h3_hex, owner_user_id')
                    .eq('h3_res', 9)
                    .inFilter('h3_hex', batch)
                as List<dynamic>? ??
            [];
        rows.addAll(batchRows);
      }
    } catch (_) {
      return null;
    }

    // Aggregate: owner_user_id → count of owned tiles on this trail.
    final ownerCounts = <String, int>{};
    // Also build per-hex ownership map for section analysis.
    final ownerByHex = <String, String>{};
    for (final r in rows) {
      if (r is Map && r['h3_hex'] is String && r['owner_user_id'] is String) {
        final hex = (r['h3_hex'] as String).toLowerCase();
        final owner = r['owner_user_id'] as String;
        if (trailHexes.contains(hex)) {
          ownerCounts[owner] = (ownerCounts[owner] ?? 0) + 1;
          ownerByHex[hex] = owner;
        }
      }
    }

    // Rank players by tile count descending.
    final sorted = ownerCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final topPlayers = sorted.take(topN).map((e) {
      return TrailLeaderboardEntry(
        userId: e.key,
        ownedTiles: e.value,
        isYou: e.key == currentUserId,
      );
    }).toList();

    // Find your rank.
    int? yourRank;
    int yourTotalTiles = 0;
    if (currentUserId != null) {
      for (var i = 0; i < sorted.length; i++) {
        if (sorted[i].key == currentUserId) {
          yourRank = i + 1;
          yourTotalTiles = sorted[i].value;
          break;
        }
      }
    }

    // Section control snapshots for Burke-Gilman sections.
    final bgSections = SeattleTrailSectionDefinitions.sections
        .where((s) => s.trailId == 'burke_gilman')
        .toList();

    final sectionSnapshots = bgSections.map((section) {
      final sectionOwnerCounts = <String, int>{};
      for (final hex in section.orderedH3Indexes) {
        final owner = ownerByHex[hex];
        if (owner != null) {
          sectionOwnerCounts[owner] = (sectionOwnerCounts[owner] ?? 0) + 1;
        }
      }

      final yourCount = currentUserId != null
          ? (sectionOwnerCounts[currentUserId] ?? 0)
          : 0;

      // Find top rival (non-you).
      int topRivalCount = 0;
      for (final entry in sectionOwnerCounts.entries) {
        if (entry.key != currentUserId && entry.value > topRivalCount) {
          topRivalCount = entry.value;
        }
      }

      final controlState = switch ((yourCount, topRivalCount)) {
        (0, 0) => SectionControlState.unclaimed,
        _ when yourCount > topRivalCount => SectionControlState.you,
        _ when topRivalCount > yourCount => SectionControlState.rival,
        _ => SectionControlState.contested,
      };

      return SectionLeaderSnapshot(
        section: section,
        controlState: controlState,
        yourTiles: yourCount,
        topRivalTiles: topRivalCount,
        totalTiles: section.totalTiles,
      );
    }).toList();

    return TrailLeaderboardSnapshot(
      trailName: trail.name,
      topPlayers: topPlayers,
      yourRank: yourRank,
      yourTotalTiles: yourTotalTiles,
      trailTotalTiles: trail.totalTiles,
      totalPlayers: sorted.length,
      sections: sectionSnapshots,
    );
  }
}
