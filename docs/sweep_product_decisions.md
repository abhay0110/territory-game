# Sweep + Activity Import — Product Decisions

Status: **LOCKED** (May 16, 2026 — Q1-Q5 accepted as recommended)
Owner: Abhay
Required by: discipline rule for build +26 (Sweep Edge Function + GPX
upload). This doc is merged BEFORE sweep code lands.

Authoritative roadmap context:
`/memories/repo/feature_roadmap_post_build16.md` (Tester feedback —
May 14, 2026; "NORTH STAR locked May 15 2026").

---

## North Star (locked)

> **Live is the battlefield. Imports are fallback and convenience.
> Background location is a measured upgrade, not a panic move.**

Imports MUST be deliberately weaker than live sessions on the
dimensions that drive the emotional loop. If imports are at parity
with live, live engagement collapses and HexTrail becomes Wandrer
(passive coverage tracker) instead of a rivalry game.

---

## Live vs Import — asymmetry table (binding)

| Dimension | Live session | Imported activity |
|---|---|---|
| Capture credit (hex ownership) | Full | Full |
| Streak credit (Phase 1.1) | Yes | **No** (or half — see open Q1) |
| Monthly "first to capture" badges (Phase 1.4) | Yes | **No** |
| Monthly distance / coverage badges (Phase 1.4) | Yes | Yes |
| Per-trail leaderboard (today) | Yes | Yes, **flagged as imported** |
| Defensive bonus / rivalry multiplier (Phase 2/3) | Yes | **No** |
| Push notification on capture (tile_lost FCM) | Real-time | **Batched / silent** |
| Hex ownership `captured_at` timestamp | `now()` | `gpx.point.time` (first-rode-at) |
| Points-per-hex-per-time (Phase 3.1) | Full multiplier | **0.5x** (see open Q2) |
| Timed-event bonuses (Phase 3.4) | Eligible | **Not eligible** |
| Season leaderboard contribution (Phase 3.2) | Full | Full, flagged |

**Hard line:** "First to capture" and rivalry/defense multipliers are
EARNED IN THE MOMENT. Importing a 6-month-old GPX cannot retroactively
take a first-capture badge from a player who got there live.

---

## What sweep IS

A Supabase Edge Function `sweep` that accepts a stream of
`(timestamp, lat, lon, accuracy?)` points and emits hex captures with:
- accuracy filter (drop points with `accuracy > 50m`)
- off-trail rejection (point must lie within configured corridor or
  on-trail polygon — TBD per-trail)
- dedup (same hex within configured cooldown window → ignored)
- per-tile cooldown (a single import cannot re-capture the same hex
  more than 1x per `IMPORT_TILE_COOLDOWN`, default 24h)
- idempotent replay (same input → same output; safe to re-run)
- `source: gpx | strava | healthkit | healthconnect | garmin`
- `first_rode_at = min(point.time)` for each captured hex
- Audit row in `import_runs` table (user_id, source, points_in,
  hexes_captured, hexes_rejected, duration_ms, created_at)

## What sweep is NOT

- NOT a live capture path. Live captures continue to flow through
  `capture_service.dart` → `user_tile_captures` direct insert.
- NOT a backfill of pre-launch history. Imports are only valid from
  the date of user's first install onward (TBD: enforce in function
  or just discourage in UI?).
- NOT a way to claim streaks or first-captures retroactively.

---

## Sequencing within +26..+30

Per locked roadmap:
- **+26** — Sweep function + GPX upload + flag, dogfood only.
- **+27** — Sweep correctness hardening (off-trail, dedup, cooldown,
  accuracy, first-rode-at semantics, idempotent replay, tests).
- **+28** — Strava OAuth on the sweep.
- **+29** — HealthKit (Apple Watch + iPhone workouts) on the sweep.
- **+30** — Health Connect (Wear OS + Android fitness) on the sweep.
- **+31** — Garmin Connect API on the sweep.

GPX is foundation because every source funnels into one code path.
Building GPX first means Strava/HealthKit/HealthConnect/Garmin are
each ~1 week of OAuth + format-conversion, not ~1 month of full
pipeline.

---

## Flags

- `sweepImportEnabled` (NEW, default OFF) — gates the entire import
  UI (no upload button if false).
