\set ON_ERROR_STOP on

-- #884 account tag import verification. BEGIN/ROLLBACK only: synthetic auth
-- users, synthetic memos, no real data, and nothing survives the transaction.
-- Run by the parent on staging after independent review; never run remotely by
-- the implementing worker. Single-connection execution proves atomicity and
-- rollback semantics but NOT parallel concurrency: the two-connection advisory
-- lock rehearsal remains a separate parent gate.

BEGIN;
SET LOCAL row_security = on;

INSERT INTO auth.users (
  id, email, aud, role, created_at, updated_at, raw_user_meta_data
)
VALUES
  (
    '99400000-0000-4000-8000-000000000001', 'tag-import-a@daypage.test',
    'authenticated', 'authenticated', now(), now(), '{}'::jsonb
  ),
  (
    '99400000-0000-4000-8000-000000000002', 'tag-import-b@daypage.test',
    'authenticated', 'authenticated', now(), now(), '{}'::jsonb
  );

DO $$
BEGIN
  IF (SELECT count(*) FROM public.users WHERE id IN (
    '99400000-0000-4000-8000-000000000001',
    '99400000-0000-4000-8000-000000000002'
  )) <> 2 THEN
    RAISE EXCEPTION 'auth profile trigger did not create both synthetic users';
  END IF;
END
$$;

INSERT INTO public.memos (id, user_id, type, body, source, origin, sync_revision) VALUES
  (
    '88400000-0000-4000-8000-000000000001', '99400000-0000-4000-8000-000000000001',
    'text', 'body keeps #proj/alpha hashtag text byte-for-byte', 'web', 'web', 1
  ),
  (
    '88400000-0000-4000-8000-000000000002', '99400000-0000-4000-8000-000000000001',
    'text', 'unicode body #标签/子 and #outside-not-in-catalog stay untouched', 'web', 'web', 2
  ),
  (
    '88400000-0000-4000-8000-000000000003', '99400000-0000-4000-8000-000000000001',
    'text', 'zero-tags memo body', 'web', 'web', 3
  ),
  (
    '88400000-0000-4000-8000-000000000004', '99400000-0000-4000-8000-000000000001',
    'text', 'body with #emoji🎉 and "#a, b" as literal hashtag text', 'web', 'web', 4
  ),
  (
    '88400000-0000-4000-8000-000000000011', '99400000-0000-4000-8000-000000000002',
    'text', 'owner B memo body', 'web', 'web', 1
  );

CREATE TEMP TABLE tag_import_memo_baseline AS
SELECT id, body, created_at, sync_revision
FROM public.memos
WHERE user_id IN (
  '99400000-0000-4000-8000-000000000001',
  '99400000-0000-4000-8000-000000000002'
);

-- Schema, security and default-privilege expectations (postgres role).
DO $$
DECLARE
  v_fn regprocedure;
