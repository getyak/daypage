import { NextResponse, type NextRequest } from "next/server";
import { createServerClient, type CookieOptions } from "@supabase/ssr";
import { checkAuthRateLimit } from "@/lib/auth-ratelimit";

// Next.js 16 request proxy. Three responsibilities, in order:
//
//   1. Refresh the Supabase session cookie (inlined from
//      lib/supabase/middleware.ts — we need the resolved `user` here too to
//      drive the auth-gate redirect below, so we can't just delegate).
//   2. Rate-limit /api/auth/* by client IP via Upstash (falls back to in-memory
//      in dev — see lib/auth-ratelimit.ts).
//   3. Redirect anonymous traffic away from authenticated app routes.
//
// Replaces the NextAuth-flavoured proxy that used to wrap `auth()`. Order
// matters: we MUST return the same `response` object that the Supabase cookie
// writer mutated, otherwise rotated cookies are dropped.

const APP_PATHS = [
  "/home",
  "/add",
  "/chat",
  "/wiki",
  "/inbox",
  "/memory-demo",
] as const;

// Shared-backend reading surface (issue #884): `/memos` and its detail pages
// are gated here with a safe full callback (path + query) so anonymous deep
// links survive the login round-trip.
function isMemosPath(pathname: string): boolean {
  return pathname === "/memos" || pathname.startsWith("/memos/");
}

function getClientIp(req: NextRequest): string {
  return (
    req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ??
    req.headers.get("x-real-ip") ??
    "unknown"
  );
}

// Canonical forwarded request header for the app router. The layout reads
// `x-pathname` from REQUEST headers (a Server Component cannot see the request
// URL directly), so the forwarded value is ALWAYS derived from the actual
// parsed request — pathname plus query — and overwrites whatever a client
// sent: a client-provided `x-pathname` is never trusted.
function makeForwardHeaders(request: NextRequest): Headers {
  const headers = new Headers(request.headers);
  headers.set("x-pathname", `${request.nextUrl.pathname}${request.nextUrl.search}`);
  return headers;
}

export async function proxy(request: NextRequest) {
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
  // Public routes must remain available when auth configuration or Supabase is
  // temporarily unavailable. Authenticated routes still fail closed below.
  let response = NextResponse.next({
    request: { headers: makeForwardHeaders(request) },
  });
  let isAuthenticated = false;
  // Every rotated/removed cookie is replayed onto each response recreation so
  // no Supabase cookie-refresh write is ever dropped.
  const rotatedCookies: Array<{ name: string; value: string; options: CookieOptions }> = [];
  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const supabaseAnonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

  if (supabaseUrl && supabaseAnonKey) {
    try {
      const supabase = createServerClient(supabaseUrl, supabaseAnonKey, {
        cookies: {
          getAll() {
            return request.cookies.getAll();
          },
          setAll(cookiesToSet) {
            cookiesToSet.forEach((cookie) => {
              request.cookies.set(cookie.name, cookie.value);
              rotatedCookies.push(cookie);
            });
            // Recreate the response on every cookie write — and re-apply the
            // canonical forwarded request headers each time, so the real
            // path/query and all rotated cookies survive together.
            response = NextResponse.next({
              request: { headers: makeForwardHeaders(request) },
            });
            rotatedCookies.forEach(({ name, value, options }) =>
              response.cookies.set(name, value, options),
            );
          },
        },
      });
      const {
        data: { user },
        error,
      } = await supabase.auth.getUser();

      if (error) {
        console.error("[auth] Supabase session refresh failed", {
          path: pathname,
          message: error.message,
        });
      }
      isAuthenticated = Boolean(user);
    } catch (error) {
      console.error("[auth] Supabase session refresh failed", {
        path: pathname,
        message: error instanceof Error ? error.message : "Unknown error",
      });
    }
  } else {
    console.error("[auth] Supabase public environment is incomplete", {
      path: pathname,
      hasUrl: Boolean(supabaseUrl),
      hasAnonKey: Boolean(supabaseAnonKey),
    });
  }

  // 3. Gate the authenticated app routes. Gate redirects carry any cookies the
  // Supabase refresh just rotated (the redirect is a NEW response object).
  const gatedRedirect = (target: URL): NextResponse => {
    const redirected = NextResponse.redirect(target);
    response.cookies.getAll().forEach((cookie) => redirected.cookies.set(cookie));
    return redirected;
  };
  if (!isAuthenticated && pathname.startsWith("/oauth/consent")) {
    const login = new URL("/login", request.url);
    login.searchParams.set("callbackUrl", `${pathname}${request.nextUrl.search}`);
    return gatedRedirect(login);
  }
  if (!isAuthenticated && isMemosPath(pathname)) {
    // Safe full callback: same-origin path + query, re-sanitised in /login.
    const login = new URL("/login", request.url);
    login.searchParams.set("callbackUrl", `${pathname}${request.nextUrl.search}`);
    return gatedRedirect(login);
  }
  if (!isAuthenticated && APP_PATHS.some((p) => pathname.startsWith(p))) {
    return gatedRedirect(new URL("/login", request.url));
  }

  // 3a. First-visit i18n hint: if the visitor lands on root with no language
  // cookie and their browser advertises Chinese, hop to /zh. Cookie is set on
  // the redirected response so later visits respect the explicit choice.
  const langCookie = request.cookies.get("daypage-lang")?.value;
  const acceptLang = request.headers.get("accept-language") ?? "";
  const wantsZh = /\bzh\b/i.test(acceptLang.split(",")[0] ?? "");
  if (pathname === "/" && !langCookie && wantsZh) {
    // 307 preserves method + is a "temporary" hint that Googlebot treats as
    // *not* the canonical URL for the source — good for language redirects.
    // Vary tells caches/crawlers the response depends on these inputs, so a
    // proxy won't serve /zh HTML to a subsequent en visitor.
    const redirect = gatedRedirect(new URL("/zh", request.url));
    redirect.headers.append("Vary", "Accept-Language, Cookie");
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
  // Merge with Next's auto-Vary (rsc, next-router-*, Accept-Encoding) so the
  // language + auth-cookie signals reach Google's crawler + upstream caches.
  response.headers.append("Vary", "Accept-Language, Cookie");

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
    // Root path is intentionally its own entry — the negative-lookahead below
    // requires at least one character after "/", so it silently excludes "/".
    // The i18n redirect + auth cookie refresh must run on the landing page.
    "/",
    "/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).+)",
  ],
};
