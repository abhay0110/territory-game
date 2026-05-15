import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Hidden capability: upgrade an anonymous Supabase auth user to a permanent
/// email-backed account WITHOUT changing the underlying `auth.users.id`.
///
/// Why this preserves progress:
/// - HexTrail's `tile_captures.owner_user_id` and `player_devices.player_id`
///   are FK references to `auth.users(id)`.
/// - `auth.updateUser(UserAttributes(email:))` keeps the same user UUID and
///   simply attaches an email identity to it. After the user clicks the
///   confirmation magic-link, the row in `auth.users` is preserved with the
///   same id but now has `email` set.
/// - Result: zero data migration needed. All captured tiles, devices and
///   leaderboard rows remain associated with the now-permanent account.
///
/// This service is intentionally NOT wired into the visible beta flow.
/// It is invoked only from a debug-only entry point so we can validate the
/// path internally before unhiding it.
class AccountUpgradeService {
  AccountUpgradeService({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  /// True when the current session is an anonymous user (no linked
  /// OAuth / email / phone identity).
  ///
  /// Uses `currentUser.identities` as the source of truth rather than an
  /// email/phone presence heuristic, because Apple Sign-In frequently
  /// returns no email (Hide My Email, scope denied, re-sign after first
  /// auth) which would otherwise leave the app stuck reporting the
  /// session as anonymous after a successful link.
  bool get isAnonymous {
    final user = _client.auth.currentUser;
    if (user == null) return false;
    if (user.isAnonymous == true) return true;
    final identities = user.identities ?? const [];
    return !identities.any(
      (i) =>
          i.provider == 'google' ||
          i.provider == 'apple' ||
          i.provider == 'email' ||
          i.provider == 'phone',
    );
  }

  /// Sends a confirmation magic-link to [email].  When the user clicks it,
  /// the existing anonymous user becomes a permanent email-backed user with
  /// the SAME `auth.users.id` — so all FK-linked progress is preserved.
  ///
  /// Returns null on success; an error message string on failure.
  /// On failure the existing session is left intact (no sign-out, no
  /// destructive cleanup) so the user keeps playing as their current
  /// anonymous identity.
  Future<String?> requestEmailUpgrade(String email) async {
    final trimmed = email.trim();
    if (trimmed.isEmpty || !trimmed.contains('@')) {
      return 'Please enter a valid email address.';
    }

    final user = _client.auth.currentUser;
    if (user == null) {
      return 'No active session to upgrade.';
    }

    try {
      await _client.auth.updateUser(
        UserAttributes(email: trimmed),
        emailRedirectTo: 'https://hextrail.app',
      );
      if (kDebugMode) {
        debugPrint(
          '[AccountUpgrade] Confirmation email sent to $trimmed for '
          'uid=${user.id}',
        );
      }
      return null;
    } on AuthException catch (e) {
      if (kDebugMode) {
        debugPrint('[AccountUpgrade] AuthException: ${e.message}');
      }
      return e.message;
    } catch (e) {
      if (kDebugMode) debugPrint('[AccountUpgrade] error: $e');
      return 'Could not start upgrade. Please try again.';
    }
  }
}
