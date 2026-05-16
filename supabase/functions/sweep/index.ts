// Supabase Edge Function: sweep
//
// Build +26.  Foundation only: accepts a stream of activity points
// from any source (GPX/Strava/HealthKit/HealthConnect/Garmin), parses
// + validates the wire shape, enforces pre-install backfill rejection
// (Q4 in docs/sweep_product_decisions.md), and writes an `import_runs`
// audit row.
//
// CORRECTNESS HARDENING IS DELIBERATELY DEFERRED TO +27.  In +26 the
// function does NOT yet:
//   * Compute H3 cells from the point stream.
//   * Apply off-trail rejection.
//   * Apply per-tile cooldown / dedup.
//   * Apply accuracy filter.
//   * Write rows into user_tile_captures.
// All of the above lands in +27 (see roadmap +26..+27 split).
//
// Why ship it this thin: the wire contract is the riskiest part to
// change later.  Locking the request/response shape now means client
// dogfood (upload UX, error states, "we got your file" messaging)
// can iterate independently of server correctness work.
//
// Authorization: caller must present a valid user JWT in the
// Authorization header.  Anonymous Supabase users qualify.  The
// function rejects unauthenticated requests with 401.

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

type Source = "gpx" | "strava" | "healthkit" | "healthconnect" | "garmin";

const VALID_SOURCES: ReadonlySet<Source> = new Set([
  "gpx",
  "strava",
  "healthkit",
  "healthconnect",
  "garmin",
]);

interface InputPoint {
  ts: string; // ISO-8601
  lat: number;
  lon: number;
  accuracy?: number; // metres; optional
}

interface SweepRequest {
  source: Source;
  points: InputPoint[];
}

interface SweepResponse {
  import_run_id: string;
  source: Source;
  points_in: number;
  points_after_accuracy: number;
  points_after_window: number;
  hexes_captured: number;
  rejected_pre_install: number;
  status: "success" | "partial" | "failed";
  message: string;
}

// Hard ceiling to keep request size and edge-function CPU bounded.  A
// 6h ride at 1Hz is ~22k points; a 24h ultramarathon at 1Hz is ~86k.
// Conservative ceiling for +26 dogfood.
const MAX_POINTS_PER_REQUEST = 100_000;

serve(async (req: Request) => {
  const t0 = Date.now();

  if (req.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  // Resolve the caller from the Authorization header.
  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader.toLowerCase().startsWith("bearer ")) {
    return json({ error: "missing_bearer" }, 401);
  }
  const token = authHeader.slice("bearer ".length).trim();
  const { data: userData, error: userErr } =
    await supabaseAdmin.auth.getUser(token);
  if (userErr || !userData?.user) {
    return json({ error: "invalid_token" }, 401);
  }
  const userId = userData.user.id;
  const userCreatedAt = userData.user.created_at
    ? Date.parse(userData.user.created_at)
    : null;

  // Parse + validate body.
  let body: SweepRequest;
  try {
    body = (await req.json()) as SweepRequest;
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  if (!body || !VALID_SOURCES.has(body.source)) {
    return json({ error: "invalid_source" }, 400);
  }
  if (!Array.isArray(body.points)) {
    return json({ error: "points_not_array" }, 400);
  }
  if (body.points.length > MAX_POINTS_PER_REQUEST) {
    return json({ error: "too_many_points", limit: MAX_POINTS_PER_REQUEST }, 413);
  }

  const pointsIn = body.points.length;

  // Filter A — shape validation (no accuracy gate yet; +27 work).
  const shapeValid = body.points.filter(
    (p) =>
      typeof p.ts === "string" &&
      typeof p.lat === "number" &&
      typeof p.lon === "number" &&
      p.lat >= -90 &&
      p.lat <= 90 &&
      p.lon >= -180 &&
      p.lon <= 180 &&
      !Number.isNaN(Date.parse(p.ts)),
  );

  // Filter B — pre-install backfill rejection (Q4 locked).  Points
  // whose ts < user.created_at are dropped and counted separately.
  let rejectedPreInstall = 0;
  const inWindow = shapeValid.filter((p) => {
    if (userCreatedAt == null) return true;
    if (Date.parse(p.ts) < userCreatedAt) {
      rejectedPreInstall++;
      return false;
    }
    return true;
  });

  // +26 SCAFFOLD: hex capture writing is deferred to +27.  We report
  // zero hexes captured but still write the audit row so the client
  // can verify round-trip end-to-end.
  const hexesCaptured = 0;
  const durationMs = Date.now() - t0;
  const status: SweepResponse["status"] = "success";

  const { data: auditRow, error: auditErr } = await supabaseAdmin
    .from("import_runs")
    .insert({
      user_id: userId,
      source: body.source,
      points_in: pointsIn,
      points_after_accuracy: shapeValid.length,
      points_after_window: inWindow.length,
      hexes_captured: hexesCaptured,
      hexes_rejected_offtrail: 0,
      hexes_rejected_cooldown: 0,
      rejected_pre_install: rejectedPreInstall,
      duration_ms: durationMs,
      status,
    })
    .select("id")
    .single();

  if (auditErr || !auditRow) {
    return json(
      { error: "audit_write_failed", detail: auditErr?.message },
      500,
    );
  }

  const response: SweepResponse = {
    import_run_id: auditRow.id as string,
    source: body.source,
    points_in: pointsIn,
    points_after_accuracy: shapeValid.length,
    points_after_window: inWindow.length,
    hexes_captured: hexesCaptured,
    rejected_pre_install: rejectedPreInstall,
    status,
    message:
      "Upload received and audited. Hex capture from imports lands in build +27.",
  };

  return json(response, 200);
});

function json(payload: unknown, status: number): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "content-type": "application/json" },
  });
}
