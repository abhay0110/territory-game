import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/constants/seattle_trail_sections.dart';
import '../../../features/map/trail_progress_service.dart';

/// Lightweight player stats computed from confirmed/synced data sources.
class PlayerStats {
  final int totalHexesCaptured;
  final int longestTrailStreak;
  final int totalSessions;
  final int bestDayCaptures;
  final String? bestDayDate; // 'YYYY-MM-DD'
  final int bestSessionCaptures;
  final int dayStreak; // consecutive days with captures ending today/yesterday
  final int daysActive; // total unique days with captures
  final double totalDistanceMeters;
  final double walkRunDistanceMeters;
  final double rideDistanceMeters;
  final int sectionsControlled;
  final double trailCompletionPercent;
  final String? trailName;

  const PlayerStats({
    this.totalHexesCaptured = 0,
    this.longestTrailStreak = 0,
    this.totalSessions = 0,
    this.bestDayCaptures = 0,
    this.bestDayDate,
    this.bestSessionCaptures = 0,
    this.dayStreak = 0,
    this.daysActive = 0,
    this.totalDistanceMeters = 0,
    this.walkRunDistanceMeters = 0,
    this.rideDistanceMeters = 0,
    this.sectionsControlled = 0,
    this.trailCompletionPercent = 0,
    this.trailName,
  });
}

/// Computes player stats from SharedPreferences + Supabase.
///
/// All stats are based on confirmed, synced data only.
class PlayerStatsService {
  final SupabaseClient _supabase;

  PlayerStatsService({SupabaseClient? supabaseClient})
      : _supabase = supabaseClient ?? Supabase.instance.client;

