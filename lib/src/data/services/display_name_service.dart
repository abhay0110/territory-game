import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Per-user public display name backed by the `profiles` table.
///
/// Schema is defined in `supabase/migrations/profiles.sql`:
///   profiles(user_id PK FK auth.users, display_name, created_at, updated_at)
///   - char_length(display_name) BETWEEN 3 AND 20
///   - display_name ~ '^[A-Za-z0-9_-]+$'
///   - case-insensitive unique on lower(display_name)
///
/// RLS: public SELECT, owner-only INSERT/UPDATE.  Anonymous users count
/// as the owner (auth.uid() returns the anon UUID), so they can claim a
/// name without first upgrading to email.
class DisplayNameService {
  DisplayNameService({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  /// Validates the name client-side with the same rules as the DB.
  /// Returns null if valid, or a human-readable error message.
  static String? validate(String raw) {
    final name = raw.trim();
    if (name.length < 3) return 'Must be at least 3 characters.';
    if (name.length > 20) return 'Must be at most 20 characters.';
    final pattern = RegExp(r'^[A-Za-z0-9_-]+$');
    if (!pattern.hasMatch(name)) {
      return 'Only letters, digits, _ and - allowed.';
    }
    return null;
  }

  /// Returns the current user's display name, or null if not set / no
  /// session.  Failure (network error etc.) returns null silently.
  Future<String?> getMine() async {
    final uid = _client.auth.currentUser?.id;
    if (uid == null) return null;
    try {
      final row = await _client
          .from('profiles')
          .select('display_name')
          .eq('user_id', uid)
          .maybeSingle();
      if (row == null) return null;
      return row['display_name'] as String?;
    } catch (e) {
      if (kDebugMode) debugPrint('[DisplayName] getMine failed: $e');
      return null;
    }
  }

  /// Sets the current user's display name.  Returns null on success or
  /// an error message on failure.  Invalid format is rejected client-side
  /// before hitting the network.
  Future<String?> setMine(String raw) async {
    final err = validate(raw);
    if (err != null) return err;
    final name = raw.trim();
    final uid = _client.auth.currentUser?.id;
    if (uid == null) return 'No active session.';
    try {
      await _client.from('profiles').upsert({
        'user_id': uid,
        'display_name': name,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'user_id');
      return null;
    } on PostgrestException catch (e) {
      if (kDebugMode) debugPrint('[DisplayName] setMine PG error: ${e.code} ${e.message}');
      // 23505 = unique_violation (case-insensitive name taken).
      if (e.code == '23505') return 'That name is already taken.';
      // 23514 = check constraint (length / charset).
      if (e.code == '23514') return 'Invalid name format.';
      return e.message;
    } catch (e) {
      if (kDebugMode) debugPrint('[DisplayName] setMine failed: $e');
      return 'Could not save name. Please try again.';
    }
  }

  /// Batch-fetches display names for [userIds].  Missing entries are
  /// simply absent from the returned map.
  Future<Map<String, String>> getMany(List<String> userIds) async {
    if (userIds.isEmpty) return const {};
    try {
      final rows = await _client
          .from('profiles')
          .select('user_id, display_name')
          .inFilter('user_id', userIds) as List<dynamic>?;
      if (rows == null) return const {};
      final out = <String, String>{};
      for (final r in rows) {
        if (r is Map &&
            r['user_id'] is String &&
            r['display_name'] is String) {
          out[r['user_id'] as String] = r['display_name'] as String;
        }
      }
      return out;
    } catch (e) {
      if (kDebugMode) debugPrint('[DisplayName] getMany failed: $e');
      return const {};
    }
  }
}
