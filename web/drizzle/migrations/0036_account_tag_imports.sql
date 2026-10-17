-- #884: account-scoped imported flomo tag preservation.
--
-- Intentionally additive. Raw memo YAML/Markdown and sync v2 payload schemas are
-- untouched: imported tags are stored as account-scoped exact labels, per-memo
-- associations, and one immutable versioned import metadata snapshot per source.
-- Existing hashtag body text stays byte-for-byte unchanged, and imported tags
-- NEVER become AI entities (no entity derivation trigger or hook exists here).
--
-- Labels keep their original leading '#', Unicode, case, punctuation, and '/'
-- hierarchy exactly as supplied. There is no normalization and no splitting on
-- comma or slash; no parent labels are invented.

-- Composite ownership key so memo_tag_links can enforce (user_id, memo_id).
CREATE UNIQUE INDEX IF NOT EXISTS "memos_user_id_id_unique"
  ON "public"."memos" ("user_id", "id");--> statement-breakpoint

-- Exact account tag labels. Label is text COLLATE "C" so equality, ordering and
-- range scans are byte-exact regardless of database collation.
CREATE TABLE IF NOT EXISTS "public"."user_tags" (
  "user_id" uuid NOT NULL,
  "label" text COLLATE "C" NOT NULL,
  "in_import_catalog" boolean NOT NULL DEFAULT false,
  CONSTRAINT "user_tags_pk" PRIMARY KEY("user_id", "label"),
  CONSTRAINT "user_tags_user_id_users_id_fk" FOREIGN KEY ("user_id")
    REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action
);--> statement-breakpoint

-- Per-memo tag associations. Duplicate label tokens inside one import memo map to
-- one association row (deduplicated); the immutable raw snapshot keeps tokens.
CREATE TABLE IF NOT EXISTS "public"."memo_tag_links" (
  "user_id" uuid NOT NULL,
  "memo_id" uuid NOT NULL,
  "label" text COLLATE "C" NOT NULL,
  CONSTRAINT "memo_tag_links_pk" PRIMARY KEY("user_id", "memo_id", "label"),
  CONSTRAINT "memo_tag_links_user_id_users_id_fk" FOREIGN KEY ("user_id")
    REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action,
  CONSTRAINT "memo_tag_links_user_memo_fk" FOREIGN KEY ("user_id", "memo_id")
    REFERENCES "public"."memos"("user_id", "id") ON DELETE cascade ON UPDATE no action,
  CONSTRAINT "memo_tag_links_user_label_fk" FOREIGN KEY ("user_id", "label")
    REFERENCES "public"."user_tags"("user_id", "label") ON DELETE cascade ON UPDATE no action
);--> statement-breakpoint

CREATE INDEX IF NOT EXISTS "memo_tag_links_user_label_memo"
  ON "public"."memo_tag_links" ("user_id", "label", "memo_id");--> statement-breakpoint

-- Immutable import receipts. One row per (account, source digest). The payload is
-- canonical version-1 metadata only: {version,catalog,memos} - it contains NO
-- note body and NO auth state. Counts derived from it are HISTORICAL metadata of
-- that import: later tombstones never rewrite the snapshot or its counts.
CREATE TABLE IF NOT EXISTS "public"."memo_tag_imports" (
  "user_id" uuid NOT NULL,
  "source_sha256" text NOT NULL,
  "payload_hash" text NOT NULL,
  "payload" jsonb NOT NULL,
  "version" integer NOT NULL DEFAULT 1,
  "created_at" timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "memo_tag_imports_pk" PRIMARY KEY("user_id", "source_sha256"),
  CONSTRAINT "memo_tag_imports_user_id_users_id_fk" FOREIGN KEY ("user_id")
    REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action,
  CONSTRAINT "memo_tag_imports_source_sha256_check"
    CHECK ("source_sha256" ~ '^[0-9a-f]{64}$'),
  CONSTRAINT "memo_tag_imports_payload_hash_check"
    CHECK ("payload_hash" ~ '^[0-9a-f]{64}$'),
  CONSTRAINT "memo_tag_imports_version_check" CHECK ("version" = 1),
  CONSTRAINT "memo_tag_imports_payload_shape_check"
    CHECK (jsonb_typeof("payload") = 'object')
);--> statement-breakpoint

