# HexTrail — Project Context

> **For any AI assistant or new contributor:** read this file FIRST every
> session. It is the durable source of truth for what HexTrail is, the
> rules we work under, and the state of the codebase. Update it at the
> end of every shipped build.

Last updated: May 16, 2026 — +25 dogfood follow-ups built (Android AAB ready; pending internal-test dogfood before promotion).

---

## What HexTrail is

A Flutter mobile game where walking real-world trail segments captures
H3 hex tiles. Players accumulate territory along curated trails (today:
Burke-Gilman in Seattle), defend tiles, and compete on per-trail
leaderboards. Backend is Supabase (Postgres + Edge Functions + Auth);
maps are Mapbox; push is FCM.

**Differentiator:** territory + rivalry loop driven by physical
movement. Not AllTrails. Not a pedometer. Not a social app.

**Core loop:** walk → capture → defend → notice rivals → walk again.

---

## Critical codebase invariants (do not re-learn)

- **Package name is `HexTrail`**, not `territory_game`. Test imports
  use `package:HexTrail/...`. The repo folder name is historical.
- **Flutter 3.41.3 stable.** Dart SDK pinned via `pubspec.yaml`.
- **H3 (`h3_flutter`) requires a native dylib that unit tests cannot
  load.** Any code reachable from a unit test must NOT transitively
  import `seattle_trails.dart` or anything that pulls H3. Workaround:
  inline static maps (e.g. `_kTrailDisplayNames`) in services that
  need trail names.
- **Mapbox version `2.19.1`.** PointAnnotationManager via
  `_map.annotations.createPointAnnotationManager()`. Style race on iOS
  is mitigated — see `/memories/repo/ios_mapbox_race.md`.
- **Theme tokens** live in `lib/core/theme/game_ui_tokens.dart`:
  `bg0/bg1/bg2/textHi/textMid/textLow/accentPrimary/panelBorder` and
  `GameUiText.body/meta/command/objectiveTitle`. There is **no**
  `surfaceBase`, `surfaceRaised`, or `display` method.
- **Feature flags** live in `lib/core/feature_flags.dart`. Phase 1
  flags default to OFF until dogfooded.

---

## Discipline rules (locked — do not violate)

1. **Tagged baseline:** `v0.9.1+14 = 58074de` on `feat/account-link`.
   Use `git diff v0.9.1+14..HEAD path/...` for tester bug reports.
2. **Every Phase 1 feature gets a FeatureFlags toggle**, default OFF
   until dogfooded on a real trail walk.
3. **One feature per build.** No batched mega-PRs. Each build = own
   branch off the previous build's commit, own AAB, own commit.
4. **Backing data tables/triggers run regardless of UI flag** so we
   never lose history while a flag is off.
5. **`dart analyze lib/` must stay at 0 errors / 0 warnings.** Info
   lints baseline is ~93–94; new code should not increase it.
6. **Pure helpers are unit-tested without I/O.** Services that touch
   Supabase / FCM / Mapbox are wrapped around a pure inner function.
7. **Don't push branches without explicit ask.** Operational safety.
8. **Don't promote to closed/external testing** until 2–3 trail walks
   of personal dogfooding.

---

## Build history

| Build | SHA | Branch | Title | Flag (default OFF) |
|---|---|---|---|---|
| v0.9.1+14 | `58074de` | `feat/account-link` | Tagged baseline (account linking, FCM, halos, Mapbox race fix, pressure card, streak scaffold) | n/a |
| +15..+17 | (rolled into roadmap) | — | Phase 1.1 streak, 1.2a defended-count metadata, 1.3 streak server backup, 1.X reconcile wiring | streak/defendedCountUi/cacheReconciliation |
| +18 | (on `feat/account-link`) | `feat/account-link` | Pressure card rewrite + streak consolidated into Stats sheet | n/a |
| **+19** | `031dbb3` | `feat/phase1-2b-overlay` | Defended-count map overlay (SymbolLayer) | `defendedCountMapOverlayEnabled` |
| **+20** | `20b1c39` | `feat/phase1-4-badges` | Periodic badges (weekly/monthly server-awarded) | `periodicBadgesUiEnabled` |
| **+21** | `ead6d7a` | `feat/phase1-5-recap` | Weekly recap data + screen + FCM parser | `weeklyRecapEnabled` |
| **+22** | `002b604` | `feat/account-link` | Fix Apple sign-in stuck-anonymous menu state + iOS `NSLocationAlwaysAndWhenInUseUsageDescription` | n/a (bugfix) |
| **+24** | `ce60e9e` | `feat/wakelock-and-onhex-hint` | Wakelock during active session + on-hex auto-capture hint + sign-out menu item + lifecycle/wakelock event logging | `keepScreenOnDuringSessionEnabled` (default ON, kill-switch) |
| **+25** | `881027b` | `feat/build25-dogfood-followups` | Five dogfood follow-ups: anon re-sign-in race fix, tied-#1 pressure card, do-not-lock tooltip, set-name menu label, home account-link card | n/a (bugfixes + UX) |