BEGIN
  IF (SELECT count(*) FROM pg_catalog.pg_class
      WHERE oid IN ('public.user_tags'::regclass,
                    'public.memo_tag_links'::regclass,
                    'public.memo_tag_imports'::regclass)
        AND relrowsecurity) <> 3 THEN
    RAISE EXCEPTION 'RLS must be enabled on all three tag tables';
  END IF;

  -- Fixed search_path on the import RPC and helpers; SECURITY DEFINER only on
  -- the import RPC (helpers stay invoker and private).
  FOREACH v_fn IN ARRAY ARRAY[
    'public.daypage_import_tags_v1(text,jsonb)'::regprocedure,
    'public.daypage_tag_import_label_ok(text)'::regprocedure,
    'public.daypage_memo_tag_import_immutable()'::regprocedure
  ] LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_catalog.pg_proc fn
      WHERE fn.oid = v_fn
        AND fn.proconfig @> ARRAY['search_path=pg_catalog']
    ) THEN
      RAISE EXCEPTION 'function % must have fixed search_path=pg_catalog', v_fn;
    END IF;
    IF EXISTS (
      SELECT 1
      FROM pg_catalog.pg_proc fn,
      LATERAL pg_catalog.aclexplode(
        COALESCE(fn.proacl, pg_catalog.acldefault('f', fn.proowner))
      ) AS acl(grantor, grantee, privilege_type, is_grantable)
      WHERE fn.oid = v_fn AND acl.grantee = 0
    ) THEN
      RAISE EXCEPTION 'function % still carries default PUBLIC EXECUTE', v_fn;
    END IF;
  END LOOP;

  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_proc
    WHERE oid = 'public.daypage_import_tags_v1(text,jsonb)'::regprocedure
      AND prosecdef
  ) THEN
    RAISE EXCEPTION 'import RPC must be SECURITY DEFINER for atomic integrity';
  END IF;

  IF NOT has_function_privilege(
    'authenticated', 'public.daypage_import_tags_v1(text,jsonb)', 'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'authenticated must be able to execute the import RPC';
  END IF;
  IF has_function_privilege(
    'anon', 'public.daypage_import_tags_v1(text,jsonb)', 'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'anon must not execute the import RPC';
  END IF;
  IF has_function_privilege(
    'authenticated', 'public.daypage_tag_import_label_ok(text)', 'EXECUTE'
  ) OR has_function_privilege(
    'anon', 'public.daypage_tag_import_label_ok(text)', 'EXECUTE'
  ) OR has_function_privilege(
    'authenticated', 'public.daypage_memo_tag_import_immutable()', 'EXECUTE'
  ) OR has_function_privilege(
    'anon', 'public.daypage_memo_tag_import_immutable()', 'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'internal tag import helpers must stay private';
  END IF;

  -- Explicit privilege posture on the three tables: owner SELECT only for
  -- authenticated, nothing for anon/PUBLIC, writes RPC-only.
  IF NOT has_table_privilege('authenticated', 'public.user_tags', 'SELECT')
    OR NOT has_table_privilege('authenticated', 'public.memo_tag_links', 'SELECT')
    OR NOT has_table_privilege('authenticated', 'public.memo_tag_imports', 'SELECT') THEN
    RAISE EXCEPTION 'authenticated must read its own tag import rows';
  END IF;
  IF has_table_privilege('authenticated', 'public.user_tags', 'INSERT')
    OR has_table_privilege('authenticated', 'public.user_tags', 'UPDATE')
    OR has_table_privilege('authenticated', 'public.user_tags', 'DELETE')
    OR has_table_privilege('authenticated', 'public.memo_tag_links', 'INSERT')
    OR has_table_privilege('authenticated', 'public.memo_tag_links', 'UPDATE')
    OR has_table_privilege('authenticated', 'public.memo_tag_links', 'DELETE')
    OR has_table_privilege('authenticated', 'public.memo_tag_imports', 'INSERT')
    OR has_table_privilege('authenticated', 'public.memo_tag_imports', 'UPDATE')
    OR has_table_privilege('authenticated', 'public.memo_tag_imports', 'DELETE') THEN
    RAISE EXCEPTION 'clients must not mutate tag import rows directly';
  END IF;
  IF has_table_privilege('anon', 'public.user_tags', 'SELECT')
    OR has_table_privilege('anon', 'public.memo_tag_links', 'SELECT')
    OR has_table_privilege('anon', 'public.memo_tag_imports', 'SELECT') THEN
    RAISE EXCEPTION 'anon must not read tag import rows';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM pg_catalog.pg_class c,
    LATERAL pg_catalog.aclexplode(
      COALESCE(c.relacl, pg_catalog.acldefault('r', c.relowner))
    ) AS acl(grantor, grantee, privilege_type, is_grantable)
    WHERE c.oid IN (
      'public.user_tags'::regclass,
      'public.memo_tag_links'::regclass,
      'public.memo_tag_imports'::regclass
    ) AND acl.grantee = 0
  ) THEN
    RAISE EXCEPTION 'tag import tables must not carry default PUBLIC privileges';
  END IF;
END
$$;

-- Fail closed: no authenticated uid means no import, even for the table owner.
DO $$
BEGIN
  BEGIN
    PERFORM public.daypage_import_tags_v1(
      '2b6ad3c8f0a14e57b9c0d2e4f6a8b0c2d4e6f8a0b2c4d6e8f0a2b4c6d8e0f2a4',
      '{"version":1,"catalog":[],"memos":[]}'::jsonb
    );
    RAISE EXCEPTION 'import RPC succeeded without an authenticated user';
  EXCEPTION WHEN SQLSTATE '42501' THEN
    IF SQLERRM <> 'authentication required' THEN
      RAISE EXCEPTION 'unexpected fail-closed message: %', SQLERRM;
    END IF;
  END;
END
$$;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '99400000-0000-4000-8000-000000000001', true);

DO $$
DECLARE
  v_src text := '2b6ad3c8f0a14e57b9c0d2e4f6a8b0c2d4e6f8a0b2c4d6e8f0a2b4c6d8e0f2a4';
  v_payload jsonb := $payload${"version":1,"catalog":["#proj/alpha","#proj/alpha/beta","#a, b","#标签/子","#emoji🎉","#unused/only-in-catalog"],"memos":[{"memo_id":"88400000-0000-4000-8000-000000000001","tags":["#proj/alpha","#proj/alpha/beta","#a, b"]},{"memo_id":"88400000-0000-4000-8000-000000000002","tags":["#标签/子","#outside-not-in-catalog","#outside-not-in-catalog"]},{"memo_id":"88400000-0000-4000-8000-000000000003","tags":[]},{"memo_id":"88400000-0000-4000-8000-000000000004","tags":["#emoji🎉","#a, b"]}]}$payload$::jsonb;
  v_expected_hash text;
  v_result jsonb;
  v_version integer;
  v_payload_out jsonb;
  v_created_at timestamptz;
BEGIN
  -- 1. First import of source S1: complete catalog and associations preserved.
  v_result := public.daypage_import_tags_v1(v_src, v_payload);
  IF v_result IS DISTINCT FROM jsonb_build_object(
    'version', 1,
    'source_sha256', v_src,
    'status', 'imported',
    'catalog_labels', 6,
    'distinct_labels', 7,
    'memos', 4,
    'memberships', 7
  ) THEN
    RAISE EXCEPTION 'unexpected S1 import result: %', v_result;
  END IF;

  IF (SELECT count(*) FROM public.user_tags WHERE user_id = auth.uid()) <> 7 THEN
    RAISE EXCEPTION 'expected 7 account labels after S1 (6 catalog + 1 outside-catalog)';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.user_tags
    WHERE user_id = auth.uid() AND label = '#unused/only-in-catalog' AND in_import_catalog
  ) THEN
    RAISE EXCEPTION 'unused catalog label must be retained with in_import_catalog true';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.user_tags
    WHERE user_id = auth.uid() AND label = '#outside-not-in-catalog' AND NOT in_import_catalog
  ) THEN
    RAISE EXCEPTION 'outside-catalog label must be stored with in_import_catalog false';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.user_tags
    WHERE user_id = auth.uid() AND label = '#a, b' AND in_import_catalog
  ) OR NOT EXISTS (
    SELECT 1 FROM public.user_tags
    WHERE user_id = auth.uid() AND label = '#标签/子' AND in_import_catalog
  ) OR NOT EXISTS (
    SELECT 1 FROM public.user_tags
    WHERE user_id = auth.uid() AND label = '#proj/alpha/beta' AND in_import_catalog
  ) THEN
    RAISE EXCEPTION 'comma/Unicode/nested labels must be preserved exactly, without splitting';
  END IF;

  IF (SELECT count(*) FROM public.memo_tag_links WHERE user_id = auth.uid()) <> 7 THEN
    RAISE EXCEPTION 'expected 7 distinct memo associations after S1';
  END IF;
  IF (SELECT count(*) FROM public.memo_tag_links
      WHERE user_id = auth.uid()
        AND memo_id = '88400000-0000-4000-8000-000000000002') <> 2 THEN
    RAISE EXCEPTION 'duplicate label tokens in one memo must collapse to one association';
  END IF;
  IF (SELECT count(*) FROM public.memo_tag_links
      WHERE user_id = auth.uid()
        AND memo_id = '88400000-0000-4000-8000-000000000003') <> 0 THEN
    RAISE EXCEPTION 'zero-tags memo must keep zero associations';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.memo_tag_links
    WHERE user_id = auth.uid() AND memo_id = '88400000-0000-4000-8000-000000000001' AND label = '#proj/alpha/beta'
  ) OR NOT EXISTS (
    SELECT 1 FROM public.memo_tag_links
    WHERE user_id = auth.uid() AND memo_id = '88400000-0000-4000-8000-000000000002' AND label = '#outside-not-in-catalog'
  ) OR NOT EXISTS (
    SELECT 1 FROM public.memo_tag_links
    WHERE user_id = auth.uid() AND memo_id = '88400000-0000-4000-8000-000000000004' AND label = '#emoji🎉'
  ) THEN
    RAISE EXCEPTION 'nested/outside-catalog/emoji associations were not preserved';
  END IF;

  -- 2. Immutable snapshot: exact payload, server-side jsonb::text fingerprint.
  v_expected_hash := pg_catalog.encode(
    pg_catalog.sha256(pg_catalog.convert_to(v_payload::text, 'UTF8')), 'hex'
  );
  SELECT version, payload, created_at
  INTO v_version, v_payload_out, v_created_at
  FROM public.memo_tag_imports
  WHERE user_id = auth.uid() AND source_sha256 = v_src;
  IF NOT FOUND OR v_version <> 1 OR v_payload_out IS DISTINCT FROM v_payload
    OR v_created_at IS NULL THEN
    RAISE EXCEPTION 'snapshot row must hold version 1 and the exact input payload';
  END IF;
  IF (SELECT payload_hash FROM public.memo_tag_imports
      WHERE user_id = auth.uid() AND source_sha256 = v_src) <> v_expected_hash THEN
    RAISE EXCEPTION 'payload_hash must be encode(sha256(convert_to(payload::text,UTF8)),hex)';
  END IF;
  IF (SELECT payload_hash FROM public.memo_tag_imports
      WHERE user_id = auth.uid() AND source_sha256 = v_src) !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'payload_hash must be lowerhex text, not bytea';
  END IF;
  IF (
    SELECT pg_catalog.array_agg(root_key ORDER BY root_key)
    FROM pg_catalog.jsonb_object_keys(
      (SELECT payload FROM public.memo_tag_imports
       WHERE user_id = auth.uid() AND source_sha256 = v_src)
    ) AS root_keys(root_key)
  ) IS DISTINCT FROM ARRAY['catalog', 'memos', 'version']::text[] THEN
    RAISE EXCEPTION 'snapshot payload must not carry note bodies or auth state';
  END IF;

  -- 3. Identical replay returns the historical receipt and writes nothing.
  v_result := public.daypage_import_tags_v1(v_src, v_payload);
  IF v_result->>'status' IS DISTINCT FROM 'replayed'
    OR (v_result->>'catalog_labels')::integer <> 6
    OR (v_result->>'distinct_labels')::integer <> 7
    OR (v_result->>'memos')::integer <> 4
    OR (v_result->>'memberships')::integer <> 7 THEN
    RAISE EXCEPTION 'unexpected S1 replay result: %', v_result;
  END IF;
  IF (SELECT count(*) FROM public.user_tags WHERE user_id = auth.uid()) <> 7
    OR (SELECT count(*) FROM public.memo_tag_links WHERE user_id = auth.uid()) <> 7
    OR (SELECT count(*) FROM public.memo_tag_imports WHERE user_id = auth.uid()) <> 1 THEN
    RAISE EXCEPTION 'replay must not create or delete any tag rows';
  END IF;

  -- 4. Same source with a changed payload is a conflict with zero writes.
  BEGIN
    PERFORM public.daypage_import_tags_v1(
      v_src,
      jsonb_set(v_payload, '{catalog}', v_payload->'catalog' || '["#extra"]'::jsonb)
    );
    RAISE EXCEPTION 'conflicting source payload was accepted';
  EXCEPTION WHEN SQLSTATE '23505' THEN
    IF SQLERRM <> 'source payload conflict' THEN
      RAISE EXCEPTION 'unexpected conflict message: %', SQLERRM;
    END IF;
  END;
  IF (SELECT count(*) FROM public.user_tags WHERE user_id = auth.uid()) <> 7
    OR (SELECT count(*) FROM public.memo_tag_links WHERE user_id = auth.uid()) <> 7
    OR (SELECT count(*) FROM public.memo_tag_imports WHERE user_id = auth.uid()) <> 1 THEN
    RAISE EXCEPTION 'conflicting import must roll back with no partial writes';
  END IF;
