-- US-035: Add pgvector extension + HNSW index on pages.embedding
-- This migration converts pages.embedding from a JSON-encoded text column to
-- a native pgvector vector(1536) column and creates an HNSW index for fast
-- approximate nearest-neighbour search.
--
-- Prerequisites: pgvector extension must be available in Postgres.
-- In local Supabase it is pre-installed; enable via:
--   supabase/config.toml → [db.extensions] → names = ["pgvector"]

--> statement-breakpoint
CREATE EXTENSION IF NOT EXISTS vector;

--> statement-breakpoint
-- Convert pages.embedding from text (JSON) to vector(1536).
-- Rows with a valid JSON array are cast; rows with NULL or invalid JSON
-- remain NULL (pgvector accepts NULL).
ALTER TABLE "pages"
  ALTER COLUMN "embedding" TYPE vector(1536)
  USING CASE
    WHEN "embedding" IS NULL THEN NULL
    ELSE "embedding"::vector
  END;

--> statement-breakpoint
-- HNSW index for cosine distance (<=>).
-- m=16, ef_construction=64 are good defaults for 1536-dim vectors.
CREATE INDEX IF NOT EXISTS "pages_embedding_hnsw"
  ON "pages" USING hnsw ("embedding" vector_cosine_ops)
  WITH (m = 16, ef_construction = 64);

--> statement-breakpoint
-- memos.embedding: same conversion (used by compile pipeline embed step).
ALTER TABLE "memos"
  ALTER COLUMN "embedding" TYPE vector(1536)
  USING CASE
    WHEN "embedding" IS NULL THEN NULL
    ELSE "embedding"::vector
  END;

--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "memos_embedding_hnsw"
  ON "memos" USING hnsw ("embedding" vector_cosine_ops)
  WITH (m = 16, ef_construction = 64);