-- Immutable receipts: UPDATE is blocked for every role, including table owners.
-- DELETE stays legal so owner-account deletion cascades remain intact.
CREATE OR REPLACE FUNCTION "public"."daypage_memo_tag_import_immutable"()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
BEGIN
  RAISE EXCEPTION 'tag import snapshots are immutable'
    USING ERRCODE = '55000';
END;
$$;--> statement-breakpoint

DROP TRIGGER IF EXISTS "memo_tag_imports_immutable" ON "public"."memo_tag_imports";--> statement-breakpoint
CREATE TRIGGER "memo_tag_imports_immutable"
BEFORE UPDATE ON "public"."memo_tag_imports"
FOR EACH ROW EXECUTE FUNCTION "public"."daypage_memo_tag_import_immutable"();--> statement-breakpoint

-- Row Level Security: authenticated reads own rows only. There are no
-- INSERT/UPDATE/DELETE policies and no client grants, so writes are RPC-only.
ALTER TABLE "public"."user_tags" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "public"."memo_tag_links" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "public"."memo_tag_imports" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint

DROP POLICY IF EXISTS "user_tags_select_own" ON "public"."user_tags";--> statement-breakpoint
CREATE POLICY "user_tags_select_own"
  ON "public"."user_tags" FOR SELECT TO "authenticated"
  USING ("user_id" = (SELECT auth.uid()));--> statement-breakpoint

DROP POLICY IF EXISTS "memo_tag_links_select_own" ON "public"."memo_tag_links";--> statement-breakpoint
CREATE POLICY "memo_tag_links_select_own"
  ON "public"."memo_tag_links" FOR SELECT TO "authenticated"
  USING ("user_id" = (SELECT auth.uid()));--> statement-breakpoint

DROP POLICY IF EXISTS "memo_tag_imports_select_own" ON "public"."memo_tag_imports";--> statement-breakpoint
CREATE POLICY "memo_tag_imports_select_own"
  ON "public"."memo_tag_imports" FOR SELECT TO "authenticated"
  USING ("user_id" = (SELECT auth.uid()));--> statement-breakpoint

-- Never rely on default privileges (fresh Supabase projects grant function
-- EXECUTE to PUBLIC and table access to broad roles by default).
REVOKE ALL ON "public"."user_tags" FROM PUBLIC, anon, authenticated;--> statement-breakpoint
REVOKE ALL ON "public"."memo_tag_links" FROM PUBLIC, anon, authenticated;--> statement-breakpoint
REVOKE ALL ON "public"."memo_tag_imports" FROM PUBLIC, anon, authenticated;--> statement-breakpoint
GRANT SELECT ON "public"."user_tags" TO "authenticated";--> statement-breakpoint
GRANT SELECT ON "public"."memo_tag_links" TO "authenticated";--> statement-breakpoint
GRANT SELECT ON "public"."memo_tag_imports" TO "authenticated";--> statement-breakpoint
REVOKE ALL ON FUNCTION "public"."daypage_memo_tag_import_immutable"() FROM PUBLIC, anon, authenticated;--> statement-breakpoint

-- Label validation helper. A label must start with '#', have a non-empty suffix,
-- fit in 1024 UTF-8 bytes, and contain no ASCII controls/DEL. No other limits are
-- imposed: commas, slashes, spaces, and any Unicode keep their exact form.
-- jsonb can never carry U+0000, so controls are U+0001..U+001F plus U+007F here.
CREATE OR REPLACE FUNCTION "public"."daypage_tag_import_label_ok"(p_label text)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
STRICT
SET search_path = pg_catalog
AS $$
BEGIN
  IF pg_catalog.octet_length(p_label) < 2
    OR pg_catalog.octet_length(p_label) > 1024 THEN
    RETURN false;
  END IF;
  IF pg_catalog.substr(p_label, 1, 1) <> '#' THEN
    RETURN false;
  END IF;
  IF EXISTS (
    SELECT 1
    FROM pg_catalog.generate_series(1, 31) AS control_codes(code)
    WHERE pg_catalog.strpos(p_label, pg_catalog.chr(control_codes.code)) > 0
  ) OR pg_catalog.strpos(p_label, pg_catalog.chr(127)) > 0 THEN
    RETURN false;
  END IF;
  RETURN true;
