# Account Link (Sign in with Google / Apple) — Setup Checklist

This document is the operator runbook for turning on the
`accountLinkUiEnabled` feature flag.  Until every step here is complete and
verified, leave `FeatureFlags.accountLinkUiEnabled = false`.

## Architecture (one-line)

`auth.signInWithIdToken()` on Supabase, called against an existing
**anonymous** session, attaches the new Google/Apple identity to the
**same** `auth.users.id`.  Every FK that references that uid
(`tile_captures.owner_user_id`, `profiles.user_id`, `founder_badges.user_id`,
`player_devices.player_id`, etc.) carries over with **zero data
migration**.  On a fresh install (no anon session present), the same call
signs the user in to the existing account that already owns that
identity — same uid, same data.

## 1. Supabase dashboard

Project → **Authentication → Providers**:

- Enable **Google**
  - Paste the **Web client ID** and **Web client secret** from Google
    Cloud Console (step 2).
  - Authorized client IDs: also paste the **iOS client ID** and (if used)
    the **Android client ID** so id_tokens minted for those clients are
    accepted.
- Enable **Apple**
  - Paste the Apple **Services ID** (step 3) as the client ID.
  - **Authorized client IDs** (additional aud values): also paste the iOS
    app **bundle ID** `com.hextrail.app`.  This is required because the
    native Sign in with Apple flow on iOS issues an `id_token` whose
    `aud` claim is the app bundle ID, NOT the Services ID.  Without
    this, sign-in fails with
    `unacceptable audience in id_token: com.hextrail.app`.
  - Generate an Apple **client secret JWT** per Supabase docs and paste
    it in.
  - Set redirect URL: `https://<project-ref>.supabase.co/auth/v1/callback`
    (this URL must also be registered with Apple — step 3).

## 2. Google Cloud Console

Project → **APIs & Services → Credentials**:

1. **OAuth consent screen** — production, add `email` + `profile` scopes.
2. **Web application** OAuth client
   - Authorized redirect URI:
     `https://<project-ref>.supabase.co/auth/v1/callback`
   - Copy **Client ID** → put in `IdentityLinkConfig.googleWebClientId`
     and Supabase dashboard.
3. **iOS** OAuth client
   - Bundle ID: `com.hextrail.app`
   - Copy **Client ID** → put in `IdentityLinkConfig.googleIosClientId`.
   - Add the reversed-client-id URL scheme to `ios/Runner/Info.plist`:
     ```xml
     <key>CFBundleURLTypes</key>
     <array>
       <dict>
         <key>CFBundleURLSchemes</key>
         <array>
           <string>com.googleusercontent.apps.<REVERSED_CLIENT_ID></string>
         </array>
       </dict>
     </array>
     ```
4. **Android** OAuth client
   - Package name: `com.hextrail.app` (verify in
     `android/app/build.gradle.kts`).
   - SHA-1 of the **release upload** keystore (run
     `keytool -list -v -keystore <upload-keystore>` and copy the SHA-1).
   - Also add the **Play App Signing** SHA-1 from Play Console →
     Setup → App integrity → App signing key certificate.
   - No client ID needs to be embedded in the app for Android — the web
     client ID is used as `serverClientId` to receive an id_token.

## 3. Apple Developer

1. **Identifiers → App IDs** — confirm `com.hextrail.app` has the
   "Sign in with Apple" capability checked.
2. **Identifiers → Services IDs** — create a new Services ID
   (e.g. `com.hextrail.app.signin`) with Sign in with Apple enabled.
   - Primary App ID: `com.hextrail.app`.
   - Domain: `<project-ref>.supabase.co`.
   - Return URL:
     `https://<project-ref>.supabase.co/auth/v1/callback`
   - Copy the Services ID identifier → put in
     `IdentityLinkConfig.appleServiceId` and Supabase dashboard.
3. **Keys** — create a new key with Sign in with Apple enabled, download
   the `.p8`.  Use it together with your Team ID + Key ID to mint the
   client-secret JWT Supabase wants (their docs include a one-liner
   script).

## 4. Native project plumbing

### iOS (`ios/Runner.xcodeproj`)
- Open in Xcode → Runner target → **Signing & Capabilities** →
  add capability **Sign in with Apple**.
- Verify the Google reversed-client-id URL scheme is present (step 2.3).

### Android (`android/app/src/main/AndroidManifest.xml`)
- No additional intent filter required for Google Sign-In with the
  `google_sign_in` plugin (it uses the Credential Manager).
- For Apple sign-in on Android (web fallback), add:
  ```xml
  <intent-filter android:autoVerify="true">
    <action android:name="android.intent.action.VIEW" />
    <category android:name="android.intent.category.DEFAULT" />
    <category android:name="android.intent.category.BROWSABLE" />
    <data
      android:scheme="https"
      android:host="hextrail.app"
      android:pathPrefix="/auth/callback" />
  </intent-filter>
  ```
  (Optional — only required if Android users will use Apple sign-in.)

## 5. Populate the config

Edit `lib/src/data/services/identity_link_service.dart` →
`IdentityLinkConfig`:

```dart
static const String? googleIosClientId  = '<from step 2.3>';
static const String? googleWebClientId  = '<from step 2.2>';
static const String? appleServiceId     = '<from step 3.2>';
```

These are not secrets (they ship in the binary) so committing them is
fine.

## 6. Flip the flag

Edit `lib/core/feature_flags.dart`:

```dart
static const bool accountLinkUiEnabled = true;
```

## 7. Smoke test (must pass before merging to main)

- [ ] Fresh install on iOS device → start session → capture 1 hex →
      end session → tap "Continue with Apple" on the summary card →
      sign in → check `auth.users` row in Supabase has same uid before
      and after, with a new row in `auth.identities` for `apple`.
- [ ] Fresh install on Android device → same flow with Google.
- [ ] Linked user uninstalls + reinstalls → on next launch, the
      "Save my progress" CTA does **not** auto-trigger.  User opens
      overflow menu → "Save my progress…" → signs in with same provider →
      previous display name + captured hex count return.
- [ ] User who declines (taps "Maybe later") on the summary card is not
      re-prompted in the same session.
- [ ] Mid-ride: confirm the CTA never appears during an active session.
      It is wired only to the post-session summary card and the
      overflow menu — not to objectives, milestones, or capture toasts.

## 8. Rollback

The change is fully revertable:
- **Soft revert:** set `accountLinkUiEnabled = false`, ship a build.
  All UI hooks become inert; `IdentityLinkService` is dead code.  No
  data is lost.
- **Hard revert:** `git revert` the merge commit of `feat/account-link`.
  Already-linked users keep their links (they live in Supabase, not in
  the app), they just lose the in-app entry point.
