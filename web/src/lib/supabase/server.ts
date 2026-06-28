import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";

// Cookie-bound Supabase client for Server Components, Route Handlers, and
// Server Actions. Reads NEXT_PUBLIC_SUPABASE_URL / NEXT_PUBLIC_SUPABASE_ANON_KEY
// from process.env at request time. The cookies() handle is request-scoped, so
// Next.js requires we re-acquire it inside the factory.
export async function createClient() {
  const cookieStore = await cookies();
  return createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return cookieStore.getAll();
        },
        setAll(cookiesToSet) {
          try {
            cookiesToSet.forEach(({ name, value, options }) =>
              cookieStore.set(name, value, options),
            );
          } catch {
            // setAll throws inside a Server Component render — that path is
            // handled by middleware refreshing the session, so swallowing here
            // is the documented pattern from @supabase/ssr.
          }
        },
      },
    },
  );
}
