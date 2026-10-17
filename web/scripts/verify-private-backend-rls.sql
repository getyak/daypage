\set ON_ERROR_STOP on

-- Synthetic, transaction-only staging verification. Never run on production.
BEGIN;
SET LOCAL row_security = on;
-- These privileges are visible only inside this transaction and are rolled
-- back. They ensure RLS, rather than missing schema/table ACLs, blocks reads.
GRANT USAGE ON SCHEMA public TO anon, authenticated;
GRANT SELECT, UPDATE ON public.user_settings TO authenticated;
GRANT SELECT ON public.user_settings TO anon;

DO $$
BEGIN
  -- Fail if missing ACLs or a bypass role could obscure an RLS failure.
  IF NOT has_schema_privilege('anon', 'public', 'USAGE')
    OR NOT has_schema_privilege('authenticated', 'public', 'USAGE')
    OR NOT has_table_privilege('anon', 'public.user_settings', 'SELECT')
    OR NOT has_table_privilege('authenticated', 'public.user_settings', 'SELECT')
    OR NOT has_table_privilege('authenticated', 'public.user_settings', 'UPDATE')
    OR EXISTS (SELECT 1 FROM pg_roles
               WHERE rolname IN ('anon', 'authenticated') AND (rolbypassrls OR rolsuper))
    OR current_setting('row_security') <> 'on' THEN
    RAISE EXCEPTION 'RLS test prerequisites missing or obscured by deployment ACLs';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind IN ('r', 'p') AND NOT c.relrowsecurity
  ) THEN
    RAISE EXCEPTION 'a public application table has RLS disabled';
  END IF;
  IF has_function_privilege('anon', 'public.handle_new_auth_user()', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.handle_new_auth_user()', 'EXECUTE') THEN
    RAISE EXCEPTION 'Auth profile trigger is exposed as a client RPC';
  END IF;
END
$$;

INSERT INTO public.users (id, email) VALUES
  ('b4000000-0000-4000-8000-000000000001', 'private-rls-a@example.invalid'),
  ('b4000000-0000-4000-8000-000000000002', 'private-rls-b@example.invalid');
INSERT INTO public.user_settings (user_id, settings) VALUES
  ('b4000000-0000-4000-8000-000000000001', '{"synthetic":"a"}'::jsonb),
  ('b4000000-0000-4000-8000-000000000002', '{"synthetic":"b"}'::jsonb);

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"b4000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.user_settings) THEN
    RAISE EXCEPTION 'server-owned settings leaked through the Data API';
  END IF;
  UPDATE public.user_settings SET settings = '{"synthetic":"modified"}'::jsonb;
  IF FOUND THEN
    RAISE EXCEPTION 'authenticated client modified server-owned settings';
  END IF;
END
$$;

SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claims', '{"role":"anon"}', true);
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.user_settings) THEN
    RAISE EXCEPTION 'anonymous client read private settings';
  END IF;
END
$$;

RESET ROLE;
DO $$
BEGIN
  IF (SELECT count(*) FROM public.user_settings
      WHERE user_id IN ('b4000000-0000-4000-8000-000000000001', 'b4000000-0000-4000-8000-000000000002')
        AND settings IN ('{"synthetic":"a"}'::jsonb, '{"synthetic":"b"}'::jsonb)) <> 2 THEN
    RAISE EXCEPTION 'private settings were changed';
  END IF;
END
$$;
ROLLBACK;

SELECT 'private backend RLS verification passed' AS result;