END
$$;

DO $$
DECLARE
  v_src text;
  v_result jsonb;
  v_invalid jsonb;
BEGIN
  -- 5. Validation failures are generic and happen before any mutation.
  -- Container guards must run before jsonb expansion, length checks or UUID
  -- casts; malformed containers must yield the same safe validation error.
  FOR v_invalid IN
    SELECT value FROM jsonb_array_elements($invalid$[
      null, [], 1,
      {"version":1,"catalog":{},"memos":[]},
      {"version":1,"catalog":null,"memos":[]},
      {"version":1,"catalog":[],"memos":{}},
      {"version":1,"catalog":[],"memos":[[]]},
      {"version":1,"catalog":[],"memos":[{"memo_id":"88400000-0000-4000-8000-000000000001","tags":{}}]},
      {"version":1,"catalog":[],"memos":[{"memo_id":"88400000-0000-4000-8000-000000000001","tags":[null,42,{}]}]},
      {"version":1,"catalog":[],"memos":[{"memo_id":"88400000-0000-4000-8000-00000000abcd","tags":[]},{"memo_id":"88400000-0000-4000-8000-00000000ABCD","tags":[]}]}
    ]$invalid$::jsonb)
  LOOP
    BEGIN
      PERFORM public.daypage_import_tags_v1(repeat('0', 64), v_invalid);
      RAISE EXCEPTION 'malformed tag import container or UUID alias accepted';
    EXCEPTION WHEN SQLSTATE '22023' THEN
      IF SQLERRM <> 'invalid tag import payload' THEN
        RAISE EXCEPTION 'unexpected validation message: %', SQLERRM;
      END IF;
    END;
  END LOOP;

  v_src := pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to('reject-controls', 'UTF8')), 'hex');
  BEGIN
    PERFORM public.daypage_import_tags_v1(
      v_src,
      jsonb_build_object('version', 1, 'catalog',
        jsonb_build_array('#bad' || chr(7) || 'tag'), 'memos', '[]'::jsonb)
    );
    RAISE EXCEPTION 'control-character label was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'invalid tag import payload' THEN
      RAISE EXCEPTION 'unexpected validation message: %', SQLERRM;
    END IF;
  END;

  v_src := pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to('reject-del', 'UTF8')), 'hex');
  BEGIN
    PERFORM public.daypage_import_tags_v1(
      v_src,
      jsonb_build_object('version', 1, 'catalog',
        jsonb_build_array('#bad' || chr(127) || 'tag'), 'memos', '[]'::jsonb)
    );
    RAISE EXCEPTION 'DEL label was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'invalid tag import payload' THEN
      RAISE EXCEPTION 'unexpected validation message: %', SQLERRM;
    END IF;
  END;

  v_src := pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to('reject-label-oversize', 'UTF8')), 'hex');
  BEGIN
    PERFORM public.daypage_import_tags_v1(
      v_src,
      jsonb_build_object('version', 1, 'catalog',
        jsonb_build_array('#' || repeat('x', 1024)), 'memos', '[]'::jsonb)
    );
    RAISE EXCEPTION 'oversize label was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'invalid tag import payload' THEN
      RAISE EXCEPTION 'unexpected validation message: %', SQLERRM;
    END IF;
  END;

  v_src := pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to('reject-memo-tags-oversize', 'UTF8')), 'hex');
  BEGIN
    PERFORM public.daypage_import_tags_v1(
      v_src,
      jsonb_build_object(
        'version', 1,
        'catalog', '[]'::jsonb,
        'memos', jsonb_build_array(jsonb_build_object(
          'memo_id', '88400000-0000-4000-8000-000000000001',
          'tags', (SELECT jsonb_agg('#t' || i) FROM generate_series(1, 201) AS i)
        ))
      )
    );
    RAISE EXCEPTION 'memo with 201 labels was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'invalid tag import payload' THEN
      RAISE EXCEPTION 'unexpected validation message: %', SQLERRM;
    END IF;
  END;

  v_src := pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to('reject-payload-oversize', 'UTF8')), 'hex');
  BEGIN
    PERFORM public.daypage_import_tags_v1(
      v_src,
      jsonb_build_object(
        'version', 1,
        'catalog', (SELECT jsonb_agg('#' || repeat('x', 1020)) FROM generate_series(1, 9000) AS i),
        'memos', '[]'::jsonb
      )
    );
    RAISE EXCEPTION 'oversize payload was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'invalid tag import payload' THEN
      RAISE EXCEPTION 'unexpected validation message: %', SQLERRM;
    END IF;
  END;

  v_src := pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to('reject-unknown-key', 'UTF8')), 'hex');
  BEGIN
    PERFORM public.daypage_import_tags_v1(
      v_src, '{"version":1,"catalog":[],"memos":[],"note":"x"}'::jsonb
    );
    RAISE EXCEPTION 'unknown root key was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'invalid tag import payload' THEN
      RAISE EXCEPTION 'unexpected validation message: %', SQLERRM;
    END IF;
  END;

  v_src := pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to('reject-wrong-type', 'UTF8')), 'hex');
  BEGIN
    PERFORM public.daypage_import_tags_v1(
      v_src, '{"version":1,"catalog":[],"memos":[{"memo_id":42,"tags":[]}]}'::jsonb
    );
    RAISE EXCEPTION 'wrong memo_id type was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'invalid tag import payload' THEN
      RAISE EXCEPTION 'unexpected validation message: %', SQLERRM;
    END IF;
  END;

  v_src := pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to('reject-json-null', 'UTF8')), 'hex');
  BEGIN
    PERFORM public.daypage_import_tags_v1(
      v_src, '{"version":1,"catalog":[],"memos":[null]}'::jsonb
    );
    RAISE EXCEPTION 'JSON null memo entry was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'invalid tag import payload' THEN
      RAISE EXCEPTION 'unexpected validation message: %', SQLERRM;
    END IF;
  END;

  v_src := pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to('reject-uuid', 'UTF8')), 'hex');
  BEGIN
    PERFORM public.daypage_import_tags_v1(
      v_src, '{"version":1,"catalog":[],"memos":[{"memo_id":"not-a-uuid","tags":[]}]}'::jsonb
    );
    RAISE EXCEPTION 'invalid memo UUID was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'invalid tag import payload' THEN
      RAISE EXCEPTION 'unexpected validation message: %', SQLERRM;
    END IF;
  END;

  v_src := pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to('reject-duplicate-catalog', 'UTF8')), 'hex');
  BEGIN
    PERFORM public.daypage_import_tags_v1(
      v_src, '{"version":1,"catalog":["#a","#a"],"memos":[]}'::jsonb
    );
    RAISE EXCEPTION 'duplicate catalog entries were accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'invalid tag import payload' THEN
      RAISE EXCEPTION 'unexpected validation message: %', SQLERRM;
    END IF;
  END;

  v_src := pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to('reject-duplicate-memo', 'UTF8')), 'hex');
  BEGIN
    PERFORM public.daypage_import_tags_v1(
      v_src,
      '{"version":1,"catalog":[],"memos":[{"memo_id":"88400000-0000-4000-8000-000000000001","tags":[]},{"memo_id":"88400000-0000-4000-8000-000000000001","tags":[]}]}'::jsonb
    );
    RAISE EXCEPTION 'duplicate memo IDs were accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'invalid tag import payload' THEN
      RAISE EXCEPTION 'unexpected validation message: %', SQLERRM;
    END IF;
  END;

  v_src := pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to('reject-bad-source', 'UTF8')), 'hex');
  BEGIN
    PERFORM public.daypage_import_tags_v1(
      'NOT-A-LOWERHEX-DIGEST', '{"version":1,"catalog":[],"memos":[]}'::jsonb
    );
    RAISE EXCEPTION 'invalid source digest was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'invalid tag import payload' THEN
      RAISE EXCEPTION 'unexpected validation message: %', SQLERRM;
    END IF;
  END;

  v_src := pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to('reject-version', 'UTF8')), 'hex');
  BEGIN
    PERFORM public.daypage_import_tags_v1(
      v_src, '{"version":2,"catalog":[],"memos":[]}'::jsonb
    );
    RAISE EXCEPTION 'unsupported payload version was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'invalid tag import payload' THEN
      RAISE EXCEPTION 'unexpected validation message: %', SQLERRM;
    END IF;
  END;

  -- 6. Memo references: owned AND live only, checked atomically before writes,
  -- with one generic ownership/availability failure and no other-owner detail.
  v_src := pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to('reject-wrong-owner', 'UTF8')), 'hex');
  BEGIN
    PERFORM public.daypage_import_tags_v1(
      v_src,
      '{"version":1,"catalog":["#b/only"],"memos":[{"memo_id":"88400000-0000-4000-8000-000000000011","tags":["#b/only"]}]}'::jsonb
    );
    RAISE EXCEPTION 'other-owner memo reference was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'import references unavailable memos' THEN
      RAISE EXCEPTION 'unexpected ownership failure message: %', SQLERRM;
    END IF;
  END;

  v_src := pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to('reject-missing-memo', 'UTF8')), 'hex');
  BEGIN
    PERFORM public.daypage_import_tags_v1(
      v_src,
      '{"version":1,"catalog":["#missing"],"memos":[{"memo_id":"88400000-0000-4000-8000-00000000f00d","tags":["#missing"]}]}'::jsonb
    );
    RAISE EXCEPTION 'nonexistent memo reference was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'import references unavailable memos' THEN
      RAISE EXCEPTION 'unexpected availability failure message: %', SQLERRM;
    END IF;
  END;

  v_src := pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to('reject-mixed-owner', 'UTF8')), 'hex');
  BEGIN
    PERFORM public.daypage_import_tags_v1(
      v_src,
      '{"version":1,"catalog":["#mixed"],"memos":[{"memo_id":"88400000-0000-4000-8000-000000000001","tags":["#mixed"]},{"memo_id":"88400000-0000-4000-8000-000000000011","tags":[]}]}'::jsonb
    );
    RAISE EXCEPTION 'mixed-ownership payload was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'import references unavailable memos' THEN
      RAISE EXCEPTION 'unexpected mixed-ownership failure message: %', SQLERRM;
    END IF;
  END;

  -- Every rejected import above must leave zero partial writes behind.
  IF (SELECT count(*) FROM public.user_tags WHERE user_id = auth.uid()) <> 7
    OR (SELECT count(*) FROM public.memo_tag_links WHERE user_id = auth.uid()) <> 7
    OR (SELECT count(*) FROM public.memo_tag_imports WHERE user_id = auth.uid()) <> 1 THEN
    RAISE EXCEPTION 'rejected imports must not leave partial writes';
  END IF;

  -- 7. OR-merge: second source reuses an existing catalog label without
  -- clearing its in_import_catalog flag and adds one new catalog label.
  v_result := public.daypage_import_tags_v1(
    pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to('source-two', 'UTF8')), 'hex'),
    '{"version":1,"catalog":["#second/only"],"memos":[{"memo_id":"88400000-0000-4000-8000-000000000001","tags":["#proj/alpha","#second/only"]}]}'::jsonb
  );
  IF v_result->>'status' IS DISTINCT FROM 'imported'
    OR (v_result->>'catalog_labels')::integer <> 1
    OR (v_result->>'distinct_labels')::integer <> 2
    OR (v_result->>'memos')::integer <> 1
    OR (v_result->>'memberships')::integer <> 2 THEN
    RAISE EXCEPTION 'unexpected second-source import result: %', v_result;
  END IF;
  IF (SELECT count(*) FROM public.user_tags WHERE user_id = auth.uid()) <> 8
    OR (SELECT count(*) FROM public.memo_tag_links WHERE user_id = auth.uid()) <> 8
    OR (SELECT count(*) FROM public.memo_tag_imports WHERE user_id = auth.uid()) <> 2 THEN
    RAISE EXCEPTION 'second source must only add its own rows';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.user_tags
    WHERE user_id = auth.uid() AND label = '#proj/alpha' AND in_import_catalog
  ) THEN
    RAISE EXCEPTION 'in_import_catalog must OR-merge true and never downgrade';
  END IF;
