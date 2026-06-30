import { NextResponse, type NextRequest } from "next/server";
import { createServerClient } from "@supabase/ssr";
import { checkAuthRateLimit } from "@/lib/auth-ratelimit";

// Next.js 16 root middleware. Three responsibilities, in order:
//
//   1. Refresh the Supabase session cookie (inlined from
//      lib/supabase/middleware.ts — we need the resolved `user` here too to
//      drive the auth-gate redirect below, so we can't just delegate).
//   2. Rate-limit /api/auth/* by client IP via Upstash (falls back to in-memory
//      in dev — see lib/auth-ratelimit.ts).
//   3. Redirect anonymous traffic away from authenticated app routes.
//
// Replaces the NextAuth-flavoured `proxy.ts` that used to wrap `auth()`. Order
// matters: we MUST return the same `response` object that the Supabase cookie
// writer mutated, otherwise rotated cookies are dropped.

const APP_PATHS = ["/home", "/add", "/chat", "/wiki", "/inbox"] as const;

function getClientIp(req: NextRequest): string {
  return (
    req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ??
    req.headers.get("x-real-ip") ??
    "unknown"
  );
}

export async function middleware(request: NextRequest) {
  const start = Date.now();
  const { pathname } = request.nextUrl;

  // 1. Rate-limit auth endpoints first — cheaper than touching Supabase.
  if (pathname.startsWith("/api/auth")) {
    const r = await checkAuthRateLimit(getClientIp(request));
    if (!r.success) {
      return NextResponse.json(
        { error: "Too many requests" },
        {
          status: 429,
          headers: {
            "Retry-After": Math.max(
              1,
              Math.ceil((r.reset - Date.now()) / 1000)
            ).toString(),
            "X-RateLimit-Limit": r.limit.toString(),
            "X-RateLimit-Remaining": r.remaining.toString(),
          },
        }
      );
    }
  }

  // 2. Refresh Supabase session cookie. Mirrors the @supabase/ssr docs pattern.
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
  const {
    data: { user },
  } = await supabase.auth.getUser();

  // 3. Gate the authenticated app routes.
  if (!user && APP_PATHS.some((p) => pathname.startsWith(p))) {
    return NextResponse.redirect(new URL("/login", request.url));
  }

  // 3a. First-visit i18n hint: if the visitor lands on root with no language
  // cookie and their browser advertises Chinese, hop to /zh. Cookie is set on
  // the redirected response so later visits respect the explicit choice.
  const langCookie = request.cookies.get("daypage-lang")?.value;
  const acceptLang = request.headers.get("accept-language") ?? "";
  const wantsZh = /\bzh\b/i.test(acceptLang.split(",")[0] ?? "");
  if (pathname === "/" && !langCookie && wantsZh) {
    const redirect = NextResponse.redirect(new URL("/zh", request.url));
    redirect.cookies.set("daypage-lang", "zh", {
      maxAge: 60 * 60 * 24 * 365,
      sameSite: "lax",
      path: "/",
    });
    return redirect;
  }

  // 4. Augment response with timing/security headers (kept from old proxy).
  response.headers.set("x-middleware-start", start.toString());
  response.headers.set("x-pathname", pathname);
  response.headers.set("X-Content-Type-Options", "nosniff");
  response.headers.set("X-Frame-Options", "SAMEORIGIN");

  if (pathname.startsWith("/api/")) {
    console.log(
      JSON.stringify({
        ts: new Date().toISOString(),
        method: request.method,
        path: pathname,
        duration_ms: Date.now() - start,
      })
    );
  }

  return response;
}

export const config = {
  matcher: [
    "/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)",
  ],
};
