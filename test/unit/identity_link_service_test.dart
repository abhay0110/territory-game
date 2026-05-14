import 'package:flutter_test/flutter_test.dart';
import 'package:HexTrail/src/data/services/identity_link_service.dart';

void main() {
  group('IdentityLinkResult', () {
    test('linked() factory marks success and linkedToExistingAnon', () {
      final r = IdentityLinkResult.linked();
      expect(r.success, isTrue);
      expect(r.linkedToExistingAnon, isTrue);
      expect(r.errorMessage, isNull);
    });

    test('signedIn() factory marks success and NOT linkedToExistingAnon', () {
      final r = IdentityLinkResult.signedIn();
      expect(r.success, isTrue);
      expect(r.linkedToExistingAnon, isFalse);
      expect(r.errorMessage, isNull);
    });

    test('error() factory marks failure with message', () {
      final r = IdentityLinkResult.error('bad token');
      expect(r.success, isFalse);
      expect(r.errorMessage, 'bad token');
      expect(r.linkedToExistingAnon, isFalse);
    });
  });

  group('IdentityLinkConfig', () {
    test('Apple is configured (hard-coded Services ID)', () {
      // Apple Services ID is wired in for build 14.  See
      // docs/account_link_setup.md for rotation procedure.
      expect(IdentityLinkConfig.appleServiceId, 'com.hextrail.app.signin');
      expect(IdentityLinkConfig.hasApple, isTrue);
    });

    test('Google client IDs are wired (provisioned via Google Cloud Console)',
        () {
      // Google build 15: client IDs provisioned via Google Cloud Console.
      // The exact values are non-secret and ship in the binary anyway.
      // We assert format (real-looking client ID strings) instead of
      // hard-coding specific IDs so a future rotation does not require
      // a coupled test edit.  See docs/account_link_setup.md.
      const suffix = '.apps.googleusercontent.com';
      expect(IdentityLinkConfig.googleIosClientId, isNotNull);
      expect(IdentityLinkConfig.googleIosClientId!.endsWith(suffix), isTrue);
      expect(IdentityLinkConfig.googleWebClientId, isNotNull);
      expect(IdentityLinkConfig.googleWebClientId!.endsWith(suffix), isTrue);
      expect(IdentityLinkConfig.hasGoogle, isTrue);
    });

    test('hasApple/hasGoogle reflect non-empty config', () {
      // Sanity: getters return true iff their backing strings are
      // non-empty.  Guards against a future refactor that breaks the
      // unconfigured fail-fast behavior.
      expect(IdentityLinkConfig.hasApple,
          equals((IdentityLinkConfig.appleServiceId ?? '').isNotEmpty));
      expect(
        IdentityLinkConfig.hasGoogle,
        equals(
            (IdentityLinkConfig.googleIosClientId ?? '').isNotEmpty ||
                (IdentityLinkConfig.googleWebClientId ?? '').isNotEmpty),
      );
    });
  });

  group('evaluateSwapGuard (data-loss vs recovery branches)', () {
    // Authoritative behavior locked in by these cases. See
    // /memories/repo/account_swap_data_loss.md.

    test('non-anon re-sign-in => reSignedIn', () {
      final d = evaluateSwapGuard(
        wasAnon: false,
        priorUid: 'permanent-uid',
        newUid: 'permanent-uid',
        localProgressCount: 99,
      );
      expect(d, SwapGuardDecision.reSignedIn);
    });

    test('anon, same uid (link path), 0 captures => linked', () {
      final d = evaluateSwapGuard(
        wasAnon: true,
        priorUid: 'anon-A',
        newUid: 'anon-A',
        localProgressCount: 0,
      );
      expect(d, SwapGuardDecision.linked);
    });

    test('anon, same uid (link path), many captures => linked (no swap)', () {
      // Critical: when uid does not change, captures count is irrelevant.
      // Same anon uid + new identity attached = the happy "Save your
      // progress" path; user keeps every hex they own.
      final d = evaluateSwapGuard(
        wasAnon: true,
        priorUid: 'anon-A',
        newUid: 'anon-A',
        localProgressCount: 42,
      );
      expect(d, SwapGuardDecision.linked);
    });

    test(
        'anon, uid changed (swap), 0 captures => recoverySwap '
        '(fresh-install / reinstall recovery flow MUST be allowed)', () {
      // This is the core of "sign in with my existing email pulls all
      // my data from the server". Previously broken when an over-eager
      // refusal blocked recovery — see the May-10 incident.
      final d = evaluateSwapGuard(
        wasAnon: true,
        priorUid: 'anon-fresh',
        newUid: 'permanent-existing',
        localProgressCount: 0,
      );
      expect(d, SwapGuardDecision.recoverySwap);
    });

    test(
        'anon, uid changed (swap), 1 capture => refuseDataLoss '
        '(strands local progress on orphaned anon uid)', () {
      final d = evaluateSwapGuard(
        wasAnon: true,
        priorUid: 'anon-rich',
        newUid: 'permanent-other',
        localProgressCount: 1,
      );
      expect(d, SwapGuardDecision.refuseDataLoss);
    });

    test(
        'anon, uid changed (swap), many captures => refuseDataLoss '
        '(same as the May-10 production incident)', () {
      final d = evaluateSwapGuard(
        wasAnon: true,
        priorUid: 'anon-rich',
        newUid: 'permanent-other',
        localProgressCount: 25,
      );
      expect(d, SwapGuardDecision.refuseDataLoss);
    });

    test('anon, priorUid null => treated as link (no swap)', () {
      final d = evaluateSwapGuard(
        wasAnon: true,
        priorUid: null,
        newUid: 'new-uid',
        localProgressCount: 0,
      );
      expect(d, SwapGuardDecision.linked);
    });

    test('anon, newUid null (post-call session lost) => treated as link', () {
      final d = evaluateSwapGuard(
        wasAnon: true,
        priorUid: 'anon-A',
        newUid: null,
        localProgressCount: 0,
      );
      expect(d, SwapGuardDecision.linked);
    });
  });
}
