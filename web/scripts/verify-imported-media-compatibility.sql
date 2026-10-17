\set ON_ERROR_STOP on

-- Transaction-only verification for the imported-media compatibility slice
-- (issue #884, ADR-0020, Drizzle migration 0033_imported_media_compatibility).
--
-- Run this against an isolated database only. Everything inside the
-- transaction rolls back; nothing here is durable. Do not run against
-- production. The script performs no DDL of its own: it verifies the objects
-- that migration 0033 is expected to create.

BEGIN;

-- 1. MIME -> extension mapping: AAC -> aac, QuickTime MOV -> mov, and all
--    seven legacy mappings unchanged. Unknown MIME types still return NULL.
DO $$
BEGIN
  IF public.daypage_attachment_extension('audio/m4a') IS DISTINCT FROM 'm4a'
    OR public.daypage_attachment_extension('audio/mp4') IS DISTINCT FROM 'mp4'
    OR public.daypage_attachment_extension('audio/aac') IS DISTINCT FROM 'aac'
    OR public.daypage_attachment_extension('image/jpeg') IS DISTINCT FROM 'jpg'
    OR public.daypage_attachment_extension('image/png') IS DISTINCT FROM 'png'
    OR public.daypage_attachment_extension('image/heic') IS DISTINCT FROM 'heic'
    OR public.daypage_attachment_extension('image/heif') IS DISTINCT FROM 'heif'
    OR public.daypage_attachment_extension('application/pdf') IS DISTINCT FROM 'pdf'
    OR public.daypage_attachment_extension('video/quicktime') IS DISTINCT FROM 'mov'
    OR public.daypage_attachment_extension('AUDIO/AAC') IS DISTINCT FROM 'aac'
    OR public.daypage_attachment_extension('Video/QuickTime') IS DISTINCT FROM 'mov'
    OR public.daypage_attachment_extension('application/x-unknown') IS NOT NULL
    OR public.daypage_attachment_extension('text/plain') IS NOT NULL THEN
    RAISE EXCEPTION 'daypage_attachment_extension mapping drift';
  END IF;
END
$$;

-- 2. Bucket invariants: still private, still 50 MB, and the MIME allow-list is
--    exactly the seven legacy types plus AAC and QuickTime.
DO $$
DECLARE
  v_bucket storage.buckets%ROWTYPE;
BEGIN
  SELECT * INTO v_bucket FROM storage.buckets WHERE id = 'memo-attachments';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'memo-attachments bucket is missing';
  END IF;
  IF v_bucket.public THEN
    RAISE EXCEPTION 'memo-attachments bucket must remain private';
  END IF;
  IF v_bucket.file_size_limit IS DISTINCT FROM 52428800 THEN
    RAISE EXCEPTION 'bucket size limit changed: %', v_bucket.file_size_limit;
  END IF;
  IF cardinality(v_bucket.allowed_mime_types) <> 9
    OR NOT (
      v_bucket.allowed_mime_types @> ARRAY[
        'audio/m4a', 'audio/mp4', 'audio/aac',
        'image/jpeg', 'image/png', 'image/heic', 'image/heif',
        'application/pdf', 'video/quicktime'
      ]
    ) THEN
    RAISE EXCEPTION 'bucket MIME allow-list drifted: %', v_bucket.allowed_mime_types;
  END IF;
END
$$;

-- 3. Grants and RLS are unchanged: the mapping function stays internal, and
--    authenticated clients keep read-only access to memo_attachments.
DO $$
BEGIN
  IF has_function_privilege('authenticated', 'public.daypage_attachment_extension(text)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.daypage_attachment_extension(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'daypage_attachment_extension must not be executable by clients';
  END IF;
  IF has_table_privilege('authenticated', 'public.memo_attachments', 'INSERT')
    OR has_table_privilege('authenticated', 'public.memo_attachments', 'UPDATE')
    OR has_table_privilege('authenticated', 'public.memo_attachments', 'DELETE')
    OR NOT has_table_privilege('authenticated', 'public.memo_attachments', 'SELECT') THEN
    RAISE EXCEPTION 'memo_attachments grants drifted';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_class
    WHERE oid = 'public.memo_attachments'::regclass AND relrowsecurity
  ) THEN
    RAISE EXCEPTION 'memo_attachments RLS must stay enabled';
  END IF;
END
$$;

-- 4. The kind/MIME guard exists and is NOT VALID: historical rows were never
--    scanned or rewritten when it was added.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'memo_attachments_verified_kind_mime_check'
      AND conrelid = 'public.memo_attachments'::regclass
      AND contype = 'c'
      AND NOT convalidated
  ) THEN
    RAISE EXCEPTION 'memo_attachments_verified_kind_mime_check is missing or was validated';
  END IF;
END
$$;

-- 5. Synthetic fixtures (rolled back): a memo whose verified rows cover every
--    settled kind/MIME/extension combination must all insert.
INSERT INTO public.users (id, email) VALUES
  ('f1000000-0000-4000-8000-000000000001', 'verify-imported-media@example.invalid');

INSERT INTO public.memos (id, user_id, body, source, origin, sync_revision) VALUES
  (
    'f2000000-0000-4000-8000-000000000001',
    'f1000000-0000-4000-8000-000000000001',
    'verify imported media compatibility',
    'web', 'web', 1
  );

DO $$
DECLARE
  v_combo record;
  v_position integer := 0;
