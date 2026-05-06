-- founder_badges: hard-capped 100 "Founder #N" badges, awarded in order
-- of first claim.  Once 100 rows exist, claim_founder_badge() returns
-- NULL forever.
--
-- Awarding is idempotent: a user who already holds a badge gets back
-- their existing row.  Numbers are gap-free (1..N, no skipped values).

CREATE TABLE IF NOT EXISTS founder_badges (
  user_id        UUID        PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  founder_number INT         NOT NULL UNIQUE,
  awarded_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT founder_number_range CHECK (founder_number BETWEEN 1 AND 100)
);

CREATE INDEX IF NOT EXISTS idx_founder_badges_number
  ON founder_badges (founder_number);

ALTER TABLE founder_badges ENABLE ROW LEVEL SECURITY;

-- Anyone can read so we can show "Founder #042" badges on shared
-- leaderboards / profiles.  No direct writes — all mutations go through
-- the SECURITY DEFINER claim function.
CREATE POLICY "Anyone can read founder badges"
  ON founder_badges FOR SELECT
  USING (true);

-- Atomic, race-safe claim.  Locks the table briefly to guarantee that
-- two concurrent first-launches cannot both receive the same number.
-- Returns the awarded row, or NULL if the cap has been reached.
CREATE OR REPLACE FUNCTION claim_founder_badge()
RETURNS founder_badges
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  caller UUID := auth.uid();
  existing founder_badges;
  next_number INT;
  total_count INT;
  inserted founder_badges;
BEGIN
  IF caller IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  -- Fast path: already a founder.
  SELECT * INTO existing FROM founder_badges WHERE user_id = caller;
  IF FOUND THEN
    RETURN existing;
  END IF;

  -- Slow path: serialize new awards behind a table-level lock so the
  -- numbering stays gap-free under concurrency.  This lock is held for
  -- the duration of one INSERT — microseconds in practice.
  LOCK TABLE founder_badges IN SHARE ROW EXCLUSIVE MODE;

  -- Re-check after acquiring the lock in case another tx awarded one.
  SELECT * INTO existing FROM founder_badges WHERE user_id = caller;
  IF FOUND THEN
    RETURN existing;
  END IF;

  SELECT COUNT(*) INTO total_count FROM founder_badges;
  IF total_count >= 100 THEN
    RETURN NULL;  -- Cap reached.
  END IF;

  next_number := total_count + 1;

  INSERT INTO founder_badges (user_id, founder_number)
  VALUES (caller, next_number)
  RETURNING * INTO inserted;

  RETURN inserted;
END;
$$;

-- Allow authenticated users (including anonymous) to call the function.
GRANT EXECUTE ON FUNCTION claim_founder_badge() TO authenticated, anon;
