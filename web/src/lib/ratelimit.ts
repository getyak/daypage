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

function getUpstash(): Ratelimit | null {
  if (upstash) return upstash;
  const url = process.env.UPSTASH_REDIS_REST_URL;
  const token = process.env.UPSTASH_REDIS_REST_TOKEN;
  if (!url || !token) return null;

  // Dynamic require so the module can still be imported when Redis is absent
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const { Redis } = require("@upstash/redis") as typeof import("@upstash/redis");
  upstash = new Ratelimit({
    redis: new Redis({ url, token }),
    limiter: Ratelimit.slidingWindow(30, "60 s"),
    prefix: "daypage:mutations",
  });
  return upstash;
}

// ── Public API ────────────────────────────────────────────────────────────────

export async function checkMutationRateLimit(userId: string): Promise<{
  success: boolean;
  remaining: number;
  reset: number;
}> {
  const limiter = getUpstash();
  if (limiter) {
    const r = await limiter.limit(userId);
    return { success: r.success, remaining: r.remaining, reset: r.reset };
  }
  return inMemoryCheck(`mutations:${userId}`, 30, 60_000);
}
