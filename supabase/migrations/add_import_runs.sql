-- import_runs: audit log of activity-import sweep runs.
--
-- Build +26 (sweep + GPX foundation).  One row per upload attempt.
-- Raw GPS traces are intentionally NOT stored (decision Q3 in
-- docs/sweep_product_decisions.md, LOCKED May 16 2026) — only the
-- aggregate audit counters that let us debug a complaint like "I
-- uploaded a 50km ride and only got 4 hexes."
--
-- Per discipline rule #4 (backing data runs regardless of UI flag),
-- this table is populated by the `sweep` Edge Function whenever it
-- accepts a request, independent of the client-side
-- `FeatureFlags.sweepImportEnabled` gate.

CREATE TABLE IF NOT EXISTS import_runs (
  id                    UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id               UUID        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  source                TEXT        NOT NULL,
    -- 'gpx' | 'strava' | 'healthkit' | 'healthconnect' | 'garmin'
  points_in             INT         NOT NULL CHECK (points_in >= 0),
  points_after_accuracy INT         NOT NULL CHECK (points_after_accuracy >= 0),
  points_after_window   INT         NOT NULL CHECK (points_after_window >= 0),
    -- After pre-install backfill rejection (Q4): points whose
    -- timestamp >= auth.users.created_at for this user.
  hexes_captured        INT         NOT NULL CHECK (hexes_captured >= 0),
  hexes_rejected_offtrail INT       NOT NULL DEFAULT 0 CHECK (hexes_rejected_offtrail >= 0),
  hexes_rejected_cooldown INT       NOT NULL DEFAULT 0 CHECK (hexes_rejected_cooldown >= 0),
  rejected_pre_install  INT         NOT NULL DEFAULT 0 CHECK (rejected_pre_install >= 0),
  duration_ms           INT         NOT NULL CHECK (duration_ms >= 0),
  status                TEXT        NOT NULL,
    -- 'success' | 'partial' | 'failed'
  error_message         TEXT,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- "Show me my recent imports" — newest first per user.
CREATE INDEX IF NOT EXISTS idx_import_runs_user_created
  ON import_runs (user_id, created_at DESC);

-- Operational lookup: "which imports failed in the last 24h?"
CREATE INDEX IF NOT EXISTS idx_import_runs_status_created
  ON import_runs (status, created_at DESC)
  WHERE status <> 'success';

ALTER TABLE import_runs ENABLE ROW LEVEL SECURITY;

-- Users can read their own import audit rows.
CREATE POLICY "Users can read their own import runs"
  ON import_runs FOR SELECT
  USING (auth.uid() = user_id);

-- No INSERT/UPDATE/DELETE policy created.  Without a policy, RLS
-- denies all writes from authenticated/anon roles by default.  Only
-- the `sweep` Edge Function (service-role key) writes to this table.

COMMENT ON TABLE import_runs IS
  'Audit log of sweep Edge Function runs.  See docs/sweep_product_decisions.md.';
