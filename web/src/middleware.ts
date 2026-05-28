import { NextRequest, NextResponse } from "next/server";
import { checkAuthRateLimit } from "@/lib/auth-ratelimit";

// NOTE: Next.js Middleware runs in the Edge runtime by default. Module-level
// state (Map, counters, etc.) is NOT shared across requests there — a cold
// start resets it. The previous implementation kept the counter in a
// module-level Map and was a no-op in production. The auth rate limiter has
// been moved to lib/auth-ratelimit.ts, which uses Upstash Redis via the REST
// API (works in any runtime) and only falls back to in-memory in local dev
// when UPSTASH_REDIS_REST_* env vars are unset.

function getClientIp(req: NextRequest): string {
  return (
    req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ??
    req.headers.get("x-real-ip") ??
    "unknown"
  );
}

export async function middleware(req: NextRequest) {
  const { pathname } = req.nextUrl;
  const start = Date.now();

  // Rate-limit auth endpoints (distributed via Upstash when configured).
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

  const res = NextResponse.next();

  // Inject timing info for downstream logging
  res.headers.set("x-middleware-start", start.toString());

  // Additional security headers
  res.headers.set("X-Content-Type-Options", "nosniff");
  res.headers.set("X-Frame-Options", "SAMEORIGIN");

  // Request logging for API routes (console; api_logs written by route handlers for errors)
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
}

export const config = {
  matcher: [
    "/api/auth/:path*",
    "/((?!_next/static|_next/image|favicon.ico).*)",
  ],
};
