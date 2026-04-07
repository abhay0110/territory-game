-- player_devices: stores FCM tokens for push notifications.
-- One row per player (anonymous or named).

CREATE TABLE IF NOT EXISTS player_devices (
  player_id  UUID        PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  fcm_token  TEXT        NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Index on token for potential admin lookups / dedup.
CREATE INDEX IF NOT EXISTS idx_player_devices_fcm_token
  ON player_devices (fcm_token);

-- RLS: players can only read/write their own row.
ALTER TABLE player_devices ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their own device"
  ON player_devices FOR SELECT
  USING (auth.uid() = player_id);

CREATE POLICY "Users can insert their own device"
  ON player_devices FOR INSERT
  WITH CHECK (auth.uid() = player_id);

CREATE POLICY "Users can update their own device"
  ON player_devices FOR UPDATE
  USING (auth.uid() = player_id)
  WITH CHECK (auth.uid() = player_id);
