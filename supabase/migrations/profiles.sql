-- profiles: per-user public display name shown on leaderboards.
-- One row per auth user (anonymous or upgraded).  Public-readable so
-- other players' names can render on shared leaderboards; writes are
-- scoped to the owning user via RLS.

CREATE TABLE IF NOT EXISTS profiles (
  user_id      UUID        PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  display_name TEXT        NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT display_name_length CHECK (
    char_length(display_name) BETWEEN 3 AND 20
  ),
  CONSTRAINT display_name_charset CHECK (
    display_name ~ '^[A-Za-z0-9_-]+$'
  )
);

-- Case-insensitive uniqueness so "Abhay" and "abhay" can't both exist.
CREATE UNIQUE INDEX IF NOT EXISTS idx_profiles_display_name_ci
  ON profiles ((lower(display_name)));

ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;

-- Public read so leaderboards can show other players' names.
CREATE POLICY "Anyone can read profiles"
  ON profiles FOR SELECT
  USING (true);

-- Writes scoped to the owning user only.
CREATE POLICY "Users can insert their own profile"
  ON profiles FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update their own profile"
  ON profiles FOR UPDATE
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);
