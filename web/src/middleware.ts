import { NextRequest, NextResponse } from "next/server";

// Separate in-memory rate limiter for auth endpoints (no Redis dependency in middleware)
interface RateWindow {
  count: number;
  reset: number;
}

const authRateStore = new Map<string, RateWindow>();
const AUTH_LIMIT = 10; // 10 requests
const AUTH_WINDOW_MS = 60_000; // per minute

function checkAuthRateLimit(ip: string): boolean {
  const now = Date.now();
  const existing = authRateStore.get(ip);

  if (!existing || now > existing.reset) {
    authRateStore.set(ip, { count: 1, reset: now + AUTH_WINDOW_MS });
    return true;
  }

  if (existing.count >= AUTH_LIMIT) return false;
  existing.count += 1;
  return true;
}

function getClientIp(req: NextRequest): string {
  return (
    req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ??
    req.headers.get("x-real-ip") ??
    "unknown"
  );
}

export function middleware(req: NextRequest) {
  const { pathname } = req.nextUrl;

  // Rate-limit auth endpoints
  if (pathname.startsWith("/api/auth")) {
    const ip = getClientIp(req);
    if (!checkAuthRateLimit(ip)) {
      return NextResponse.json(
        { error: "Too many requests" },
        {
          status: 429,
          headers: {
            "Retry-After": "60",
            "X-RateLimit-Limit": AUTH_LIMIT.toString(),
            "X-RateLimit-Remaining": "0",
          },
        }
      );
    }
  }

  const res = NextResponse.next();

  // Additional security headers not set via next.config.ts
  res.headers.set("X-Content-Type-Options", "nosniff");
  res.headers.set("X-Frame-Options", "SAMEORIGIN");

  return res;
}

export const config = {
  matcher: [
    "/api/auth/:path*",
    "/((?!_next/static|_next/image|favicon.ico).*)",
  ],
};
