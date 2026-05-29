-- US-022: ingest_sources declares its default compile tier so high-value
-- sources are not under-processed. Reuses the existing ingest_mode enum
-- (light|full); memos created from a source inherit this tier.
ALTER TABLE "ingest_sources"
  ADD COLUMN IF NOT EXISTS "default_ingest_mode" "ingest_mode" NOT NULL DEFAULT 'light';
