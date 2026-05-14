import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Static trail-id → display-name map.  Inlined here (rather than
/// resolved via `SeattleTrailDefinitions`) to keep the model layer free
/// of the H3 native dependency — pure unit tests of `PeriodicBadge`
/// must not require a loaded H3 dylib.  Add new trails here when the
/// awarder starts emitting badges for them.
const Map<String, String> _kTrailDisplayNames = <String, String>{
  'burke_gilman': 'Burke-Gilman',
};

/// One row from the `user_badges` table (Phase 1.4 — periodic badges
/// awarded by the `award-periodic-badges` Edge Function on cron).
///
/// Schema lives in `supabase/migrations/add_user_badges.sql`.  The
/// `badgeKey` is the row's PK suffix and is used as the diffable
/// identity for upserts: re-runs of the awarder for the same period
/// produce the same key and therefore land as a no-op INSERT.
@immutable
class PeriodicBadge {
  const PeriodicBadge({
    required this.badgeKey,
    required this.badgeType,
    required this.trailId,
    required this.periodStart,
    required this.periodEnd,
    required this.rank,
    required this.ownedTiles,
    required this.awardedAt,
  });

  /// e.g. `weekly_top3:burke_gilman:2026-W19` or
  /// `monthly_top3:burke_gilman:2026-03`.
  final String badgeKey;

  /// e.g. `weekly_top3`, `monthly_top3`.  Drives icon + section
  /// grouping in the UI.
  final String badgeType;

  /// e.g. `burke_gilman`.  Resolved against
  /// [SeattleTrailDefinitions.trails] for display.
  final String trailId;

  /// First day of the awarded period (UTC).  Inclusive.
  final DateTime periodStart;

  /// Last day of the awarded period (UTC).  Inclusive.
  final DateTime periodEnd;

  /// 1-based rank within the awarded top-N (1, 2, or 3 today).
  final int rank;

  /// Hex count owned at the moment of the cron run.  Snapshot value;
  /// can drift from current ownership but never changes once awarded.
  final int ownedTiles;

  /// Server timestamp of the INSERT.
  final DateTime awardedAt;

  /// "Top 3 — Burke-Gilman — March 2026" (monthly)
  /// "Top 3 — Burke-Gilman — Week of Mar 9, 2026" (weekly)
  String get label {
    final trailName = _trailNameOrId(trailId);
    final n = _topNFromType(badgeType);
    final period = badgeType.startsWith('monthly')
        ? _monthLabel(periodStart)
        : 'Week of ${_weekLabel(periodStart)}';
    return 'Top $n — $trailName — $period';
  }

  factory PeriodicBadge.fromRow(Map<String, dynamic> row) {
    return PeriodicBadge(
      badgeKey: row['badge_key'] as String,
      badgeType: row['badge_type'] as String,
      trailId: row['trail_id'] as String,
      periodStart: DateTime.parse(row['period_start'] as String),
      periodEnd: DateTime.parse(row['period_end'] as String),
      rank: (row['rank'] as num).toInt(),
      ownedTiles: (row['owned_tiles'] as num).toInt(),
      awardedAt: DateTime.parse(row['awarded_at'] as String),
    );
  }

  static int _topNFromType(String type) {
    // Format: "<period>_top<N>".  Defensive default of 3 (current
    // awarder cap) if a future type ever lands without a number.
    final match = RegExp(r'top(\d+)$').firstMatch(type);
    if (match == null) return 3;
    return int.tryParse(match.group(1)!) ?? 3;
  }

  static String _trailNameOrId(String trailId) {
    return _kTrailDisplayNames[trailId] ?? trailId;
  }

  static const _months = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];
  static const _shortMonths = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  static String _monthLabel(DateTime d) {
    return '${_months[d.month - 1]} ${d.year}';
  }

  static String _weekLabel(DateTime d) {
    return '${_shortMonths[d.month - 1]} ${d.day}, ${d.year}';
  }

  @override
  bool operator ==(Object other) =>
      other is PeriodicBadge && other.badgeKey == badgeKey;

  @override
  int get hashCode => badgeKey.hashCode;
}

/// Read-only client for the `user_badges` table.  Writes happen
/// server-side via the `award-periodic-badges` Edge Function; the
/// Dart layer only fetches.
class BadgeService {
  BadgeService({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  /// Returns the signed-in user's badges, newest-first.  Returns an
  /// empty list when:
  ///   * no session (anon flow before sign-in completes)
  ///   * the user has not yet been awarded anything
  ///   * the table fetch fails (network / RLS hiccup)
  ///
  /// Failures are intentionally swallowed: the ACHIEVEMENTS section is
  /// decoration, not load-critical, and a transient REST failure must
  /// not blank out the rest of the stats sheet.
  Future<List<PeriodicBadge>> fetchMine({int limit = 50}) async {
    final uid = _client.auth.currentUser?.id;
    if (uid == null) return const [];
    try {
      final rows = await _client
          .from('user_badges')
          .select(
            'badge_key, badge_type, trail_id, period_start, period_end, '
            'rank, owned_tiles, awarded_at',
          )
          .eq('user_id', uid)
          .order('awarded_at', ascending: false)
          .limit(limit);
      return rows
          .whereType<Map<String, dynamic>>()
          .map(PeriodicBadge.fromRow)
          .toList();
    } catch (e) {
      if (kDebugMode) debugPrint('[BadgeService] fetchMine failed: $e');
      return const [];
    }
  }
}
