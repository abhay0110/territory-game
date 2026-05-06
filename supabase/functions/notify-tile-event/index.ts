// Supabase Edge Function: notify-tile-event
//
// Sends an FCM push to the previous owner when their tile is taken, or to
// a player who lost control of a trail section.
//
// Hardening:
//   1. Verifies the caller's Supabase JWT (rejects unauthenticated callers).
//   2. Authorizes the caller as the current owner of the hex via
//      `tile_captures` before dispatching.
//   3. Uses the OAuth2 refresh-token flow to obtain FCM access tokens.
//      Tokens are cached in module scope and reused until near expiry.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

// ── Env ──────────────────────────────────────────────────────────────────

const SUPABASE_URL = requireEnv("SUPABASE_URL");
const SUPABASE_SERVICE_ROLE_KEY = requireEnv("SUPABASE_SERVICE_ROLE_KEY");
const FCM_PROJECT_ID = requireEnv("FCM_PROJECT_ID");
const FCM_CLIENT_ID = requireEnv("FCM_CLIENT_ID");
const FCM_CLIENT_SECRET = requireEnv("FCM_CLIENT_SECRET");
const FCM_REFRESH_TOKEN = requireEnv("FCM_REFRESH_TOKEN");

function requireEnv(name: string): string {
  const v = Deno.env.get(name);
  if (!v) throw new Error(`Missing required env var: ${name}`);
  return v;
}

// Admin client (service role, bypasses RLS).  Used for server-side lookups
// and for verifying the caller's JWT via `auth.getUser()`.
const supabaseAdmin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { autoRefreshToken: false, persistSession: false },
});

// ── CORS ─────────────────────────────────────────────────────────────────

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// ── OAuth2 refresh-token → access token (cached) ─────────────────────────

let cachedAccessToken: { token: string; expiresAt: number } | null = null;

async function getFCMAccessToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedAccessToken && cachedAccessToken.expiresAt - 60 > now) {
    return cachedAccessToken.token;
  }

  const resp = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: FCM_CLIENT_ID,
      client_secret: FCM_CLIENT_SECRET,
      refresh_token: FCM_REFRESH_TOKEN,
      grant_type: "refresh_token",
    }),
  });
  const data = await resp.json();
  if (!resp.ok || !data.access_token) {
    throw new Error(`Token exchange failed: ${JSON.stringify(data)}`);
  }

  cachedAccessToken = {
    token: data.access_token,
    expiresAt: now + (data.expires_in ?? 3600),
  };
  return cachedAccessToken.token;
}

// ── FCM send ─────────────────────────────────────────────────────────────

async function sendFCMNotification(
  accessToken: string,
  fcmToken: string,
  title: string,
  body: string,
  data?: Record<string, string>,
): Promise<void> {
  const response = await fetch(
    `https://fcm.googleapis.com/v1/projects/${FCM_PROJECT_ID}/messages:send`,
    {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        message: {
          token: fcmToken,
          notification: { title, body },
          data: data ?? {},
          android: {
            priority: "high",
            notification: { sound: "default", channel_id: "hextrail_default" },
          },
          apns: { payload: { aps: { sound: "default", badge: 1 } } },
        },
      }),
    },
  );

  if (!response.ok) {
    const errText = await response.text();
    if (errText.includes("UNREGISTERED") || errText.includes("INVALID_ARGUMENT")) {
      throw new Error(`STALE_TOKEN: ${errText}`);
    }
    throw new Error(`FCM send failed: ${errText}`);
  }
}

// ── Request handler ──────────────────────────────────────────────────────

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    // ── 1. Authenticate caller via JWT ──
    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      return json({ success: false, reason: "unauthenticated" }, 401);
    }
    const jwt = authHeader.slice("Bearer ".length);

    const { data: userData, error: userErr } =
      await supabaseAdmin.auth.getUser(jwt);
    if (userErr || !userData?.user) {
      return json({ success: false, reason: "invalid_token" }, 401);
    }
    const callerId = userData.user.id;

    // ── 2. Parse & validate payload ──
    if (!req.headers.get("content-type")?.includes("application/json")) {
      return json({ success: false, reason: "bad_content_type" }, 400);
    }
    let payload: Record<string, unknown>;
    try {
      payload = await req.json();
    } catch {
      return json({ success: false, reason: "bad_json" }, 400);
    }

    // Accept both snake_case (current client) and camelCase (legacy) keys.
    const type = String(payload.type ?? payload.event ?? "");
    const targetUserId = String(
      payload.target_user_id ?? payload.targetPlayerId ?? "",
    );
    const h3Hex = String(payload.h3_hex ?? payload.hexId ?? "").toLowerCase();

    if (type !== "tile_lost" && type !== "section_lost") {
      return json({ success: false, reason: "unknown_event" }, 400);
    }
    if (!UUID_RE.test(targetUserId)) {
      return json({ success: false, reason: "bad_target_id" }, 400);
    }
    if (targetUserId === callerId) {
      return json({ success: false, reason: "cannot_notify_self" }, 400);
    }

    // ── 3. Authorize: caller must actually own the hex for tile_lost ──
    if (type === "tile_lost") {
      if (!h3Hex || !/^[0-9a-f]+$/.test(h3Hex)) {
        return json({ success: false, reason: "bad_hex" }, 400);
      }
      const { data: ownerRow, error: ownerErr } = await supabaseAdmin
        .from("tile_captures")
        .select("owner_user_id")
        .eq("h3_hex", h3Hex)
        .maybeSingle();
      if (ownerErr) {
        console.error("tile_captures lookup failed", {
          callerId,
          h3Hex,
          error: ownerErr.message,
        });
        return json({ success: false, reason: "lookup_failed" }, 500);
      }
      if (!ownerRow || ownerRow.owner_user_id !== callerId) {
        return json({ success: false, reason: "not_current_owner" }, 403);
      }
    }

    // ── 4. Look up the target's FCM token ──
    const { data: deviceData, error: deviceError } = await supabaseAdmin
      .from("player_devices")
      .select("fcm_token")
      .eq("player_id", targetUserId)
      .maybeSingle();

    if (deviceError) {
      console.error("player_devices lookup failed", {
        targetUserId,
        error: deviceError.message,
      });
      return json({ success: false, reason: "lookup_failed" }, 500);
    }
    if (!deviceData?.fcm_token) {
      return json({ success: false, reason: "no_token" }, 200);
    }

    // ── 5. Compose & send ──
    const accessToken = await getFCMAccessToken();

    const { title, body } = type === "tile_lost"
        ? {
            title: "Tile captured",
            body:
              "Someone just took one of your Burke-Gilman tiles. Take it back.",
          }
        : {
            title: "Section lost",
            body:
              "You've lost control of a Burke-Gilman section. Get back on the trail.",
          };

    try {
      await sendFCMNotification(
        accessToken,
        deviceData.fcm_token,
        title,
        body,
        { event: type, hexId: h3Hex },
      );
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      if (msg.startsWith("STALE_TOKEN")) {
        // Only remove the specific stale token, not all devices for the user.
        await supabaseAdmin
          .from("player_devices")
          .delete()
          .eq("fcm_token", deviceData.fcm_token);
      }
      console.error("FCM send failed", { targetUserId, type, error: msg });
      return json({ success: false, reason: "send_failed" }, 500);
    }

    return json({ success: true }, 200);
  } catch (error) {
    const msg = error instanceof Error ? error.message : String(error);
    console.error("notify-tile-event fatal:", msg);
    return json({ success: false, error: msg }, 500);
  }
});

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
