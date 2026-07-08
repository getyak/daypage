// 30 mutations per minute per user.
// Uses @upstash/ratelimit when UPSTASH_REDIS_REST_URL is set; falls back to
// a simple in-memory sliding window for local dev.

import { Ratelimit } from "@upstash/ratelimit";

// ── In-memory fallback ────────────────────────────────────────────────────────

interface Window {
  count: number;
  reset: number; // epoch ms
}

const store = new Map<string, Window>();

function inMemoryCheck(
  key: string,
  limit: number,
  windowMs: number
): { success: boolean; remaining: number; reset: number } {
  const now = Date.now();
  const existing = store.get(key);

  if (!existing || now > existing.reset) {
    const reset = now + windowMs;
    store.set(key, { count: 1, reset });
    return { success: true, remaining: limit - 1, reset };
  }

  if (existing.count >= limit) {
    return { success: false, remaining: 0, reset: existing.reset };
  }

  existing.count += 1;
  return { success: true, remaining: limit - existing.count, reset: existing.reset };
}

// ── Upstash limiter (lazy-initialised) ───────────────────────────────────────

let upstash: Ratelimit | null = null;
let upstashInit: Promise<Ratelimit | null> | null = null;

async function getUpstash(): Promise<Ratelimit | null> {
  if (upstash) return upstash;
  const url = process.env.UPSTASH_REDIS_REST_URL;
  const token = process.env.UPSTASH_REDIS_REST_TOKEN;
  if (!url || !token) return null;
  if (upstashInit) return upstashInit;

  // Resolve via `eval` so bundlers (Turbopack/webpack) cannot statically see
  // the specifier. The package is only required in production when Upstash
  // env vars are configured.
  upstashInit = (async () => {
    try {
      // eslint-disable-next-line @typescript-eslint/no-implied-eval, no-new-func
      const dynamicImport = new Function("s", "return import(s)") as (s: string) => Promise<unknown>;
      const mod = (await dynamicImport("@upstash/redis")) as { Redis: new (cfg: { url: string; token: string }) => unknown };
      upstash = new Ratelimit({
        redis: new mod.Redis({ url, token }) as never,
        limiter: Ratelimit.slidingWindow(30, "60 s"),
        prefix: "daypage:mutations",
      });
      return upstash;
    } catch {
      return null;
    }
  })();
  return upstashInit;
}

// ── Public API ────────────────────────────────────────────────────────────────

export async function checkMutationRateLimit(userId: string): Promise<{
  success: boolean;
  remaining: number;
  reset: number;
}> {
  const limiter = await getUpstash();
  if (limiter) {
    const r = await limiter.limit(userId);
    return { success: r.success, remaining: r.remaining, reset: r.reset };
  }
  return inMemoryCheck(`mutations:${userId}`, 30, 60_000);
}

// Generic keyed limiter for API routes that need custom limits/windows or that
// key on something other than a per-user mutation quota (e.g. an unauthenticated
// webhook keyed by client IP). Uses the shared in-memory sliding window; the
// Upstash mutation limiter above is reserved for the /api/memos write quota.
export function checkRateLimit(
  key: string,
  limit: number,
  windowMs: number
): { success: boolean; remaining: number; reset: number } {
  return inMemoryCheck(key, limit, windowMs);
}

// Best-effort client IP for keying unauthenticated limiters.
export function clientIp(req: Request): string {
  const fwd = req.headers.get("x-forwarded-for");
  if (fwd) return fwd.split(",")[0]!.trim();
  return req.headers.get("x-real-ip") ?? "unknown";
}
