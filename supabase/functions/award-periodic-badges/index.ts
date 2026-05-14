// Supabase Edge Function: award-periodic-badges
//
// Build +20 / Phase 1.4.  Awards weekly + monthly "Top N on <trail>"
// badges by writing rows into the `user_badges` table.  Triggered by a
// Supabase scheduled trigger:
//
//   * Weekly  : Sunday 23:00 UTC      → mode=weekly  (awards prior ISO week)
//   * Monthly : Last day of month 23:00 UTC → mode=monthly (awards just-finished month)
//
// Idempotency:
//   * Award rows use PK (user_id, badge_key).  We INSERT … ON CONFLICT
//     DO NOTHING, so re-running for the same period is a strict no-op.
//   * The job has at-least-once delivery; the upsert guarantees
//     at-most-once visible award.
//
// Authorization:
//   * Invoker must present the SUPABASE_SERVICE_ROLE_KEY in the
//     Authorization header.  Public callers cannot trigger awards.
//
// This function is intentionally minimal — it queries `tile_captures`,
// computes top-N owners per trail for the period, and writes badges.
// The award logic is a pure derivation of capture state at the time of
// invocation; if a tile was captured-then-lost during the period, the
// owner at the time of the cron run is what counts.  (A later build
// can switch to a period-snapshot model if testers complain.)

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL = requireEnv("SUPABASE_URL");
const SUPABASE_SERVICE_ROLE_KEY = requireEnv("SUPABASE_SERVICE_ROLE_KEY");

function requireEnv(name: string): string {
  const v = Deno.env.get(name);
  if (!v) throw new Error(`Missing required env var: ${name}`);
  return v;
}

const supabaseAdmin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { autoRefreshToken: false, persistSession: false },
});

// Hard-coded trail definitions matching the client.  When a new trail
// is added on the client, add the corresponding entry here and re-deploy.
// Keeping this hard-coded (vs. reading from a `trails` table) avoids
// schema churn for a list that turns over every few months at most.
const TRAILS: Array<{ id: string; hexes: string[] }> = [
  // Burke-Gilman corridor hexes — copy of LaunchCorridor.displayHexes
  // from the client.  Kept in sync manually; stale entries award
  // wrong badges, so any client-side corridor edit MUST be mirrored
  // here in the same PR.
  {
    id: "burke_gilman",
    hexes: [
      // NB: full list is large (~600 hexes).  In production this is
      // populated via a build script that imports the same constant
      // the client uses; for the +20 scaffold we leave a placeholder
      // and rely on the deployment step to fill it in.
    ],
  },
];

const TOP_N = 3;

interface AwardCandidate {
  user_id: string;
  owned_tiles: number;
  rank: number;
}

serve(async (req) => {
  // Authz: require the service-role key.  This function MUST NOT be
  // callable by end users — they could trigger awards out-of-period.
  const auth = req.headers.get("authorization") ?? "";
  if (auth !== `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`) {
    return new Response("Unauthorized", { status: 401 });
  }

  let mode: "weekly" | "monthly";
  try {
    const body = await req.json();
    mode = body.mode === "monthly" ? "monthly" : "weekly";
  } catch (_) {
    mode = "weekly";
  }

  const period = computePeriod(mode, new Date());

  let totalInserted = 0;
  for (const trail of TRAILS) {
    if (trail.hexes.length === 0) continue;
    const top = await topOwnersForTrail(trail.hexes, TOP_N);
    for (const candidate of top) {
      const badgeKey = `${mode}_top${TOP_N}:${trail.id}:${period.iso}`;
      const { error } = await supabaseAdmin
        .from("user_badges")
        .insert({
          user_id: candidate.user_id,
          badge_key: badgeKey,
          badge_type: `${mode}_top${TOP_N}`,
          trail_id: trail.id,
          period_start: period.start,
          period_end: period.end,
          rank: candidate.rank,
          owned_tiles: candidate.owned_tiles,
        })
        .select()
        .maybeSingle();
      // PK conflict (re-run) returns a "duplicate key" error which is
      // expected; only surface unexpected errors.
      if (error && !error.message.includes("duplicate key")) {
        console.error("[award-periodic-badges] insert failed", {
          badgeKey,
          err: error.message,
        });
        continue;
      }
      if (!error) totalInserted += 1;
    }
  }

  return new Response(
    JSON.stringify({
      mode,
      period: period.iso,
      trails: TRAILS.length,
      inserted: totalInserted,
    }),
    { headers: { "content-type": "application/json" } },
  );
});

