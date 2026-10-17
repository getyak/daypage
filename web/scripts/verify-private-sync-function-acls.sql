\set ON_ERROR_STOP on

-- Privilege-only verification: no data reads or persistent changes.
BEGIN;
DO $$
DECLARE
  routine text;
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname LIKE 'daypage_%'
      AND p.proname NOT IN ('daypage_mcp_api_key_request', 'daypage_mcp_action_api_key_request_v1')
      AND has_function_privilege('anon', p.oid, 'EXECUTE')
  ) THEN
    RAISE EXCEPTION 'unexpected anonymous DayPage RPC';
  END IF;

  FOREACH routine IN ARRAY ARRAY[
    'public.daypage_length_prefix(text)',
    'public.daypage_attachment_extension(text)',
    'public.daypage_attachment_manifest_hash(jsonb)',
    'public.daypage_bump_memo_change_sequence()',
    'public.daypage_queue_memo_attachment_gc()',
    'public.daypage_enqueue_memo_revision()',
    'public.handle_new_auth_user()',
    'public.daypage_inventory_attachment_orphans()',
    'public.daypage_claim_attachment_gc(integer)',
    'public.daypage_finish_attachment_gc(uuid,text,uuid,boolean,text)'
  ] LOOP
    IF has_function_privilege('anon', routine, 'EXECUTE')
      OR has_function_privilege('authenticated', routine, 'EXECUTE') THEN
      RAISE EXCEPTION 'private routine exposed to clients: %', routine;
    END IF;
  END LOOP;

  FOREACH routine IN ARRAY ARRAY[
    'public.daypage_inventory_attachment_orphans()',
    'public.daypage_claim_attachment_gc(integer)',
    'public.daypage_finish_attachment_gc(uuid,text,uuid,boolean,text)'
  ] LOOP
    IF NOT has_function_privilege('service_role', routine, 'EXECUTE') THEN
      RAISE EXCEPTION 'service-role GC access missing: %', routine;
    END IF;
  END LOOP;

  FOREACH routine IN ARRAY ARRAY[
    'public.daypage_apply_sync_operations(jsonb)',
    'public.daypage_apply_sync_operations_v2(jsonb)',
    'public.daypage_prepare_attachment_upload(uuid,text,bigint,text,text)',
    'public.daypage_pull_memo_changes(timestamptz,integer)',
    'public.daypage_pull_sync_changes(bigint,integer)',
    'public.daypage_pull_sync_changes_v2(bigint,integer)'
  ] LOOP
    IF NOT has_function_privilege('authenticated', routine, 'EXECUTE') THEN
      RAISE EXCEPTION 'authenticated sync access missing: %', routine;
    END IF;
  END LOOP;

  IF NOT has_function_privilege('anon', 'public.daypage_mcp_api_key_request(text,text,jsonb)', 'EXECUTE')
    OR NOT has_function_privilege('anon', 'public.daypage_mcp_action_api_key_request_v1(text,text,jsonb)', 'EXECUTE') THEN
    RAISE EXCEPTION 'PAT-gated MCP entry point was disabled';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_default_acl d
    JOIN pg_namespace n ON n.oid = d.defaclnamespace
    CROSS JOIN LATERAL aclexplode(d.defaclacl) a
    WHERE d.defaclrole = 'postgres'::regrole AND n.nspname = 'public'
      AND d.defaclobjtype = 'f' AND a.privilege_type = 'EXECUTE'
      AND a.grantee IN ('anon'::regrole, 'authenticated'::regrole)
  ) THEN
    RAISE EXCEPTION 'new application functions still inherit explicit client grants';
  END IF;
END
$$;
ROLLBACK;
SELECT 'private sync function ACL verification passed' AS result;