END
$$;

RESET ROLE;

-- Soft tombstone as the account owner would apply it via sync.
UPDATE public.memos
SET deleted_at = now()
WHERE id = '88400000-0000-4000-8000-000000000002'
  AND user_id = '99400000-0000-4000-8000-000000000001';

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '99400000-0000-4000-8000-000000000001', true);

DO $$
DECLARE
  v_src text := '2b6ad3c8f0a14e57b9c0d2e4f6a8b0c2d4e6f8a0b2c4d6e8f0a2b4c6d8e0f2a4';
  v_payload jsonb := $payload${"version":1,"catalog":["#proj/alpha","#proj/alpha/beta","#a, b","#标签/子","#emoji🎉","#unused/only-in-catalog"],"memos":[{"memo_id":"88400000-0000-4000-8000-000000000001","tags":["#proj/alpha","#proj/alpha/beta","#a, b"]},{"memo_id":"88400000-0000-4000-8000-000000000002","tags":["#标签/子","#outside-not-in-catalog","#outside-not-in-catalog"]},{"memo_id":"88400000-0000-4000-8000-000000000003","tags":[]},{"memo_id":"88400000-0000-4000-8000-000000000004","tags":["#emoji🎉","#a, b"]}]}$payload$::jsonb;
  v_result jsonb;
