import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Compile-time configuration for native OAuth providers.
///
/// These IDs are obtained from Google Cloud Console and Apple Developer.
/// They are NOT secrets (the iOS/Android binary already exposes them) so
/// it is fine to commit them.  Until they are populated, calls into
/// [IdentityLinkService.linkGoogle]/[linkApple] will fail fast with a
/// configuration error.
///
/// To populate, see `docs/account_link_setup.md`.
class IdentityLinkConfig {
  IdentityLinkConfig._();

  /// Google Cloud Console -> Credentials -> "iOS client" -> Client ID.
  static const String? googleIosClientId =
      '375048332121-v94dui7p82ucag0ihi07oq0b8cpe19qt.apps.googleusercontent.com';

  /// Google Cloud Console -> Credentials -> "Web application" client.
  /// Required as `serverClientId` on Android so we receive an ID token
  /// suitable for Supabase `signInWithIdToken`.
  static const String? googleWebClientId =
      '375048332121-56kh1v6e9csioirtbnbs3e7bt2a4jd1g.apps.googleusercontent.com';

  /// Apple Developer -> "Sign in with Apple" Service ID.
  static const String? appleServiceId = 'com.hextrail.app.signin';

  /// Universal-link / web-redirect target Supabase falls back to when the
  /// native flow is unavailable (web/desktop test runs).  Safe to leave as
  /// the marketing site root.
  static const String webRedirect = 'https://hextrail.app';

  static bool get hasGoogle =>
      (googleIosClientId ?? '').isNotEmpty || (googleWebClientId ?? '').isNotEmpty;

  static bool get hasApple => (appleServiceId ?? '').isNotEmpty;
}

/// Result of a link/sign-in attempt.
@immutable
class IdentityLinkResult {
  final bool success;
  final String? errorMessage;

  /// True when the call linked an OAuth identity onto the existing
  /// anonymous user (preserving uid + all FK-linked progress).  False
  /// when the call signed the user in to an existing account that already
  /// owned that Google/Apple identity (fresh-install recovery flow).
  final bool linkedToExistingAnon;

  const IdentityLinkResult._({
    required this.success,
    this.errorMessage,
    this.linkedToExistingAnon = false,
  });

  factory IdentityLinkResult.linked() =>
      const IdentityLinkResult._(success: true, linkedToExistingAnon: true);
  factory IdentityLinkResult.signedIn() =>
      const IdentityLinkResult._(success: true, linkedToExistingAnon: false);
  factory IdentityLinkResult.error(String message) =>
      IdentityLinkResult._(success: false, errorMessage: message);
}

/// Pure decision over the four signals collected before/after
/// `signInWithIdToken`.  Extracted from `_completeWithIdToken` so the
/// data-loss-vs-recovery branch is unit-testable without mocking the
/// entire Supabase client.  See `account_swap_data_loss.md` for the
/// hard rules this enforces.
@visibleForTesting
enum SwapGuardDecision {
  /// Identity was attached to the same uid (link path) — success.
  linked,

  /// Sign-in resolved to a different existing uid AND the local cache
  /// was empty (recovery path) — success, swap allowed.
  recoverySwap,

  /// User was already permanent before the call (re-sign-in) — success.
  reSignedIn,

  /// Sign-in swapped uids on a session that still holds local captures —
  /// MUST refuse, sign back out locally, surface a recovery error.
  refuseDataLoss,
}

@visibleForTesting
SwapGuardDecision evaluateSwapGuard({
  required bool wasAnon,
  required String? priorUid,
  required String? newUid,
  required int localProgressCount,
}) {
  // Authoritative behavior — keep in sync with rules in
  // /memories/repo/account_swap_data_loss.md.
  if (!wasAnon) return SwapGuardDecision.reSignedIn;
  final swapped =
      priorUid != null && newUid != null && newUid != priorUid;
  if (!swapped) return SwapGuardDecision.linked;
  if (localProgressCount > 0) return SwapGuardDecision.refuseDataLoss;
  return SwapGuardDecision.recoverySwap;
}