END;
$$;--> statement-breakpoint

REVOKE ALL ON FUNCTION "public"."daypage_tag_import_label_ok"(text) FROM PUBLIC, anon, authenticated;--> statement-breakpoint

-- Import RPC. SECURITY DEFINER keeps the multi-table write atomic and
-- integrity-checked even if a client role is compromised; it runs with a fixed
-- search_path, no dynamic SQL, explicit user_id predicates on every path, and
-- only static generic error strings (never raw labels or other-owner details).
--
-- Ordering contract:
--   1. verify auth.uid() and fully validate payload shape/limits (read-only)
--   2. compute the server-side payload fingerprint (never caller-provided)
--   3. take the per-account advisory lock, then look for the source receipt:
--      identical payload -> replay historical receipt BEFORE any live-memo check
--      changed payload   -> conflict error, zero writes
--   4. first import: lock referenced owned/live memos in sorted UUID order
--      (FOR SHARE; FK key-share alone does not protect deleted_at), verify
--      cardinality and ownership atomically, then write tags/links/receipt
CREATE OR REPLACE FUNCTION "public"."daypage_import_tags_v1"(
  p_source_sha256 text,
  p_payload jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_payload_hash text;
  v_payload jsonb;
  v_status text;
  v_existing public.memo_tag_imports%ROWTYPE;
  v_catalog_count integer;
  v_memo_count integer;
  v_ref_count integer;
  v_locked_count integer;
  v_distinct_labels integer;
  v_memberships integer;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING ERRCODE = '42501';
  END IF;

  IF p_source_sha256 IS NULL OR p_source_sha256 !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'invalid tag import payload' USING ERRCODE = '22023';
  END IF;

  -- Strict root shape first, then the 8 MiB canonical-size cap, so later
  -- per-item work is bounded. The cap is measured on PostgreSQL jsonb::text.
  IF p_payload IS NULL
    OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'invalid tag import payload' USING ERRCODE = '22023';
  END IF;
  IF (
      SELECT pg_catalog.array_agg(root_key ORDER BY root_key)
      FROM pg_catalog.jsonb_object_keys(p_payload) AS root_keys(root_key)
    ) IS DISTINCT FROM ARRAY['catalog', 'memos', 'version']::text[]
    OR pg_catalog.octet_length(p_payload::text) > 8388608 THEN
    RAISE EXCEPTION 'invalid tag import payload' USING ERRCODE = '22023';
  END IF;

  IF p_payload->'version' IS DISTINCT FROM '1'::jsonb THEN
    RAISE EXCEPTION 'invalid tag import payload' USING ERRCODE = '22023';
  END IF;

  -- catalog: array of exact labels, 20000 max, no duplicate entries.
  IF jsonb_typeof(p_payload->'catalog') IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'invalid tag import payload' USING ERRCODE = '22023';
  END IF;
  IF pg_catalog.jsonb_array_length(p_payload->'catalog') > 20000 THEN
    RAISE EXCEPTION 'invalid tag import payload' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM pg_catalog.jsonb_array_elements(p_payload->'catalog') AS entries(item)
    WHERE jsonb_typeof(entries.item) IS DISTINCT FROM 'string'
  ) OR EXISTS (
    SELECT 1
    FROM pg_catalog.jsonb_array_elements_text(p_payload->'catalog') AS labels(label)
    WHERE NOT public.daypage_tag_import_label_ok(labels.label COLLATE "C")
  ) THEN
    RAISE EXCEPTION 'invalid tag import payload' USING ERRCODE = '22023';
  END IF;
  IF (
    SELECT pg_catalog.count(*)
    FROM pg_catalog.jsonb_array_elements(p_payload->'catalog') AS entries(item)
  ) <> (
    SELECT pg_catalog.count(DISTINCT entries.item)
    FROM pg_catalog.jsonb_array_elements(p_payload->'catalog') AS entries(item)
  ) THEN
    RAISE EXCEPTION 'invalid tag import payload' USING ERRCODE = '22023';
  END IF;

  -- memos: array of {memo_id, tags} objects, 10000 max, no duplicate memo IDs.
  IF jsonb_typeof(p_payload->'memos') IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'invalid tag import payload' USING ERRCODE = '22023';
  END IF;
  IF pg_catalog.jsonb_array_length(p_payload->'memos') > 10000 THEN
    RAISE EXCEPTION 'invalid tag import payload' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM pg_catalog.jsonb_array_elements(p_payload->'memos') AS memo_items(item)
    WHERE jsonb_typeof(memo_items.item) IS DISTINCT FROM 'object'
  ) THEN
    RAISE EXCEPTION 'invalid tag import payload' USING ERRCODE = '22023';
  END IF;
  -- Every item is a jsonb object now, so item keys can be enumerated safely.
  IF EXISTS (
    SELECT 1
    FROM pg_catalog.jsonb_array_elements(p_payload->'memos') AS memo_items(item)
    WHERE (
      SELECT pg_catalog.array_agg(item_key ORDER BY item_key)
      FROM pg_catalog.jsonb_object_keys(memo_items.item) AS item_keys(item_key)
    ) IS DISTINCT FROM ARRAY['memo_id', 'tags']::text[]
  ) THEN
    RAISE EXCEPTION 'invalid tag import payload' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM pg_catalog.jsonb_array_elements(p_payload->'memos') AS memo_items(item)
    WHERE jsonb_typeof(memo_items.item->'memo_id') IS DISTINCT FROM 'string'
       OR (memo_items.item->>'memo_id') !~
          '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$'
       OR jsonb_typeof(memo_items.item->'tags') IS DISTINCT FROM 'array'
  ) THEN
    RAISE EXCEPTION 'invalid tag import payload' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM pg_catalog.jsonb_array_elements(p_payload->'memos') AS memo_items(item)
    WHERE pg_catalog.jsonb_array_length(memo_items.item->'tags') > 200
  ) THEN
    RAISE EXCEPTION 'invalid tag import payload' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM pg_catalog.jsonb_array_elements(p_payload->'memos') AS memo_items(item)
    CROSS JOIN LATERAL pg_catalog.jsonb_array_elements(memo_items.item->'tags') AS tag_items(item)
    WHERE jsonb_typeof(tag_items.item) IS DISTINCT FROM 'string'
  ) OR EXISTS (
    SELECT 1
    FROM pg_catalog.jsonb_array_elements(p_payload->'memos') AS memo_items(item)
    CROSS JOIN LATERAL pg_catalog.jsonb_array_elements_text(memo_items.item->'tags') AS labels(label)
    WHERE NOT public.daypage_tag_import_label_ok(labels.label COLLATE "C")
  ) THEN
    RAISE EXCEPTION 'invalid tag import payload' USING ERRCODE = '22023';
  END IF;
  IF (
    SELECT pg_catalog.count(*)
    FROM pg_catalog.jsonb_array_elements(p_payload->'memos') AS memo_items(item)
  ) <> (
    SELECT pg_catalog.count(DISTINCT (memo_items.item->>'memo_id')::uuid)
    FROM pg_catalog.jsonb_array_elements(p_payload->'memos') AS memo_items(item)
  ) THEN
    RAISE EXCEPTION 'invalid tag import payload' USING ERRCODE = '22023';
  END IF;

  -- 50000 total distinct (memo, label) links. Duplicate label tokens inside one
  -- memo collapse to one association and are not double-counted here.
  SELECT pg_catalog.count(*) INTO v_memberships
  FROM (
    SELECT DISTINCT
      (memo_items.item->>'memo_id')::uuid AS memo_id,
      labels.label COLLATE "C"
    FROM pg_catalog.jsonb_array_elements(p_payload->'memos') AS memo_items(item)
    CROSS JOIN LATERAL pg_catalog.jsonb_array_elements_text(memo_items.item->'tags') AS labels(label)
  ) AS distinct_links;
  IF v_memberships > 50000 THEN
    RAISE EXCEPTION 'invalid tag import payload' USING ERRCODE = '22023';
  END IF;

  -- Server-side immutable-import fingerprint over the canonical PostgreSQL
  -- jsonb::text representation, stored as lowerhex text. It is deliberately NOT
  -- a portable wire-JSON digest: snapshot consumers keep it as opaque metadata
  -- and must not recompute it from a Swift/JS serialization.
  v_payload_hash := pg_catalog.encode(
    pg_catalog.sha256(pg_catalog.convert_to(p_payload::text, 'UTF8')),
    'hex'
  );

  -- Serialize first-time imports per ACCOUNT (not per source) so two sources
  -- sharing labels can never acquire row locks in reverse order.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('daypage-tag-import:' || v_user_id::text, 884)
  );

  SELECT * INTO v_existing
  FROM public.memo_tag_imports
  WHERE user_id = v_user_id AND source_sha256 = p_source_sha256;

  IF FOUND THEN
    -- Identical payload replays the historical receipt before any live-memo
    -- check (a later memo tombstone must not break replay). A changed payload is
    -- a conflict and must never be silently absorbed.
    IF v_existing.payload_hash IS DISTINCT FROM v_payload_hash
      OR v_existing.payload IS DISTINCT FROM p_payload THEN
      RAISE EXCEPTION 'source payload conflict' USING ERRCODE = '23505';
    END IF;
    v_status := 'replayed';
    v_payload := v_existing.payload;
  ELSE
    v_status := 'imported';
    v_payload := p_payload;

    -- Lock every referenced memo in sorted UUID order (FOR SHARE also blocks
    -- concurrent deleted_at tombstones; FK key-share alone would not), then
    -- require exact cardinality: every referenced memo is OWNED by the current
    -- uid AND live. Any failure is one generic error - no other-owner details.
    WITH refs AS (
      SELECT DISTINCT (memo_items.item->>'memo_id')::uuid AS memo_id
      FROM pg_catalog.jsonb_array_elements(p_payload->'memos') AS memo_items(item)
    )
    SELECT pg_catalog.count(*) INTO v_locked_count
    FROM (
      SELECT memo.id
      FROM refs
      JOIN public.memos memo
        ON memo.id = refs.memo_id
       AND memo.user_id = v_user_id
       AND memo.deleted_at IS NULL
      ORDER BY memo.id
      FOR SHARE OF memo
    ) AS locked_refs;

    SELECT pg_catalog.count(*) INTO v_ref_count
    FROM (
      SELECT DISTINCT (memo_items.item->>'memo_id')::uuid AS memo_id
      FROM pg_catalog.jsonb_array_elements(p_payload->'memos') AS memo_items(item)
    ) AS refs;

    IF v_locked_count IS DISTINCT FROM v_ref_count THEN
      RAISE EXCEPTION 'import references unavailable memos' USING ERRCODE = '22023';
    END IF;

    -- Set-based writes only: no per-label row lookups and no memo writes, so
    -- memo body/created_at/sync_revision never change and no memo trigger fires.
    -- Catalog membership OR-merges true; outside-catalog labels land as false;
    -- unused catalog labels are retained; existing tags/links are never deleted.
    INSERT INTO public.user_tags AS tags (user_id, label, in_import_catalog)
    SELECT v_user_id, all_labels.label COLLATE "C", pg_catalog.bool_or(all_labels.in_catalog)
    FROM (
      SELECT labels.label COLLATE "C", true AS in_catalog
      FROM pg_catalog.jsonb_array_elements_text(p_payload->'catalog') AS labels(label)
      UNION ALL
      SELECT labels.label COLLATE "C", false AS in_catalog
      FROM pg_catalog.jsonb_array_elements(p_payload->'memos') AS memo_items(item)
      CROSS JOIN LATERAL pg_catalog.jsonb_array_elements_text(memo_items.item->'tags') AS labels(label)
    ) AS all_labels
    GROUP BY all_labels.label COLLATE "C"
    ON CONFLICT (user_id, label) DO UPDATE
      SET in_import_catalog = tags.in_import_catalog OR EXCLUDED.in_import_catalog
      WHERE NOT tags.in_import_catalog AND EXCLUDED.in_import_catalog;

    INSERT INTO public.memo_tag_links (user_id, memo_id, label)
    SELECT DISTINCT v_user_id, (memo_items.item->>'memo_id')::uuid, labels.label COLLATE "C"
    FROM pg_catalog.jsonb_array_elements(p_payload->'memos') AS memo_items(item)
    CROSS JOIN LATERAL pg_catalog.jsonb_array_elements_text(memo_items.item->'tags') AS labels(label)
    ON CONFLICT (user_id, memo_id, label) DO NOTHING;

    INSERT INTO public.memo_tag_imports (user_id, source_sha256, payload_hash, payload)
    VALUES (v_user_id, p_source_sha256, v_payload_hash, p_payload);
  END IF;

  -- Version-1 receipt counts. They describe the snapshot payload, which is
  -- HISTORICAL metadata of this import: later tombstones never edit the payload
  -- or these counts. Active tag display/filter/counts must separately join live
  -- memos; a direct snapshot SELECT does not hide deleted internal memo entries.
  --   catalog_labels : catalog entries (duplicates rejected at validation)
  --   distinct_labels: distinct labels across catalog AND per-memo tag arrays
  --   memos          : memo map entries (including empty tag arrays)
  --   memberships    : distinct (memo_id, label) associations
  SELECT
    (
      SELECT pg_catalog.count(*)
      FROM pg_catalog.jsonb_array_elements(v_payload->'catalog') AS entries(item)
    ),
    (
      SELECT pg_catalog.count(*) FROM (
        SELECT labels.label COLLATE "C" AS label
        FROM pg_catalog.jsonb_array_elements_text(v_payload->'catalog') AS labels(label)
        UNION
        SELECT labels.label COLLATE "C" AS label
        FROM pg_catalog.jsonb_array_elements(v_payload->'memos') AS memo_items(item)
        CROSS JOIN LATERAL pg_catalog.jsonb_array_elements_text(memo_items.item->'tags') AS labels(label)
      ) AS complete_labels
    ),
    (
      SELECT pg_catalog.count(*)
      FROM pg_catalog.jsonb_array_elements(v_payload->'memos') AS memo_items(item)
    ),
    (
      SELECT pg_catalog.count(*)
      FROM (
        SELECT DISTINCT
          (memo_items.item->>'memo_id')::uuid AS memo_id,
          labels.label COLLATE "C"
        FROM pg_catalog.jsonb_array_elements(v_payload->'memos') AS memo_items(item)
        CROSS JOIN LATERAL pg_catalog.jsonb_array_elements_text(memo_items.item->'tags') AS labels(label)
      ) AS distinct_links
    )
  INTO v_catalog_count, v_distinct_labels, v_memo_count, v_memberships;

  RETURN pg_catalog.jsonb_build_object(
    'version', 1,
    'source_sha256', p_source_sha256,
    'status', v_status,
    'catalog_labels', v_catalog_count,
    'distinct_labels', v_distinct_labels,
    'memos', v_memo_count,
    'memberships', v_memberships
  );
END;
$$;--> statement-breakpoint

REVOKE ALL ON FUNCTION "public"."daypage_import_tags_v1"(text, jsonb)
  FROM PUBLIC, anon, authenticated;--> statement-breakpoint
GRANT EXECUTE ON FUNCTION "public"."daypage_import_tags_v1"(text, jsonb)
  TO "authenticated";--> statement-breakpoint
