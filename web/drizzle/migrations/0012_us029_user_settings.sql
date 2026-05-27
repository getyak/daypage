-- US-029: user_settings table for cloud-synced preferences
CREATE TABLE IF NOT EXISTS "user_settings" (
  "user_id" uuid PRIMARY KEY REFERENCES "users"("id") ON DELETE CASCADE,
  "settings" jsonb NOT NULL DEFAULT '{}'::jsonb,
  "updated_at" timestamptz NOT NULL DEFAULT now()
);
