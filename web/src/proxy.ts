import { NextResponse } from "next/server";
import type { NextRequest } from "next/server";
import { auth } from "@/auth";
import { checkAuthRateLimit } from "@/lib/auth-ratelimit";

// Next.js 16 unified proxy (formerly middleware). Runs in the Edge runtime by
// default — do NOT keep module-level mutable state here; cold starts reset it.
// The auth rate limiter lives in lib/auth-ratelimit.ts and uses Upstash Redis
// via the REST API (works in any runtime), falling back to in-memory only when
// UPSTASH_REDIS_REST_* env vars are unset (local dev).

const APP_PATHS = ["/home", "/add", "/chat", "/wiki", "/inbox"] as const;

function getClientIp(req: NextRequest): string {
  return (
    req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ??
    req.headers.get("x-real-ip") ??
    "unknown"
  );
}

export default auth(async (req) => {
  const { pathname } = req.nextUrl;
  const start = Date.now();

  // 1. Rate-limit auth endpoints (distributed via Upstash when configured).
  if (pathname.startsWith("/api/auth")) {
    const ip = getClientIp(req);
    const r = await checkAuthRateLimit(ip);
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

  // 2. Protect authenticated app routes — redirect anonymous users to /login.
  const isLoggedIn = !!req.auth;
  if (!isLoggedIn && APP_PATHS.some((p) => pathname.startsWith(p))) {
    return NextResponse.redirect(new URL("/login", req.url));
  }

  // 3. Default response with timing + security headers + pathname.
  const res = NextResponse.next();
  res.headers.set("x-middleware-start", start.toString());
  res.headers.set("x-pathname", pathname);
  res.headers.set("X-Content-Type-Options", "nosniff");
  res.headers.set("X-Frame-Options", "SAMEORIGIN");

  // 4. Request logging for API routes (console; api_logs is written by route
  //    handlers themselves for error cases).
  if (pathname.startsWith("/api/")) {
    const duration = Date.now() - start;
    console.log(
      JSON.stringify({
        ts: new Date().toISOString(),
        method: req.method,
        path: pathname,
        duration_ms: duration,
      })
    );
  }

  return res;
});

export const config = {
  matcher: [
    "/api/auth/:path*",
    "/((?!_next/static|_next/image|favicon.ico).*)",
  ],
};