BEGIN
  -- 8. A first import referencing a tombstoned memo is rejected: soft-deleted
  -- memos are never (re)linked.
  BEGIN
    PERFORM public.daypage_import_tags_v1(
      pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to('reject-tombstoned', 'UTF8')), 'hex'),
      '{"version":1,"catalog":["#tombstoned"],"memos":[{"memo_id":"88400000-0000-4000-8000-000000000002","tags":["#tombstoned"]}]}'::jsonb
    );
    RAISE EXCEPTION 'tombstoned memo reference was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM <> 'import references unavailable memos' THEN
      RAISE EXCEPTION 'unexpected tombstone failure message: %', SQLERRM;
    END IF;
  END;

  -- 9. Replay still succeeds after the tombstone and returns HISTORICAL
  -- receipt counts; the snapshot and existing links stay untouched.
  v_result := public.daypage_import_tags_v1(v_src, v_payload);
  IF v_result->>'status' IS DISTINCT FROM 'replayed'
    OR (v_result->>'catalog_labels')::integer <> 6
    OR (v_result->>'distinct_labels')::integer <> 7
    OR (v_result->>'memos')::integer <> 4
    OR (v_result->>'memberships')::integer <> 7 THEN
    RAISE EXCEPTION 'replay after tombstone must keep historical counts: %', v_result;
  END IF;
  IF (SELECT count(*) FROM public.user_tags WHERE user_id = auth.uid()) <> 8
    OR (SELECT count(*) FROM public.memo_tag_links WHERE user_id = auth.uid()) <> 8
    OR (SELECT count(*) FROM public.memo_tag_imports WHERE user_id = auth.uid()) <> 2 THEN
    RAISE EXCEPTION 'replay after tombstone must not rewrite tag metadata';
  END IF;
  IF (SELECT count(*) FROM public.memo_tag_links
      WHERE user_id = auth.uid()
        AND memo_id = '88400000-0000-4000-8000-000000000002') <> 2 THEN
    RAISE EXCEPTION 'soft-deleted memo associations must remain intact';
  END IF;
