/// Compile-time feature flags for unreleased UI surfaces.
///
/// Data collection for these features may already run in the
/// background — these flags only gate user-visible UI.  Toggle to true
/// to reveal a feature; commit the flip along with the rollout PR.
class FeatureFlags {
  FeatureFlags._();

  /// Founders Badge UI (pill, dialog, leaderboard chip).
  ///
  /// Award/claim happens silently from app launch regardless of this
  /// flag — see [FounderBadgeService].  The first 100 unique users get
  /// "Founder #N" recorded server-side from the day this ships.
  static const bool founderBadgeUiEnabled = false;

  /// "Save my progress" account-linking UI (Google + Apple Sign-In).
  ///
  /// When false, all account-link surfaces (post-session summary CTA and
  /// the overflow-menu "Save my progress" entry) are hidden and the app
  /// behaves identically to the anonymous-only flow.  Flip to true ONLY
  /// after Supabase Google + Apple OAuth providers are configured AND the
  /// platform-side OAuth client IDs are set in `IdentityLinkConfig`.
  ///
  /// Backing service: [IdentityLinkService].
  static const bool accountLinkUiEnabled = true;

  /// Capture-progress hint on the active-hex halo.
  ///
  /// When true, the halo around the player's currently-occupied capturable
  /// hex brightens proportionally to dwell progress (0% → 100%) so the user
  /// gets visual feedback that "the hex is charging up" before auto-capture
  /// fires.  When false, the halo behaves identically to today (slow
  /// 1.2s on/off pulse with no progress signal).
  ///
  /// Backing render path: [MapRenderService.drawActiveHexHaloProgress].
  static const bool captureProgressHintEnabled = true;

  /// Reconcile the local "captured by me" cache against server ground
  /// truth on every nearby-ownership refresh, pruning hexes that another
  /// player now owns (i.e. they took it from us while we were away).
  ///
  /// Without this, the local `capturedHexes` Set is only ever pruned in
  /// our own rollback paths — a takeover by another player leaves the
  /// hex stuck green forever in the map view, in tile details, and in
  /// every owned-tile counter (home stats / objectives / etc.).
  /// Leaderboard already queries the server directly so it stays correct,
  /// which is exactly what cross-device beta testing surfaced.
  ///
  /// Default ON (kill-switch).  Flip to false ONLY if the reconciliation
  /// causes spurious pruning under unforeseen race conditions; the
  /// reconcile path is intentionally conservative (only prunes when the
  /// server explicitly reports a *different* owner, never on null/missing).
  static const bool cacheReconciliationEnabled = true;

  /// Process inbound FCM `tile_lost` data payloads to invalidate the
  /// local capture cache the instant the push arrives, instead of waiting
  /// for the next periodic ownership refresh.  Pure UX speed-up — the
  /// reconciliation flag above is the safety net that makes correctness
  /// independent of FCM delivery.
  static const bool fcmTileLostInvalidationEnabled = true;

  // ───────────────────────────────────────────────────────────────────
  // Phase 1 — Solo retention features (post build 14/16).
  //
  // All default OFF until each feature is implemented + dogfooded on a
  // real trail walk.  Flip to true in the same commit that promotes the
  // feature to internal/closed builds.  Each flag gates ONLY user-visible
  // surfaces — backing data tables / triggers may run regardless so we
  // don't lose history while a flag is off.
  // See: /memories/repo/feature_roadmap_post_build16.md
  // ───────────────────────────────────────────────────────────────────

  /// Daily-capture streak counter on the home screen (with weekly freeze).
  /// Backing data accumulates from launch; flag only gates the UI.
  static const bool streakSystemEnabled = false;

  /// "Defended N times" badge on tiles you've reclaimed ≥3 times.
  /// Backing column on captured_tiles increments regardless of flag.
  static const bool defendedCountUiEnabled = false;

  /// Lifetime stats screen (captured / taken-over / defended / distance /
  /// days-played / longest-streak).  Backing user_stats table populated
  /// by Supabase trigger regardless of flag.
  static const bool lifetimeStatsUiEnabled = false;

  /// Permanent weekly + monthly badges (top-3 / streak / volume).
  /// Backing scheduled job awards badges regardless of flag once shipped;
  /// the flag only controls whether the profile timeline is rendered.
  /// DO NOT flip this on with retroactive pre-launch awards — see roadmap.
  static const bool periodicBadgesUiEnabled = false;

  /// Weekly recap push notification (Sunday eve).  Requires ≥2 weeks of
  /// per-user data to feel meaningful — do not flip on before then.
  static const bool weeklyRecapEnabled = false;
}
