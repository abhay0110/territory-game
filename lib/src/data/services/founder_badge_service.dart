import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Founders badge data — first 100 unique users to launch HexTrail.
///
/// Schema is defined in `supabase/migrations/founder_badges.sql`:
///   founder_badges(user_id PK FK auth.users, founder_number 1..100, awarded_at)
///
/// Awarding is server-side via the `claim_founder_badge()` RPC, which is
/// SECURITY DEFINER, idempotent, and race-safe.  Once 100 rows exist the
/// RPC returns NULL forever.
class FounderBadge {
  const FounderBadge({required this.number, required this.awardedAt});

  final int number;
  final DateTime awardedAt;

  /// Display string: "Founder #042".
  String get label => 'Founder #${number.toString().padLeft(3, '0')}';

  factory FounderBadge.fromRow(Map<String, dynamic> row) {
    return FounderBadge(
      number: (row['founder_number'] as num).toInt(),
      awardedAt: DateTime.parse(row['awarded_at'] as String),
    );
  }
}

class FounderBadgeService {
  FounderBadgeService({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  /// Returns the current user's badge, or null if they don't have one
  /// (or if there's no session / the cap was reached before they joined).
  /// Network failures return null silently.
  Future<FounderBadge?> getMine() async {
    final uid = _client.auth.currentUser?.id;
    if (uid == null) return null;
    try {
      final row = await _client
          .from('founder_badges')
          .select('founder_number, awarded_at')
          .eq('user_id', uid)
          .maybeSingle();
      if (row == null) return null;
      return FounderBadge.fromRow(row);
    } catch (e) {
      if (kDebugMode) debugPrint('[FounderBadge] getMine failed: $e');
      return null;
    }
  }

  /// Calls the server-side claim RPC.  Idempotent: a user who already
  /// has a badge gets the same row back.  Returns null if the cap of
  /// 100 has been reached before this user could claim.
  ///
  /// Safe to call on every app launch — the server enforces both
  /// authentication and the cap.
  Future<FounderBadge?> claim() async {
    final uid = _client.auth.currentUser?.id;
    if (uid == null) return null;
    try {
      final result = await _client.rpc('claim_founder_badge');
      if (result == null) return null;
      // Supabase returns the composite-row record as a Map.
      if (result is Map) {
        final map = Map<String, dynamic>.from(result);
        if (map['founder_number'] == null) return null;
        return FounderBadge.fromRow(map);
      }
      // Some Supabase client versions wrap composite returns in a list.
      if (result is List && result.isNotEmpty && result.first is Map) {
        final map = Map<String, dynamic>.from(result.first as Map);
        if (map['founder_number'] == null) return null;
        return FounderBadge.fromRow(map);
      }
      return null;
    } catch (e) {
      if (kDebugMode) debugPrint('[FounderBadge] claim failed: $e');
      return null;
    }
  }

  /// Total number of badges awarded so far (0..100).  Useful for
  /// "X/100 founders claimed" UI once the feature is revealed.
  Future<int> awardedCount() async {
    try {
      final rows = await _client
          .from('founder_badges')
          .select('founder_number');
      return (rows as List).length;
    } catch (e) {
      if (kDebugMode) debugPrint('[FounderBadge] awardedCount failed: $e');
      return 0;
    }
  }
}