END
$$;

RESET ROLE;

-- Hard delete (a later owner action) cascades its links away via FK.
DELETE FROM public.memos
WHERE id = '88400000-0000-4000-8000-000000000004'
  AND user_id = '99400000-0000-4000-8000-000000000001';

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '99400000-0000-4000-8000-000000000001', true);

DO $$
DECLARE
  v_src text := '2b6ad3c8f0a14e57b9c0d2e4f6a8b0c2d4e6f8a0b2c4d6e8f0a2b4c6d8e0f2a4';
  v_payload jsonb := $payload${"version":1,"catalog":["#proj/alpha","#proj/alpha/beta","#a, b","#标签/子","#emoji🎉","#unused/only-in-catalog"],"memos":[{"memo_id":"88400000-0000-4000-8000-000000000001","tags":["#proj/alpha","#proj/alpha/beta","#a, b"]},{"memo_id":"88400000-0000-4000-8000-000000000002","tags":["#标签/子","#outside-not-in-catalog","#outside-not-in-catalog"]},{"memo_id":"88400000-0000-4000-8000-000000000003","tags":[]},{"memo_id":"88400000-0000-4000-8000-000000000004","tags":["#emoji🎉","#a, b"]}]}$payload$::jsonb;
  v_result jsonb;
BEGIN
  -- 10. Idempotent replay after a memo hard delete: the historical receipt is
  -- returned and nothing is recreated or deleted.
  v_result := public.daypage_import_tags_v1(v_src, v_payload);
  IF v_result->>'status' IS DISTINCT FROM 'replayed'
    OR (v_result->>'catalog_labels')::integer <> 6
    OR (v_result->>'distinct_labels')::integer <> 7
    OR (v_result->>'memos')::integer <> 4
    OR (v_result->>'memberships')::integer <> 7 THEN
    RAISE EXCEPTION 'replay after memo deletion must keep historical counts: %', v_result;
  END IF;
  IF (SELECT count(*) FROM public.user_tags WHERE user_id = auth.uid()) <> 8 THEN
    RAISE EXCEPTION 'replay must not recreate deleted associations as tags';
  END IF;
  IF (SELECT count(*) FROM public.memo_tag_links WHERE user_id = auth.uid()) <> 6 THEN
    RAISE EXCEPTION 'hard-deleted memo links must stay deleted; replay must not recreate them';
  END IF;
  IF (SELECT count(*) FROM public.memo_tag_imports WHERE user_id = auth.uid()) <> 2 THEN
    RAISE EXCEPTION 'replay must not create additional receipts';
  END IF;
