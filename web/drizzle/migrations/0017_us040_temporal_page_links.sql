-- US-040: time dimension on page_links (演变 / as-of 某日 queries).
-- A page_link is a fact observed at a point in time. We add a validity window so
-- the knowledge graph can answer temporal questions:
--   * valid_from — the day the fact first held (backfilled from created_at)
--   * valid_to   — the day the fact was superseded; NULL = still valid
-- Facts are INVALIDATED by setting valid_to, never physically deleted, so an
-- as-of query before that date still sees the fact and an entity's history is a
-- sequence rather than an overwrite.
ALTER TABLE "page_links"
  ADD COLUMN IF NOT EXISTS "valid_from" timestamptz NOT NULL DEFAULT now();
--> statement-breakpoint
ALTER TABLE "page_links"
  ADD COLUMN IF NOT EXISTS "valid_to" timestamptz;
--> statement-breakpoint
-- Backfill existing rows: they were valid from their creation day.
UPDATE "page_links" SET "valid_from" = "created_at";
--> statement-breakpoint
-- Make date-window / as-of scans over a user's links efficient.
CREATE INDEX IF NOT EXISTS "page_links_user_valid"
  ON "page_links" ("user_id", "valid_from", "valid_to");
