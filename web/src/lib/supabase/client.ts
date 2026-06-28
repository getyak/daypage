import { createBrowserClient } from "@supabase/ssr";

// Browser-side Supabase client for "use client" components that need to call
// auth methods directly (e.g. signInWithOAuth's PKCE redirect for Apple in
// non-form-action contexts). NEXT_PUBLIC_* env vars are inlined into the
// client bundle at build time.
export function createClient() {
  return createBrowserClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
  );
}
