-- #884 / ADR-0020: imported media compatibility slice (ADTS AAC and QuickTime MOV).
--
-- Additive only. This migration:
--   1. extends public.daypage_attachment_extension with audio/aac -> aac and
--      video/quicktime -> mov while keeping the seven legacy mappings intact;
--   2. appends those two MIME types to the existing private 'memo-attachments'
--      bucket allow-list without touching its public flag, file size limit, or
--      any other bucket setting;
--   3. adds a NOT VALID kind/MIME guard so the server rejects wrong kind/MIME
--      combinations for newly verified v2 manifest rows while legacy unverified
--      rows (content_sha256 NULL) remain fully compatible.
--
-- It changes no RLS policy, no grants, no size or quota limits, no existing
-- upload reservation, and drops or rewrites no historical row or SQL.

CREATE OR REPLACE FUNCTION public.daypage_attachment_extension(p_mime_type text)
RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
SET search_path = pg_catalog
AS $$
  SELECT CASE lower(p_mime_type)
    WHEN 'audio/m4a' THEN 'm4a'
    WHEN 'audio/mp4' THEN 'mp4'
    WHEN 'audio/aac' THEN 'aac'
    WHEN 'image/jpeg' THEN 'jpg'
    WHEN 'image/png' THEN 'png'
    WHEN 'image/heic' THEN 'heic'
    WHEN 'image/heif' THEN 'heif'
    WHEN 'application/pdf' THEN 'pdf'
    WHEN 'video/quicktime' THEN 'mov'
    ELSE NULL
  END
$$;--> statement-breakpoint

-- Privileges are unchanged from 0029; CREATE OR REPLACE preserves them and
-- this idempotent revoke keeps the same fail-closed state.
REVOKE ALL ON FUNCTION public.daypage_attachment_extension(text) FROM PUBLIC;--> statement-breakpoint

-- Append AAC and QuickTime to the bucket MIME allow-list. The update runs only
-- when either type is missing, so it is idempotent and leaves the bucket's
-- public flag, file size limit, and every other column untouched.
UPDATE storage.buckets
SET allowed_mime_types = (
  SELECT array_agg(DISTINCT entry ORDER BY entry)
  FROM unnest(allowed_mime_types || ARRAY['audio/aac', 'video/quicktime']) AS entry
)
WHERE id = 'memo-attachments'
  AND allowed_mime_types IS NOT NULL
  AND NOT allowed_mime_types @> ARRAY['audio/aac', 'video/quicktime'];--> statement-breakpoint

-- Additive kind/MIME guard for newly verified manifests. The v2 sync RPC
-- validates kind and MIME independently today, so a wrong pairing such as
-- QuickTime MOV as photo or AAC as file could reach memo_attachments. The
-- constraint is added NOT VALID: historical rows are never scanned, dropped,
-- or rewritten, legacy unverified rows (content_sha256 NULL) stay compatible,
-- and only newly inserted or updated verified rows are checked. A violating
-- insert inside daypage_apply_sync_operations_v2 is rejected like any other
-- invalid attachment descriptor.
--
-- COALESCE wraps the tuple IN on purpose: with a NULL mime_type the IN
-- expression evaluates to NULL, which a CHECK constraint would otherwise
-- accept. COALESCE turns that NULL into FALSE so a verified row without a MIME
-- type fails closed. The content_sha256 IS NULL branch keeps legacy unverified
-- rows compatible.
ALTER TABLE public.memo_attachments
  DROP CONSTRAINT IF EXISTS memo_attachments_verified_kind_mime_check;--> statement-breakpoint
ALTER TABLE public.memo_attachments
  ADD CONSTRAINT memo_attachments_verified_kind_mime_check
  CHECK (
    content_sha256 IS NULL
    OR COALESCE(
      (kind::text, lower(mime_type)) IN (
        ('photo', 'image/jpeg'),
        ('photo', 'image/png'),
        ('photo', 'image/heic'),
        ('photo', 'image/heif'),
        ('audio', 'audio/m4a'),
        ('audio', 'audio/mp4'),
        ('audio', 'audio/aac'),
        ('file', 'application/pdf'),
        ('file', 'video/quicktime')
      ),
      FALSE
    )
  ) NOT VALID;--> statement-breakpoint