/// Links an existing anonymous Supabase user to a permanent Google/Apple
/// identity (preserving the same `auth.users.id`), or signs in a fresh
/// install to an already-linked account.
///
/// Survival guarantee:
/// - `auth.linkIdentity()` keeps the anonymous user's UUID intact and
///   simply attaches a new identity row.  Captured hexes
///   (`tile_captures.owner_user_id`), display names (`profiles.user_id`),
///   founder badge, and FCM device row remain associated with the user
///   automatically with zero data migration.
/// - On a fresh install (no anon session), `signInWithIdToken()` resolves
///   to the existing user that already owns that Google/Apple identity.
///   Same uid → same data.
class IdentityLinkService {
  IdentityLinkService({SupabaseClient? client}) : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  bool get isCurrentSessionAnonymous {
    final user = _client.auth.currentUser;
    if (user == null) return false;
    final hasEmail = (user.email ?? '').isNotEmpty;
    final hasPhone = (user.phone ?? '').isNotEmpty;
    return user.isAnonymous == true || (!hasEmail && !hasPhone);
  }

  bool get isLinked {
    final identities = _client.auth.currentUser?.identities ?? const [];
    return identities.any(
      (i) => i.provider == 'google' || i.provider == 'apple',
    );
  }

  /// Human-readable label of the linked OAuth provider for status UIs,
  /// e.g. "Apple" or "Google".  Returns null when the current session is
  /// not yet linked to any OAuth identity.  When both are linked (rare,
  /// possible if the user added a second provider) the first one wins;
  /// callers that care about the full set should read
  /// `currentUser.identities` directly.
  String? get linkedProviderLabel {
    final identities = _client.auth.currentUser?.identities ?? const [];
    for (final i in identities) {
      if (i.provider == 'apple') return 'Apple';
      if (i.provider == 'google') return 'Google';
    }
    return null;
  }

