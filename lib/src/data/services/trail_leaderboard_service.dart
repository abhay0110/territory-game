import 'dart:math' as math;

import 'package:h3_flutter/h3_flutter.dart' as h3lib;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/constants/launch_corridor.dart';
import '../../../core/constants/seattle_trails.dart';
import '../../../core/constants/seattle_trail_sections.dart';
import '../../../core/constants/valid_trail_hexes.dart';
import '../../../models/trail_section.dart';
import 'display_name_service.dart';

/// A ranked player on a trail leaderboard.
class TrailLeaderboardEntry {
  final String userId;
  final int ownedTiles;
  final bool isYou;
  final String? customDisplayName;

  const TrailLeaderboardEntry({
    required this.userId,
    required this.ownedTiles,
    required this.isYou,
    this.customDisplayName,
  });

  String get displayName {
    if (customDisplayName != null && customDisplayName!.isNotEmpty) {
      return customDisplayName!;
    }
    return isYou ? 'You' : 'Player ${userId.substring(0, 6).toUpperCase()}';
  }
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
  static final h3lib.H3 _h3 = const h3lib.H3Factory().load();

  TrailLeaderboardService({required SupabaseClient supabaseClient})
    : _supabase = supabaseClient;

  /// Fetch leaderboard for Burke-Gilman. Returns null on error.
  Future<TrailLeaderboardSnapshot?> fetchBurkeGilman({int topN = 10}) async {
    final trail = SeattleTrailDefinitions.trails.firstWhere(
      (t) => t.id == 'burke_gilman',
    );
    // Use LaunchCorridor.displayHexes so leaderboard counts match the
    // visual trail lane the player sees on the map (core + 1-ring
    // expansion). Using the strict ValidTrailHexes set caused
    // cross-device count disagreements when a legitimate captured tile
    // sat on an expansion hex.
    final trailHexes = LaunchCorridor.displayHexes;
    final currentUserId = _supabase.auth.currentUser?.id;

    // Fetch all tile_captures rows for corridor hexes.
    // Batch to stay within Supabase REST URL-length limits.
    final hexList = trailHexes.toList();
    final List<dynamic> rows = [];
    try {
      const batchSize = 200;
      for (var i = 0; i < hexList.length; i += batchSize) {
        final batch = hexList.sublist(
          i,
          math.min(i + batchSize, hexList.length),
        );
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

    // Batch-fetch display names for the visible top-N (cheap one query).
    final topUserIds = sorted.take(topN).map((e) => e.key).toList();
    final names = await DisplayNameService(client: _supabase)
        .getMany(topUserIds);

    final topPlayers = sorted.take(topN).map((e) {
      return TrailLeaderboardEntry(
        userId: e.key,
        ownedTiles: e.value,
        isYou: e.key == currentUserId,
        customDisplayName: names[e.key],
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

    // Build a per-section playable hex set so totals match what's actually
    // capturable:
    //   • drop blacklisted hexes from the raw section list
    //   • drop hexes that aren't in the valid set (defensive)
    //   • assign every valid hex NOT already in some section (Phase 2/2.5
    //     expansion + manual whitelist) to the section that contains an
    //     H3 neighbor of it, so section totals sum to validHexIds.length.
    final sectionHexes = <String, Set<String>>{
      for (final s in bgSections)
        s.id: {
          for (final h in s.orderedH3Indexes)
            if (!ValidTrailHexes.isBlacklisted(h) &&
                ValidTrailHexes.isValid(h))
              h,
        },
    };
    final assigned = <String>{
      for (final s in sectionHexes.values) ...s,
    };
    for (final hex in ValidTrailHexes.validHexIds) {
      if (assigned.contains(hex)) continue;
      final cell = BigInt.parse(hex, radix: 16);
      final ring = _h3
          .gridDisk(cell, 1)
          .map((c) => c.toRadixString(16).toLowerCase())
          .toSet();
      String? bestSectionId;
      for (final s in bgSections) {
        if (sectionHexes[s.id]!.any(ring.contains)) {
          bestSectionId = s.id;
          break;
        }
      }
      // Fallback: append to last section if no neighbor match.
      bestSectionId ??= bgSections.last.id;
      sectionHexes[bestSectionId]!.add(hex);
      assigned.add(hex);
    }

    final sectionSnapshots = bgSections.map((section) {
      final hexes = sectionHexes[section.id]!;
      final sectionOwnerCounts = <String, int>{};
      for (final hex in hexes) {
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
        totalTiles: hexes.length,
      );
    }).toList();

    return TrailLeaderboardSnapshot(
      trailName: trail.name,
      topPlayers: topPlayers,
      yourRank: yourRank,
      yourTotalTiles: yourTotalTiles,
      // Use the playable (valid) hex count so the denominator matches
      // what is actually capturable — not the wider visual lane.
      trailTotalTiles: ValidTrailHexes.validHexIds.length,
      totalPlayers: sorted.length,
      sections: sectionSnapshots,
    );
  }
}
