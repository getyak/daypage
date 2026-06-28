-- US-049: Migrate from NextAuth to Supabase Auth.
--
-- 1. Drop the three NextAuth tables (accounts / sessions / verificationTokens)
--    and the two NextAuth-only columns on `public.users`.
-- 2. Reshape `public.users` into a Supabase profile table:
--      - id mirrors auth.users.id (no defaultRandom anymore — the trigger
--        inserts the row using the new auth user's UUID).
--      - 25 business-table FKs to public.users(id) keep working because the
--        profile row exists for every auth user.
-- 3. Install the `handle_new_auth_user` trigger so every new auth.users row
--    auto-inserts a matching public.users profile row.
-- 4. Backfill: for any existing auth.users that doesn't yet have a profile,
--    insert one (idempotent — safe on a fresh DB too).
--
-- RLS policies for memos / memo_attachments / etc. (auth.uid() = user_id) are
-- managed in the Supabase Dashboard — see docs/supabase-auth-setup.md.

-- ── 1. Drop NextAuth tables ───────────────────────────────────────────────────
DROP TABLE IF EXISTS "verificationTokens" CASCADE;
DROP TABLE IF EXISTS "sessions" CASCADE;
DROP TABLE IF EXISTS "accounts" CASCADE;

-- ── 2. Drop NextAuth-only columns from public.users ───────────────────────────
ALTER TABLE "users" DROP COLUMN IF EXISTS "emailVerified";
ALTER TABLE "users" DROP COLUMN IF EXISTS "image";

-- ── 2b. id no longer defaults — it's set from auth.users.id by the trigger. ──
ALTER TABLE "users" ALTER COLUMN "id" DROP DEFAULT;

-- ── 3. Trigger: auth.users INSERT → public.users INSERT ───────────────────────
-- Runs with SECURITY DEFINER so it can insert into public schema while the
-- auth.users insert happens as the postgres role (not the end user).
CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.users (id, email, name, avatar_url, created_at)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(
      NEW.raw_user_meta_data ->> 'name',
      NEW.raw_user_meta_data ->> 'full_name',
      split_part(NEW.email, '@', 1)
    ),
    NEW.raw_user_meta_data ->> 'avatar_url',
    NEW.created_at
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
AFTER INSERT ON auth.users
FOR EACH ROW EXECUTE FUNCTION public.handle_new_auth_user();

-- ── 4. Backfill profiles for any existing auth users ─────────────────────────
INSERT INTO public.users (id, email, name, created_at)
SELECT
  au.id,
  au.email,
  COALESCE(
    au.raw_user_meta_data ->> 'name',
    au.raw_user_meta_data ->> 'full_name',
    split_part(au.email, '@', 1)
  ),
  au.created_at
FROM auth.users au
LEFT JOIN public.users pu ON pu.id = au.id
WHERE pu.id IS NULL;