  /// Load all available stats. Fails gracefully — returns partial stats
  /// if any individual source fails.
  Future<PlayerStats> loadStats() async {
    final prefs = await SharedPreferences.getInstance();

    // 1. Total hexes captured (synced set from SharedPrefs).
    final capturedRaw = prefs.getString('captured_h3_cells_res9_v1');
    Set<String> capturedHexes = {};
    if (capturedRaw != null && capturedRaw.trim().isNotEmpty) {
      try {
        final list = jsonDecode(capturedRaw) as List<dynamic>;
        capturedHexes = list.map((e) => e.toString().toLowerCase()).toSet();
      } catch (_) {}
    }

    // 2. Total sessions (persisted counter).
    final totalSessions = prefs.getInt('sessions_started_count_v1') ?? 0;

    // 3. Total distance (persisted lifetime accumulator).
    final totalDistance =
        prefs.getDouble('lifetime_distance_meters_v1') ?? 0.0;
    final walkRunDistance =
        prefs.getDouble('lifetime_walk_run_distance_meters_v1') ?? 0.0;
    final rideDistance =
        prefs.getDouble('lifetime_ride_distance_meters_v1') ?? 0.0;

    // 4. Trail streak (computed from trail progress service).
    int longestStreak = 0;
    double trailPercent = 0;
    String? trailName;
    try {
      final trailService = TrailProgressService();
      final progress = trailService.calculateProgress(capturedHexes);
      for (final p in progress) {
        if (p.longestOwnedSegmentTiles > longestStreak) {
          longestStreak = p.longestOwnedSegmentTiles;
        }
        if (p.completionPercent > trailPercent) {
          trailPercent = p.completionPercent;
          trailName = p.trail.name;
        }
      }
    } catch (_) {}

    // 5. Sections controlled (local computation — no Supabase needed).
    int sectionsControlled = 0;
    try {
      final bgSections = SeattleTrailSectionDefinitions.sections
          .where((s) => s.trailId == 'burke_gilman');
      for (final section in bgSections) {
        final owned = section.orderedH3Indexes
            .where((h) => capturedHexes.contains(h.toLowerCase()))
            .length;
        if (owned >= section.totalTiles && section.totalTiles > 0) {
          sectionsControlled++;
        }
      }
    } catch (_) {}

    // 6. Best day + day streak + days active (from Supabase user_tile_captures).
    int bestDayCaptures = 0;
    String? bestDayDate;
    int dayStreak = 0;
    int daysActive = 0;
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId != null) {
        final rows = await _supabase
            .from('user_tile_captures')
            .select('captured_at')
            .eq('user_id', userId)
            .eq('h3_res', 9) as List<dynamic>?;
        if (rows != null) {
          final countByDay = <String, int>{};
          for (final r in rows) {
            if (r is Map && r['captured_at'] is String) {
              final dt = DateTime.tryParse(r['captured_at'] as String);
              if (dt != null) {
                final local = dt.toLocal();
                final day =
                    '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
                countByDay[day] = (countByDay[day] ?? 0) + 1;
              }
            }
          }
          // Best day.
          for (final entry in countByDay.entries) {
            if (entry.value > bestDayCaptures) {
              bestDayCaptures = entry.value;
              bestDayDate = entry.key;
            }
          }
          // Days active.
          daysActive = countByDay.length;
          // Day streak (consecutive days ending today or yesterday).
          dayStreak = _computeDayStreak(countByDay.keys.toSet());
        }
      }
    } catch (_) {}

    // 7. Best session captures (from persisted session history).
    int bestSessionCaptures = 0;
    try {
      final historyRaw = prefs.getString(_prefsSessionHistory);
      if (historyRaw != null) {
        final list = jsonDecode(historyRaw) as List<dynamic>;
        for (final entry in list) {
          if (entry is Map) {
            final c = entry['captures'] as int? ?? 0;
            if (c > bestSessionCaptures) bestSessionCaptures = c;
          }
        }
      }
    } catch (_) {}

    return PlayerStats(
      totalHexesCaptured: capturedHexes.length,
      longestTrailStreak: longestStreak,
      totalSessions: totalSessions,
      bestDayCaptures: bestDayCaptures,
      bestDayDate: bestDayDate,
      bestSessionCaptures: bestSessionCaptures,
      dayStreak: dayStreak,
      daysActive: daysActive,
      totalDistanceMeters: totalDistance,
      walkRunDistanceMeters: walkRunDistance,
      rideDistanceMeters: rideDistance,
      sectionsControlled: sectionsControlled,
      trailCompletionPercent: trailPercent,
      trailName: trailName,
    );
  }

  // ── Day streak computation ─────────────────────────────────────────

  /// Consecutive days ending at today or yesterday that have captures.
  static int _computeDayStreak(Set<String> activeDays) {
    if (activeDays.isEmpty) return 0;
    final now = DateTime.now();
    final today =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final yesterday = now.subtract(const Duration(days: 1));
    final yesterdayStr =
        '${yesterday.year}-${yesterday.month.toString().padLeft(2, '0')}-${yesterday.day.toString().padLeft(2, '0')}';

    // Streak must include today or yesterday to be current.
    DateTime cursor;
    if (activeDays.contains(today)) {
      cursor = now;
    } else if (activeDays.contains(yesterdayStr)) {
      cursor = yesterday;
    } else {
      return 0;
    }

    int streak = 0;
    while (true) {
      final dayStr =
          '${cursor.year}-${cursor.month.toString().padLeft(2, '0')}-${cursor.day.toString().padLeft(2, '0')}';
      if (!activeDays.contains(dayStr)) break;
      streak++;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    return streak;
  }

  // ── Session history persistence ────────────────────────────────────

  static const String _prefsSessionHistory = 'session_history_v1';

  /// Persist a completed session summary. Call at session end.
  static Future<void> saveSessionSummary({
    required int captures,
    required double distanceMeters,
    required int durationSeconds,
    required String mode,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    List<dynamic> history = [];
    try {
      final raw = prefs.getString(_prefsSessionHistory);
      if (raw != null) history = jsonDecode(raw) as List<dynamic>;
    } catch (_) {}

    history.add({
      'captures': captures,
      'distance': distanceMeters,
      'duration': durationSeconds,
      'mode': mode,
      'date': DateTime.now().toIso8601String(),
    });

    await prefs.setString(_prefsSessionHistory, jsonEncode(history));
  }

  // ── Distance persistence helpers (called from game state) ──────────

  /// Accumulate session distance into lifetime totals. Call at session end.
  static Future<void> accumulateSessionDistance({
    required double distanceMeters,
    required bool isRide,
  }) async {
    if (distanceMeters <= 0) return;
    final prefs = await SharedPreferences.getInstance();

    final total =
        (prefs.getDouble('lifetime_distance_meters_v1') ?? 0.0) +
            distanceMeters;
    await prefs.setDouble('lifetime_distance_meters_v1', total);

    if (isRide) {
      final ride =
          (prefs.getDouble('lifetime_ride_distance_meters_v1') ?? 0.0) +
              distanceMeters;
      await prefs.setDouble('lifetime_ride_distance_meters_v1', ride);
    } else {
      final walkRun =
          (prefs.getDouble('lifetime_walk_run_distance_meters_v1') ?? 0.0) +
              distanceMeters;
      await prefs.setDouble('lifetime_walk_run_distance_meters_v1', walkRun);
    }
  }
}