- `sweepImportGpxEnabled` (NEW, default OFF) — gates GPX source
  specifically. Allows shipping GPX dogfood while Strava lands later.
- Future per-source flags: `sweepStravaEnabled`, `sweepHealthKitEnabled`,
  `sweepHealthConnectEnabled`, `sweepGarminEnabled` — all default OFF
  until each source dogfooded.

Backing data (`import_runs`, sweep edge function deploys, RLS) always
on per discipline rule #4 — no UI-flag gate on schema.

---

## Privacy and trust

- Imported points are NOT stored beyond the sweep run. We persist
  hex captures + audit row, NOT raw GPS traces. (Open Q3: do we
  need to store raw traces for re-sweep when corridor definitions
  change?)
- iOS plist string shipped May 14 2026: "The app does not track your
  location in the background." Imports do not violate this — user
  explicitly uploads a file. No background tracking is added.
- App Review story for +26: "users can upload their existing GPX
  files to get hex credit for past rides." No new permissions
  requested. Zero review risk.

---

## Open questions (need decision before code)

1. **Streak credit on import: zero or half?**
   - Zero is cleaner ("streak = live discipline").
   - Half ("each imported day counts as 0.5") is more inclusive
     but encourages farming.
   - **Recommendation: zero.** Streak is the one purely-live
     mechanic. Keep it that way.

2. **Phase 3 points multiplier for imports: 0.5x or 0.0x?**
   - 0.5x keeps imports relevant to season ranking.
   - 0.0x makes live the only path to season leaderboard top.
   - **Recommendation: 0.5x.** Imports need to matter or no one
     uses them, but they must be strictly weaker than live.

3. **Raw GPS trace storage: keep or drop?**
   - Keep: enables re-sweep when corridor definitions evolve;
     enables future heatmap features.
   - Drop: lower privacy surface area; smaller storage footprint;
     "we don't store your traces" is a stronger marketing line.
   - **Recommendation: drop for +26.** Re-sweep is a Phase 4
     concern. Lean on input idempotence (user re-uploads if
     definitions change). Revisit when heatmap is on the table.

4. **Pre-install backfill: enforce or discourage?**
   - Enforce server-side: reject points older than user's
     `auth.users.created_at`.
   - Discourage in UI but allow: warning copy on upload, no
     server-side block.
   - **Recommendation: enforce server-side.** Cleaner story
     ("you can't claim hexes from before HexTrail existed"),
     prevents 10-year-archive dumps from skewing leaderboards.

5. **Per-trail leaderboard "imported" flag — UI placement?**
   - Asterisk next to count? Separate column? Tooltip on hover?
   - **Recommendation: subtle badge icon (📁) next to the count
     for any row where >50% of captures came from imports.**
     Defer detailed design to +27.

---

## Decisions (LOCKED May 16, 2026)

1. **Streak credit on import: ZERO.** Streak stays a purely-live
   mechanic. Imports do not advance or freeze a streak.
2. **Phase 3 points multiplier for imports: 0.5x.** Imports count
   toward season leaderboards at half rate of live captures.
3. **Raw GPS trace storage: DROP for +26.** Persist only hex
   captures + `import_runs` audit row. Re-sweep is a Phase 4
   concern; user can re-upload if corridor definitions change.
4. **Pre-install backfill: ENFORCE server-side.** Sweep rejects
   points whose `timestamp < auth.users.created_at` for the
   uploading user. Error surface: `rejected_pre_install` count
   in the audit row.
5. **Imported-row leaderboard flag: 📁 badge if >50% of a row's
   captures came from imports.** Detailed UI design deferred to
   +27.

---

## Sign-off

Once Abhay reviews and accepts (or amends) the recommendations on
Q1-Q5, this doc moves to status: **LOCKED**, and +26 implementation
begins:
1. New migration: `import_runs` table.
2. New edge function: `sweep/index.ts` skeleton.
3. New flag declarations in `lib/core/feature_flags.dart`.
4. GPX parser + unit tests in `lib/src/data/services/sweep/`.
5. Upload UI behind `sweepImportEnabled` (dogfood-only entry point).

NO source-side code (Strava OAuth etc.) until +27 onwards.
