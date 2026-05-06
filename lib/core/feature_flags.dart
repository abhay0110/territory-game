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
}
