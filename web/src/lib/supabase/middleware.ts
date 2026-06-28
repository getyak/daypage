import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";

// Refresh the Supabase session cookie on every request that passes through
// Next.js middleware. Without this, expired access tokens reach Server
// Components and force users to re-login mid-session. The pattern is taken
// verbatim from @supabase/ssr docs — we MUST return the same `response`
// instance we wrote cookies onto, otherwise the rotated cookies are lost.
export async function updateSession(request: NextRequest) {
  let response = NextResponse.next({ request });

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return request.cookies.getAll();
        },
        setAll(cookiesToSet) {
          cookiesToSet.forEach(({ name, value }) =>
            request.cookies.set(name, value),
          );
          response = NextResponse.next({ request });
          cookiesToSet.forEach(({ name, value, options }) =>
            response.cookies.set(name, value, options),
          );
        },
      },
    },
  );

  // Touch the user to trigger token refresh if needed. Don't gate any logic
  // on the result here — auth-required pages handle their own redirect.
  await supabase.auth.getUser();

  return response;
}