END
$$;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '99400000-0000-4000-8000-000000000002', true);

DO $$
DECLARE
  v_result jsonb;
BEGIN
  -- 11. Owner read isolation: account B starts from zero visible rows.
  IF current_user <> 'authenticated'
    OR current_setting('row_security') <> 'on'
    OR EXISTS (SELECT 1 FROM pg_catalog.pg_roles
               WHERE rolname = current_user AND (rolsuper OR rolbypassrls)) THEN
    RAISE EXCEPTION 'isolation test requires a normal authenticated RLS role';
  END IF;
  -- No owner predicate: the database must enforce this isolation itself.
  IF (SELECT count(*) FROM public.user_tags) <> 0
    OR (SELECT count(*) FROM public.memo_tag_links) <> 0
    OR (SELECT count(*) FROM public.memo_tag_imports) <> 0 THEN
    RAISE EXCEPTION 'RLS must hide other accounts'' tag import rows';
  END IF;

  v_result := public.daypage_import_tags_v1(
    pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to('source-owner-b', 'UTF8')), 'hex'),
    '{"version":1,"catalog":["#b/own"],"memos":[{"memo_id":"88400000-0000-4000-8000-000000000011","tags":["#b/own"]}]}'::jsonb
  );
  IF v_result->>'status' IS DISTINCT FROM 'imported'
    OR (v_result->>'memberships')::integer <> 1 THEN
    RAISE EXCEPTION 'account B must import into its own scope: %', v_result;
  END IF;
  IF (SELECT count(*) FROM public.user_tags) <> 1
    OR (SELECT count(*) FROM public.memo_tag_links) <> 1
    OR (SELECT count(*) FROM public.memo_tag_imports) <> 1 THEN
    RAISE EXCEPTION 'account B must only see and write its own rows';
  END IF;
