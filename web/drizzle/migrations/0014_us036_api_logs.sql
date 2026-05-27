-- US-036: api_logs table for request-level error logging
CREATE TABLE IF NOT EXISTS "api_logs" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "method" text NOT NULL,
  "path" text NOT NULL,
  "status" integer NOT NULL,
  "duration_ms" integer NOT NULL,
  "user_id" uuid REFERENCES "users"("id") ON DELETE SET NULL,
  "error" text,
  "created_at" timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS "api_logs_created" ON "api_logs" ("created_at");