BEGIN
  FOR v_combo IN
    SELECT * FROM (VALUES
      ('photo', 'image/jpeg'),
      ('photo', 'image/png'),
      ('photo', 'image/heic'),
      ('photo', 'image/heif'),
      ('audio', 'audio/m4a'),
      ('audio', 'audio/mp4'),
      ('audio', 'audio/aac'),
      ('file', 'application/pdf'),
      ('file', 'video/quicktime')
    ) AS settled(kind, mime_type)
  LOOP
    INSERT INTO public.memo_attachments (
      memo_id, kind, storage_key, filename, mime_type, size_bytes,
      protocol_version, position, content_sha256, verified_at
    ) VALUES (
      'f2000000-0000-4000-8000-000000000001',
      v_combo.kind::public.attachment_kind,
      'verify-imported-media/' || v_position,
      'sample-' || v_position,
      v_combo.mime_type,
      1024,
      2,
      v_position,
      repeat('b', 64),
      statement_timestamp()
    );
    v_position := v_position + 1;
  END LOOP;
  IF v_position <> 9 THEN
    RAISE EXCEPTION 'settled mapping matrix shrank: %', v_position;
  END IF;
END
$$;

-- 6. Wrong kind/MIME combinations for newly verified rows fail closed:
--    QuickTime MOV is never a photo, AAC is never a file or photo, and a
--    verified row without a MIME type is rejected.
DO $$
BEGIN
  BEGIN
    INSERT INTO public.memo_attachments (
      memo_id, kind, storage_key, mime_type, size_bytes,
      protocol_version, position, content_sha256, verified_at
    ) VALUES (
      'f2000000-0000-4000-8000-000000000001', 'photo', 'verify-imported-media/mov-photo',
      'video/quicktime', 1024, 2, 20, repeat('c', 64), statement_timestamp()
    );
    RAISE EXCEPTION 'QuickTime MOV as photo was not rejected';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  BEGIN
    INSERT INTO public.memo_attachments (
      memo_id, kind, storage_key, mime_type, size_bytes,
      protocol_version, position, content_sha256, verified_at
    ) VALUES (
      'f2000000-0000-4000-8000-000000000001', 'file', 'verify-imported-media/aac-file',
      'audio/aac', 1024, 2, 21, repeat('c', 64), statement_timestamp()
    );
    RAISE EXCEPTION 'AAC as file was not rejected';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  BEGIN
    INSERT INTO public.memo_attachments (
      memo_id, kind, storage_key, mime_type, size_bytes,
      protocol_version, position, content_sha256, verified_at
    ) VALUES (
      'f2000000-0000-4000-8000-000000000001', 'audio', 'verify-imported-media/mov-audio',
      'video/quicktime', 1024, 2, 22, repeat('c', 64), statement_timestamp()
    );
    RAISE EXCEPTION 'QuickTime MOV as audio was not rejected';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  BEGIN
    INSERT INTO public.memo_attachments (
      memo_id, kind, storage_key, mime_type, size_bytes,
      protocol_version, position, content_sha256, verified_at
    ) VALUES (
      'f2000000-0000-4000-8000-000000000001', 'audio', 'verify-imported-media/missing-mime',
      NULL, 1024, 2, 23, repeat('c', 64), statement_timestamp()
    );
    RAISE EXCEPTION 'verified row without a MIME type was not rejected';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
END
$$;

-- 7. Legacy unverified rows stay fully compatible: rows without a verified
--    content hash may keep any historical kind/MIME pairing and can still be
--    updated without tripping the guard.
DO $$
BEGIN
  INSERT INTO public.memo_attachments (
    memo_id, kind, storage_key, filename, mime_type, size_bytes
  ) VALUES (
    'f2000000-0000-4000-8000-000000000001', 'file',
    'verify-imported-media/legacy', 'legacy.m4a', 'audio/m4a', 100
  );
  UPDATE public.memo_attachments
  SET filename = 'legacy-renamed.m4a'
  WHERE storage_key = 'verify-imported-media/legacy';
  IF NOT EXISTS (
    SELECT 1 FROM public.memo_attachments
    WHERE storage_key = 'verify-imported-media/legacy'
      AND filename = 'legacy-renamed.m4a'
      AND content_sha256 IS NULL
  ) THEN
    RAISE EXCEPTION 'legacy unverified attachment row is not compatible';
  END IF;
END
$$;

-- 8. The v2 canonical manifest hash encoding is unchanged. This vector is
--    cross-checked against packages/contracts/manifest-hash.mjs and the Swift
--    AttachmentManifest.hash implementation.
DO $$
DECLARE
  v_vector jsonb := '[{"position": 0, "kind": "audio", "content_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "size_bytes": 12, "mime_type": "audio/aac", "object_key": "11111111-1111-4111-8111-111111111111/22222222-2222-4222-8222-222222222222/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.aac", "original_filename": "note.aac", "duration_ms": null, "transcript": null, "transcription_status": null}]'::jsonb;
BEGIN
  IF public.daypage_attachment_manifest_hash(v_vector)
    IS DISTINCT FROM 'e33882caa25cf2cf4e034d2dfaa15fa38037e3f3668ac185966440d3398591f3' THEN
    RAISE EXCEPTION 'v2 canonical manifest hash encoding drifted';
  END IF;
END
$$;

ROLLBACK;

SELECT 'imported media compatibility verification passed' AS result;
