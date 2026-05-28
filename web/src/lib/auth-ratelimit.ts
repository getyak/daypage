// Rate limiter for /api/auth — separate from the per-user mutation limiter in
// ratelimit.ts. Keyed by client IP. Uses the Upstash Redis REST API directly
// when configured (works in any Next.js runtime); falls back to an in-memory
// sliding window for local dev.
//
// The previous in-memory-only implementation lived in middleware.ts and was
// a no-op in production because Next.js Middleware runs in the Edge runtime
// where module state is not shared across requests.

const AUTH_LIMIT = 10;
const AUTH_WINDOW_SEC = 60;

// ── In-memory fallback (dev only) ────────────────────────────────────────────

interface MemWindow {
  count: number;
  reset: number; // epoch ms
}
const memStore = new Map<string, MemWindow>();

function inMemoryCheck(key: string): {
  success: boolean;
  remaining: number;
  reset: number;
} {
  const now = Date.now();
  const windowMs = AUTH_WINDOW_SEC * 1000;
  const existing = memStore.get(key);
  if (!existing || now > existing.reset) {
    const reset = now + windowMs;
    memStore.set(key, { count: 1, reset });
    return { success: true, remaining: AUTH_LIMIT - 1, reset };
  }
  if (existing.count >= AUTH_LIMIT) {
    return { success: false, remaining: 0, reset: existing.reset };
  }
  existing.count += 1;
  return {
    success: true,
    remaining: AUTH_LIMIT - existing.count,
    reset: existing.reset,
  };
}

// ── Upstash REST ─────────────────────────────────────────────────────────────

interface UpstashPipelineResult {
  result: number | string | null;
}

async function upstashCheck(
  url: string,
  token: string,
  key: string
): Promise<{ success: boolean; remaining: number; reset: number } | null> {
  // INCR the counter, set TTL only on the first hit (NX), then read the
  // remaining TTL. One round-trip via the REST pipeline endpoint.
  const body = JSON.stringify([
    ["INCR", `daypage:auth:${key}`],
    ["EXPIRE", `daypage:auth:${key}`, String(AUTH_WINDOW_SEC), "NX"],
    ["PTTL", `daypage:auth:${key}`],
  ]);
  try {
    const res = await fetch(`${url}/pipeline`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
      },
      body,
    });
    if (!res.ok) return null;
    const parsed = (await res.json()) as UpstashPipelineResult[];
    const count = Number(parsed[0]?.result ?? 0);
    const ttlMs = Number(parsed[2]?.result ?? AUTH_WINDOW_SEC * 1000);
    const now = Date.now();
    const reset = now + (ttlMs > 0 ? ttlMs : AUTH_WINDOW_SEC * 1000);
    if (count > AUTH_LIMIT) {
      return { success: false, remaining: 0, reset };
    }
    return { success: true, remaining: Math.max(0, AUTH_LIMIT - count), reset };
  } catch {
    return null;
  }
}

export async function checkAuthRateLimit(
  ip: string
): Promise<{ success: boolean; remaining: number; reset: number; limit: number }> {
  const url = process.env.UPSTASH_REDIS_REST_URL;
  const token = process.env.UPSTASH_REDIS_REST_TOKEN;
  if (url && token) {
    const r = await upstashCheck(url, token, ip);
    if (r) return { ...r, limit: AUTH_LIMIT };
  }
  return { ...inMemoryCheck(ip), limit: AUTH_LIMIT };
}

export const AUTH_RATE_LIMIT = AUTH_LIMIT;
export const AUTH_RATE_WINDOW_SEC = AUTH_WINDOW_SEC;