All branches +19/+20/+21/+22/+24 are pushed to origin. **+25 is local-only** (Android AAB built, awaiting internal-test dogfood before push/promote).

**+24 promoted to internal + closed + external testing on May 15, 2026** (cleaned DB beforehand to remove stranded anon UIDs from pre-+24 dev — see `/memories/repo/build25_followups.md` item #1).

**+25 status (May 16, 2026):** Android AAB built, deploying to internal track for dogfood. Hold push + iOS pods + wider promotion until internal-test confirms anon-race fix (#1) actually stops the UID-respawn behavior and the home account-link card (#5) renders correctly on anon cold-start.

**Note:** there is no +23. Version skipped during the +24 build cut.

---

## Feature inventory (shipped + flag state)

| Feature | Where it lives | Flag | State |
|---|---|---|---|
| Account linking (Apple/Google) | `lib/src/data/services/identity_link_service.dart` | always on | shipped +14 |
| FCM tile_lost push | `lib/src/services/notification_service.dart` | always on | shipped +14 |
| Capture-progress halo | `map_screen.dart` `drawActiveHexHaloProgress` | always on | shipped +14 |
| iOS deferred corridor (Mapbox style race) | `map_render_service.dart` | always on | shipped +14 |
| Pressure card (rewritten) | `lib/features/pressure/territory_pressure_card.dart` + `pressureCardSummary()` | always on | shipped +18 |
| Daily-capture streak | `lib/src/data/services/streak_service.dart` + `_StreakPill` in Stats sheet | `streakSystemEnabled` | shipped +15 |
| Defended-count metadata | `add_defend_count_to_user_tile_captures.sql` + `GameTile.defendCount` | `defendedCountUiEnabled` | shipped +16 |
| Streak server backup | `add_user_streaks.sql` + `StreakService.mergeServerSnapshot()` | `streakServerBackupEnabled` | shipped +17 |
| Reconcile wiring (cache pruning) | `_reconcileLocalCapturesAgainst()` in capture service | `cacheReconciliationEnabled` | shipped +17 |
| Defended-count map overlay | `selectDefendBadges()` + `MapRenderService.updateDefendBadges()` | `defendedCountMapOverlayEnabled` | shipped +19 |
| Periodic badges | `add_user_badges.sql` + `award-periodic-badges` edge fn + `BadgeService` + ACHIEVEMENTS section | `periodicBadgesUiEnabled` | shipped +20 |
| Weekly recap | `lib/features/recap/{recap_summary,recap_data_loader,recap_screen}.dart` + `parseRecapPayload` | `weeklyRecapEnabled` | shipped +21 |
| Apple sign-in stuck-menu fix + iOS Always-location string | `IdentityLinkService` listener + `ios/Runner/Info.plist` | always on | shipped +22 |
| Wakelock during active session | `_acquireSessionWakelock`/`_releaseSessionWakelock` in `map_screen.dart` (start/stop/dispose); `wakelock_plus: ^1.2.8` | `keepScreenOnDuringSessionEnabled` (kill-switch, default ON) | shipped +24 |
| On-hex auto-capture hint | `tile_details_dialog.dart` `isOnThisHex` param + green hint container | always on | shipped +24 |
| Sign-out menu item | `_handleSignOut()` in `map_screen.dart`, both popup menus, confirmation-gated | always on | shipped +24 |
| Session lifecycle + wakelock event log | `MapEventType.{sessionBackgrounded,sessionForegrounded,wakelockAcquired,wakelockReleased,importInitiated,importCompleted}` | always on | shipped +24 |
| Anon session-restore race fix (await `initialSession`/`signedIn` before creating new anon) | `CaptureService.ensureSignedIn()` | always on | shipped +25 |
| Tied-#1 pressure card (defend headline on `lead == 0`) | `pressureCardSummary()` defend branch + unit test | always on | shipped +25 |
| Do-not-lock-the-phone session-start tooltip (once-only SnackBar) | `_maybeShowDoNotLockTooltip()` in `map_screen.dart` | gated on `keepScreenOnDuringSessionEnabled` | shipped +25 |
| Map-screen set-name menu label reflects current name | `_cachedDisplayName` + `_loadCachedDisplayName()` in `map_screen.dart`, both popup menus | always on | shipped +25 |
| Home-screen account-link affordance (dismissible card, 7-day re-nag) | `_SaveProgressCard` + `_refreshSaveProgressCardVisibility()` in `home_screen.dart` | gated on `accountLinkUiEnabled` | shipped +25 |

---

## Test inventory (226 tests, all passing as of +25)

*Note: prior count of "254" in the +21 update was stale; actual `flutter test` reports 226 passing + 1 skipped placeholder. +22 and +24 added no tests (I/O-bound auth / plugin / lifecycle code, intentionally not unit-tested per discipline rule #6). +25 modified `territory_pressure_card_test.dart` in place — the existing "tie with #2" case was rewritten to assert the new defend headline instead of null. Total count unchanged.*

Each test file guards a specific feature. Run `flutter test test/unit/`
to execute all. To run one: `flutter test test/unit/<file>.dart`.

| Test file | Guards |
|---|---|
| `badge_service_test.dart` | Periodic badges parsing + label formatting (1.4) |
| `capture_reconcile_test.dart` | Conservative cache pruning semantics (1.X) |
| `capture_service_wiring_test.dart` | Reconcile wiring at both call sites (1.X) |
| `defend_count_test.dart` | Defended-count model field + threshold (1.2a) |
| `edge_function_contract_test.dart` | tile_lost edge fn payload contract |
| `identity_link_service_test.dart` | Account linking flow |
| `map_controller_ordering_test.dart` | Map render call ordering |
| `milestone_evaluator_test.dart` | Capture milestones |
| `notification_payload_test.dart` | tile_lost FCM parser (`parseTileLostPayload`) |
| `objective_engine_service_test.dart` | Objective state machine |
| `protection_timing_test.dart` | Tile protection windows |
| `recap_payload_test.dart` | weekly_recap FCM parser (`parseRecapPayload`) (1.5) |
| `recap_summary_test.dart` | Recap builder + ISO week math + empty-state guard (1.5) |
| `recommendation_scoring_service_test.dart` | Trail recommendation |
| `select_defend_badges_test.dart` | Defend badge selection (1.2b) |
| `streak_service_test.dart` | Streak state machine + week math + server merge (1.1, 1.3) |
| `territory_pressure_card_test.dart` | Pressure card pure state machine (+18 rewrite) |

---

## Pending deploy steps (do these before flipping the corresponding flag)

### Build +19 — `defendedCountMapOverlayEnabled`
- No backend deploy needed. Flag flip is purely client.
- Dogfood on a real trail walk first.

### Build +20 — `periodicBadgesUiEnabled`
- [x] Apply `supabase/migrations/add_user_badges.sql` (DONE May 14 2026)
- [ ] Populate `TRAILS` hex array in
      `supabase/functions/award-periodic-badges/index.ts` (currently
      placeholder `[]`). Mirror `LaunchCorridor.displayHexes` for
      `burke_gilman`.
- [ ] `supabase functions deploy award-periodic-badges`
- [ ] Schedule cron triggers: Sun 23:00 UTC weekly mode, last-day-of-month 23:00 UTC monthly mode.
- [ ] Manually invoke once with mode=`weekly`; verify `user_badges` rows.
- [ ] Wait ≥1 week of real data, eyeball rows, THEN flip flag in +22 build.

### Build +21 — `weeklyRecapEnabled`
- [ ] Build a separate edge fn that emits FCM payload
      `{ event: 'weekly_recap', recapId: '<iso-week>' }` to opted-in
      `player_devices` Sunday evening.
- [ ] Add a top-level navigator hook on `weeklyRecapEvents` that pushes
      `RecapScreen.routeName`. (Intentionally NOT in +21 so a stray
      flag toggle cannot navigate users into an empty screen.)
- [ ] Verify ≥2 weeks of `user_tile_captures` data per active tester.
- [ ] Flip flag in a new build that also includes the navigator hook.

### Build +22 — Apple sign-in fix + iOS Always-location string
- No backend deploy needed. Pure client fix.
- iOS `Info.plist` now declares `NSLocationAlwaysAndWhenInUseUsageDescription` — required for App Store review even though we do NOT request `authorizationStatus.always` at runtime (we hold a wakelock instead, see +24).

### Build +24 — `keepScreenOnDuringSessionEnabled` + on-hex hint + sign-out
- Kill-switch flag, default ON. No flag flip needed for promote.
- **Personal dogfood gate (do BEFORE promote):** one Burke ride, pocket the phone, ride, stop session, confirm:
  1. distance > 0 and at least one hex captured (proves wakelock kept GPS alive),
  2. screen lock returns to normal after stop-session (proves no wakelock leak — the leak failure mode is the only real risk),
  3. on-hex info dialog shows the green "keep moving to auto-capture" hint when standing on a non-mine capturable hex.
- After dogfood: promote to internal, bake ~24h, then closed + external. Reply to tester ONLY after build is in their hands.
- Reminder: do NOT bundle a Phase 1 flag flip (+19 overlay, +20 badges, +21 recap) into the +24 promote — keep bisect target clean.
- **Outcome (May 15-16, 2026):** promoted to closed + external. Two independent dogfood signals (Abhay trail walk, wife) confirmed the wakelock UX is poor (screen-on friction). Roadmap updated to make +32 background-location non-conditional — see `/memories/repo/feature_roadmap_post_build16.md` "Dogfood signal on +24 wakelock" section.

### Build +25 — dogfood follow-ups
- Five small fixes bundled (see `/memories/repo/build25_followups.md` for spec). No backend deploy, no migrations, no flag flips.
- **Personal dogfood gate (do BEFORE pushing branch / promote):**
  1. Cold-start the Android build several times — same UID every time. Today's bug: 4 anon UIDs in 2 days on one device. Target: 1 UID, period. (Item #1.)
  2. Fresh-install on a clean device — home screen shows the new dismissible "Save your progress" card. Dismiss it. Cold-restart — should not re-show for 7 days. (Item #5.)
  3. Start a session for the first time on this install — SnackBar appears explaining don't-press-lock. Start another session same install — no SnackBar. (Item #3.)
  4. Open map popup menu after setting a display name — menu shows the name, not "Set display name…". (Item #4.)
  5. Tied-#1 pressure card requires two-device contrived state — lower priority gate (already unit-tested).
- After dogfood passes: push branch, `pod install` for iOS, build iOS IPA, promote to internal, bake, then closed + external.

---

## Active backlog (small chores)

- **Build +25 — BUILT, awaiting internal-test dogfood.** Android AAB on `feat/build25-dogfood-followups` SHA `881027b`. Branch local-only. iOS pods + IPA pending dogfood signal. See `/memories/repo/build25_followups.md` for the 5-item spec and this doc's "Build +25" section for the dogfood gate.
- **Activity import (GPX / Strava / Garmin / HealthKit / Health
  Connect).** The *real* fix for "my phone slept and I lost my ride."
  Wakelock (+24) is the interim. Multi-build effort — scope before
  starting. Priority justification: see
  `/memories/repo/background_location_roadmap.md`.
- **Background location (`Always Allow`) opt-in upgrade.** Shipped
  AFTER activity import, as a power-user upgrade. Multi-week App
  Store / Play Store review path. Full plan in
  `/memories/repo/background_location_roadmap.md`.
- **iOS IPAs via Xcode** for each branch when promoting to TestFlight.

---

## What's NOT being built (rejected / deferred)

- Heatmap of disputed zones (needs density)
- Achievements outside time-bounded badges (content treadmill)
- Friend system / social graph (leaderboard IS the social graph)
- Tile customization / flags / colors (vanity)
- In-app chat (moderation nightmare)
- Trail recommendations (that's AllTrails)
- Sunrise / location-gimmick badges (encourages farming)
- Daily badges (too noisy), yearly badges (too sparse)
- Retroactive badges for pre-launch periods (kills meaning)

See `/memories/repo/feature_roadmap_post_build16.md` for the full
roadmap including Phase 2 (rivalry) and beyond.

---

## How to come back after a week

1. Read this file.
2. `git log --oneline -20` to see recent commits.
3. `git branch -vv` to see local branches and which are unpushed.
4. `flutter test test/unit/` to confirm 254 pass.
5. `dart analyze lib/` to confirm 0 errors / 0 warnings.
6. Pick the next item from "Pending deploy steps" or "Active backlog".

If anything in this file is stale, update it before doing real work.