END
$$;

-- 12. anon: no read and no execute.
SET LOCAL ROLE anon;

DO $$
BEGIN
  BEGIN
    PERFORM count(*) FROM public.user_tags;
    RAISE EXCEPTION 'anon read tag import rows';
  EXCEPTION WHEN SQLSTATE '42501' THEN
    NULL;
  END;
  BEGIN
    PERFORM public.daypage_import_tags_v1(
      pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to('source-anon', 'UTF8')), 'hex'),
      '{"version":1,"catalog":[],"memos":[]}'::jsonb
    );
    RAISE EXCEPTION 'anon executed the import RPC';
  EXCEPTION WHEN SQLSTATE '42501' THEN
    NULL;
  END;
END
$$;

RESET ROLE;

-- 13. Direct client writes to tag rows are denied for authenticated.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '99400000-0000-4000-8000-000000000001', true);

DO $$
BEGIN
  BEGIN
    INSERT INTO public.user_tags (user_id, label, in_import_catalog)
    VALUES (auth.uid(), '#forged', true);
    RAISE EXCEPTION 'authenticated inserted user_tags directly';
  EXCEPTION WHEN SQLSTATE '42501' THEN
    NULL;
  END;
  BEGIN
    UPDATE public.user_tags SET in_import_catalog = false WHERE user_id = auth.uid();
    RAISE EXCEPTION 'authenticated updated user_tags directly';
  EXCEPTION WHEN SQLSTATE '42501' THEN
    NULL;
  END;
  BEGIN
    DELETE FROM public.memo_tag_links WHERE user_id = auth.uid();
    RAISE EXCEPTION 'authenticated deleted memo_tag_links directly';
  EXCEPTION WHEN SQLSTATE '42501' THEN
    NULL;
  END;
  BEGIN
    INSERT INTO public.memo_tag_imports (user_id, source_sha256, payload_hash, payload)
    VALUES (auth.uid(), repeat('a', 64), repeat('b', 64), '{}'::jsonb);
    RAISE EXCEPTION 'authenticated inserted memo_tag_imports directly';
  EXCEPTION WHEN SQLSTATE '42501' THEN
    NULL;
  END;
  IF (SELECT count(*) FROM public.user_tags WHERE user_id = auth.uid()) <> 8
    OR (SELECT count(*) FROM public.memo_tag_links WHERE user_id = auth.uid()) <> 6
    OR (SELECT count(*) FROM public.memo_tag_imports WHERE user_id = auth.uid()) <> 2 THEN
    RAISE EXCEPTION 'denied write attempts must not change tag rows';
  END IF;
END
$$;

RESET ROLE;

-- 14. Receipt immutability: even the table owner cannot update a snapshot.
DO $$
BEGIN
  BEGIN
    UPDATE public.memo_tag_imports
    SET payload = '{}'::jsonb
    WHERE user_id = '99400000-0000-4000-8000-000000000001';
    RAISE EXCEPTION 'tag import snapshot was updated';
  EXCEPTION WHEN SQLSTATE '55000' THEN
    IF SQLERRM <> 'tag import snapshots are immutable' THEN
      RAISE EXCEPTION 'unexpected immutability message: %', SQLERRM;
    END IF;
  END;
END
$$;

-- 15. Tag imports never touched memo body/created_at/sync_revision.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM tag_import_memo_baseline baseline
    JOIN public.memos memo ON memo.id = baseline.id
    WHERE memo.id <> '88400000-0000-4000-8000-000000000004'
      AND (
        memo.body IS DISTINCT FROM baseline.body
        OR memo.created_at IS DISTINCT FROM baseline.created_at
        OR memo.sync_revision IS DISTINCT FROM baseline.sync_revision
      )
  ) THEN
    RAISE EXCEPTION 'tag import modified memo body, created_at, or sync_revision';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM tag_import_memo_baseline WHERE id = '88400000-0000-4000-8000-000000000004'
  ) THEN
    RAISE EXCEPTION 'baseline must record the deliberately hard-deleted memo';
  END IF;
END
$$;

ROLLBACK;

\echo 'Account tag import transactional verification passed (single connection; parallel advisory-lock rehearsal remains a separate parent gate).'
