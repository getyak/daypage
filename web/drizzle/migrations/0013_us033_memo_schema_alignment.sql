-- US-033: Unified memo schema — iOS↔Web field alignment
-- weather: text → jsonb (nullable, stores structured weather object)
-- New fields: source, device_id, mood, word_count

ALTER TABLE "memos"
  ALTER COLUMN "weather" TYPE jsonb USING
    CASE
      WHEN "weather" IS NULL THEN NULL
      ELSE jsonb_build_object('raw', "weather")
    END,
  ADD COLUMN IF NOT EXISTS "source" text NOT NULL DEFAULT 'web',
  ADD COLUMN IF NOT EXISTS "device_id" text,
  ADD COLUMN IF NOT EXISTS "mood" text,
  ADD COLUMN IF NOT EXISTS "word_count" integer NOT NULL DEFAULT 0;
