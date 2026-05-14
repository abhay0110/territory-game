-- user_badges: time-bounded, server-awarded achievements.
--
-- Build +20 (Phase 1.4).  Awarded by a Supabase Edge Function on cron
-- (Sunday 23:00 UTC for weekly, last day of month 23:00 UTC for monthly).
--
-- Idempotency lives in the schema, not the job: PK (user_id, badge_key)
-- means a re-run of the awarder for the same period is a no-op.  This
-- is a hard requirement — cron jobs at this provider have at-least-once
-- delivery semantics, and we MUST NOT duplicate badges if the job is
-- retried after a transient timeout.
--
-- Per discipline rule #4 (backing data runs regardless of UI flag),
-- the UI gate `FeatureFlags.periodicBadgesUiEnabled` controls only
-- whether the ACHIEVEMENTS section renders.  Rows continue to be
-- written by the awarder regardless of any client flag state.

CREATE TABLE IF NOT EXISTS user_badges (
  user_id      UUID        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  badge_key    TEXT        NOT NULL,
  badge_type   TEXT        NOT NULL,   -- 'weekly_topN' | 'monthly_topN'
  trail_id     TEXT        NOT NULL,   -- e.g. 'burke_gilman'
  period_start DATE        NOT NULL,   -- first day of the awarded period (UTC)
  period_end   DATE        NOT NULL,   -- last  day of the awarded period (UTC, inclusive)
  rank         INT         NOT NULL CHECK (rank BETWEEN 1 AND 10),
  owned_tiles  INT         NOT NULL CHECK (owned_tiles >= 0),
  awarded_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, badge_key)
);

-- Lookup index for "show me my badges, newest first".
CREATE INDEX IF NOT EXISTS idx_user_badges_user_awarded
  ON user_badges (user_id, awarded_at DESC);

-- Lookup index for the awarder's "has this period already been awarded?"
-- check.  In the happy path the PK upsert handles this, but the index
-- speeds up out-of-band auditing.
CREATE INDEX IF NOT EXISTS idx_user_badges_period
  ON user_badges (badge_type, trail_id, period_start);

ALTER TABLE user_badges ENABLE ROW LEVEL SECURITY;

-- Anyone can read so we can show "Player X — Top 3 Burke-Gilman March
-- 2026" badges on shared profile views in a future build.  Writes are
-- service-role only (the Edge Function uses the service key).
CREATE POLICY "Anyone can read user badges"
  ON user_badges FOR SELECT
  USING (true);

-- No INSERT/UPDATE/DELETE policy is created.  Without a policy, RLS
-- denies all writes from authenticated/anon roles by default.  Only
-- the service role (used by the Edge Function) can write.

COMMENT ON TABLE user_badges IS
  'Phase 1.4 — periodic achievements awarded by a server cron job. PK enforces award-once-per-period idempotency.';
COMMENT ON COLUMN user_badges.badge_key IS
  'Stable identifier of the form "<badge_type>:<trail_id>:<period_iso>". Examples: "weekly_top3:burke_gilman:2026-W19", "monthly_top3:burke_gilman:2026-03".';
