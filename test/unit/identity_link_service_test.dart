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
}