  /// Link the current anonymous user to (or sign in as) a Google account.
  ///
  /// [localProgressCount] is the number of captures held by the local
  /// SharedPreferences cache for the current anon session.  When it is 0
  /// (e.g. fresh install / post-uninstall recovery) a uid swap into an
  /// existing account is the EXPECTED behavior and is allowed.  When it
  /// is > 0 the swap is refused so we never silently strand local
  /// captures on an orphaned anon uid.
  Future<IdentityLinkResult> linkGoogle({int localProgressCount = 0}) async {
    if (!IdentityLinkConfig.hasGoogle) {
      return IdentityLinkResult.error(
        'Google sign-in is not configured for this build.',
      );
    }
    try {
      final googleSignIn = GoogleSignIn(
        clientId: IdentityLinkConfig.googleIosClientId,
        serverClientId: IdentityLinkConfig.googleWebClientId,
      );
      final account = await googleSignIn.signIn();
      if (account == null) {
        return IdentityLinkResult.error('Sign-in was cancelled.');
      }
      final auth = await account.authentication;
      final idToken = auth.idToken;
      final accessToken = auth.accessToken;
      if (idToken == null) {
        return IdentityLinkResult.error('Google did not return an ID token.');
      }
      return _completeWithIdToken(
        provider: OAuthProvider.google,
        idToken: idToken,
        accessToken: accessToken,
        localProgressCount: localProgressCount,
      );
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[IdentityLink] Google failed: $e');
        debugPrintStack(stackTrace: st);
      }
      return IdentityLinkResult.error('Could not sign in with Google.');
    }
  }

  /// Link the current anonymous user to (or sign in as) an Apple account.
  /// See [linkGoogle] for [localProgressCount] semantics.
  Future<IdentityLinkResult> linkApple({int localProgressCount = 0}) async {
    if (!IdentityLinkConfig.hasApple) {
      return IdentityLinkResult.error(
        'Apple sign-in is not configured for this build.',
      );
    }
    try {
      final rawNonce = _generateNonce();
      final hashedNonce = sha256.convert(utf8.encode(rawNonce)).toString();
      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: const [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        nonce: hashedNonce,
      );
      final idToken = credential.identityToken;
      if (idToken == null) {
        return IdentityLinkResult.error('Apple did not return an ID token.');
      }
      return _completeWithIdToken(
        provider: OAuthProvider.apple,
        idToken: idToken,
        nonce: rawNonce,
        localProgressCount: localProgressCount,
      );
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[IdentityLink] Apple failed: $e');
        debugPrintStack(stackTrace: st);
      }
      return IdentityLinkResult.error('Could not sign in with Apple.');
    }
  }

  /// Sign out of the current Supabase session.  Used by the "switch
  /// account" flow on a device that already has a linked session.
  Future<void> signOut() async {
    try {
      await GoogleSignIn().signOut();
    } catch (_) {}
    await _client.auth.signOut();
  }

  Future<IdentityLinkResult> _completeWithIdToken({
    required OAuthProvider provider,
    required String idToken,
    String? accessToken,
    String? nonce,
    int localProgressCount = 0,
  }) async {
    final priorUid = _client.auth.currentUser?.id;
    final wasAnon = isCurrentSessionAnonymous;
    try {
      // signInWithIdToken on an existing anonymous session links the new
      // identity onto the SAME auth.users.id (preserving uid + FK progress)
      // when the OAuth identity is not already claimed.  When it IS already
      // claimed by another user, Supabase silently signs in as that user and
      // the current anon session is replaced.
      //
      // That swap is the EXPECTED behavior for the recovery path (fresh
      // install / new device — no local captures to preserve).  It is a
      // DATA-LOSS bug only when the current anon session is rich (has
      // captures or other progress that would be stranded on the orphaned
      // uid).  We use [localProgressCount] supplied by the caller as the
      // signal: 0 = safe to swap, > 0 = refuse and surface a recovery
      // error.  See /memories/repo/account_swap_data_loss.md.
      await _client.auth.signInWithIdToken(
        provider: provider,
        idToken: idToken,
        accessToken: accessToken,
        nonce: nonce,
      );

      final newUid = _client.auth.currentUser?.id;
      final decision = evaluateSwapGuard(
        wasAnon: wasAnon,
        priorUid: priorUid,
        newUid: newUid,
        localProgressCount: localProgressCount,
      );
      switch (decision) {
        case SwapGuardDecision.refuseDataLoss:
          // Surprise swap on a rich anon session.  Sign back out so the
          // device is not stranded on the wrong (other) account, then
          // surface a recoverable error.  Local captures stay in prefs;
          // the original anon uid is still intact server-side, only its
          // session token is gone.
          try {
            await _client.auth.signOut(scope: SignOutScope.local);
          } catch (_) {}
          return IdentityLinkResult.error(
            'This account is already linked to a different HexTrail '
            'profile. To avoid losing your current progress we did not '
            'switch accounts. Contact support to merge them.',
          );
        case SwapGuardDecision.linked:
          return IdentityLinkResult.linked();
        case SwapGuardDecision.recoverySwap:
          // Recovery path: anon session was clean (localProgressCount == 0),
          // signed into the existing user that already owns the OAuth
          // identity.  All FK-tied progress (captures/badges/streak/
          // leaderboard) on that uid is restored automatically by the
          // map_screen auth-state listener that pulls fresh from
          // user_tile_captures + reconciles the per-device cache.
          return IdentityLinkResult.signedIn();
        case SwapGuardDecision.reSignedIn:
          return IdentityLinkResult.signedIn();
      }
    } on AuthException catch (e) {
      if (kDebugMode) debugPrint('[IdentityLink] AuthException: ${e.message}');
      return IdentityLinkResult.error(e.message);
    } catch (e) {
      if (kDebugMode) debugPrint('[IdentityLink] error: $e');
      return IdentityLinkResult.error('Could not complete sign-in.');
    }
  }

  String _generateNonce([int length = 32]) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._';
    final rnd = Random.secure();
    return List.generate(length, (_) => chars[rnd.nextInt(chars.length)]).join();
  }
}