// ── Helpers ──────────────────────────────────────────────────────────────

interface PeriodInfo {
  iso: string; // e.g. "2026-W19" or "2026-03"
  start: string; // YYYY-MM-DD (UTC)
  end: string;   // YYYY-MM-DD (UTC, inclusive)
}

function computePeriod(mode: "weekly" | "monthly", now: Date): PeriodInfo {
  if (mode === "weekly") {
    // Award the JUST-ENDED ISO week.  Sunday 23:00 UTC cron fires while
    // we are still inside that week's Sunday — back up one day so we
    // capture the week that just finished cleanly.
    const ref = new Date(now.getTime() - 24 * 60 * 60 * 1000);
    const { year, week, monday } = isoWeek(ref);
    const sunday = new Date(monday.getTime() + 6 * 24 * 60 * 60 * 1000);
    return {
      iso: `${year}-W${String(week).padStart(2, "0")}`,
      start: ymd(monday),
      end: ymd(sunday),
    };
  }
  // Monthly: the cron fires on the LAST day of the month, so the month
  // we just finished is `now.getUTCMonth()`.
  const year = now.getUTCFullYear();
  const month = now.getUTCMonth(); // 0-11
  const start = new Date(Date.UTC(year, month, 1));
  const end = new Date(Date.UTC(year, month + 1, 0));
  return {
    iso: `${year}-${String(month + 1).padStart(2, "0")}`,
    start: ymd(start),
    end: ymd(end),
  };
}

function isoWeek(d: Date): { year: number; week: number; monday: Date } {
  // Standard ISO 8601 week computation (Thursday-anchored).
  const utc = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()));
  const dow = utc.getUTCDay() || 7; // 1..7, Mon..Sun
  utc.setUTCDate(utc.getUTCDate() + 4 - dow); // shift to Thursday of this week
  const yearStart = new Date(Date.UTC(utc.getUTCFullYear(), 0, 1));
  const week = Math.ceil(((utc.getTime() - yearStart.getTime()) / 86400000 + 1) / 7);
  // Monday of the original week.
  const monday = new Date(d);
  monday.setUTCHours(0, 0, 0, 0);
  monday.setUTCDate(monday.getUTCDate() - ((monday.getUTCDay() || 7) - 1));
  return { year: utc.getUTCFullYear(), week, monday };
}

function ymd(d: Date): string {
  return d.toISOString().slice(0, 10);
}

async function topOwnersForTrail(
  hexes: string[],
  topN: number,
): Promise<AwardCandidate[]> {
  // Batch the IN filter to stay under PostgREST URL limits.
  const counts = new Map<string, number>();
  const batchSize = 200;
  for (let i = 0; i < hexes.length; i += batchSize) {
    const batch = hexes.slice(i, i + batchSize);
    const { data, error } = await supabaseAdmin
      .from("tile_captures")
      .select("h3_hex, owner_user_id")
      .eq("h3_res", 9)
      .in("h3_hex", batch);
    if (error) {
      console.error("[award-periodic-badges] fetch batch failed", error.message);
      continue;
    }
    for (const row of data ?? []) {
      const owner = (row as { owner_user_id?: string | null }).owner_user_id;
      if (!owner) continue;
      counts.set(owner, (counts.get(owner) ?? 0) + 1);
    }
  }
  const ranked = [...counts.entries()]
    .map(([user_id, owned_tiles]) => ({ user_id, owned_tiles }))
    .sort((a, b) => b.owned_tiles - a.owned_tiles)
    .slice(0, topN);
  return ranked.map((r, i) => ({ ...r, rank: i + 1 }));
}
