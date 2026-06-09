import "server-only";
import { db } from "@/lib/db/client";
import {
  prompt_log,
  agent_sessions,
  workOrderGateEnum,
  agentBackendEnum,
} from "@/lib/db/schema";
import { and, desc, eq, sql } from "drizzle-orm";
import { Ratelimit } from "@upstash/ratelimit";

// US-006: Policy/Gate engine — a single module guarding budget, rate, and
// side-effect gating for the Gateway. Every dispatch path should consult these
// helpers before spending tokens or running a work order.

// Derive value unions straight from the schema enums so this module stays in
// sync with the DB definitions without a parallel type file.
export type WorkOrderGate = (typeof workOrderGateEnum.enumValues)[number];
export type AgentBackend = (typeof agentBackendEnum.enumValues)[number];

// ── Budget ────────────────────────────────────────────────────────────────────

// Daily token ceiling per user. Overridable via env for ops tuning; defaults to
// a conservative 1M tokens/day (≈ hundreds of compile/suggest cycles).
const DEFAULT_DAILY_TOKEN_LIMIT = 1_000_000;

export function dailyTokenLimit(): number {
  const raw = process.env.GATEWAY_DAILY_TOKEN_LIMIT;
  const parsed = raw ? Number(raw) : NaN;
  return Number.isFinite(parsed) && parsed > 0 ? parsed : DEFAULT_DAILY_TOKEN_LIMIT;
}

export interface BudgetCheck {
  allowed: boolean;
  spent: number;
  limit: number;
}

// Sum a user's prompt_log token usage over the trailing 24h window and compare
// against the daily limit. `treeId` is accepted for forward-compatibility (the
// Gateway scopes spend per evolution tree); prompt_log has no tree column yet,
// so the sum is currently user-scoped regardless.
export async function checkBudget(
  userId: string,
  treeId?: string
): Promise<BudgetCheck> {
  void treeId; // reserved for per-tree scoping once prompt_log carries a tree id
  const since = new Date(Date.now() - 24 * 60 * 60 * 1000);
  const rows = await db
    .select({
      spent: sql<number>`coalesce(sum(${prompt_log.tokens_in} + ${prompt_log.tokens_out}), 0)`,
    })
    .from(prompt_log)
    .where(
      and(
        eq(prompt_log.user_id, userId),
        sql`${prompt_log.created_at} >= ${since}`
      )
    );

  const spent = Number(rows[0]?.spent ?? 0);
  const limit = dailyTokenLimit();
  return { allowed: spent < limit, spent, limit };
}

// ── Gate classification ─────────────────────────────────────────────────────────

// Intents that mutate the outside world or are otherwise irreversible always
// require explicit user approval before dispatch. Tree-internal mutations,
// text generation, and external read-only work run automatically.
const APPROVE_FIRST_PATTERNS: RegExp[] = [
  // external write / publishing / messaging
  /\b(publish|post|tweet|email|send|notify|message|dm|comment|reply)\b/i,
  // code mutation
  /\b(commit|push|merge\s+pr|deploy|release|refactor|patch|write\s+code|edit\s+code|modify\s+(?:file|code|repo))\b/i,
  // destructive / external API writes
  /\b(delete|remove|create\s+(?:pr|issue|repo)|update\s+(?:remote|external)|payment|purchase|charge)\b/i,
];

const AUTO_PATTERNS: RegExp[] = [
  // tree-internal evolution
  /\b(grow|prune|split|branch|tree|node|evolve)\b/i,
  // text generation / compilation
  /\b(summarize|compile|draft|generate\s+text|write\s+up|outline|suggest|annotate|embed)\b/i,
  // external read-only
  /\b(read|fetch|search|lookup|browse|scrape|analyze|review)\b/i,
];

// Classify a work-order intent into a gate decision. Side-effecting intents win
// even if an auto keyword also appears (e.g. "summarize then post it"). Defaults
// to the safer `approve-first` when nothing matches, so unknown intents never
// run unsupervised.
export function classifyGate(intent: string): Extract<WorkOrderGate, "auto" | "approve-first"> {
  const text = intent.trim();
  if (APPROVE_FIRST_PATTERNS.some((re) => re.test(text))) {
    return "approve-first";
  }
  if (AUTO_PATTERNS.some((re) => re.test(text))) {
    return "auto";
  }
  return "approve-first";
}

// ── Circuit breaker ──────────────────────────────────────────────────────────

// Trip the breaker for a backend after this many consecutive failed sessions.
export const CIRCUIT_FAILURE_THRESHOLD = 5;

export interface CircuitState {
  open: boolean; // true = tripped, stop dispatching to this backend
  failures: number; // consecutive recent failures
  threshold: number;
}

// Inspect the most recent sessions for a backend (newest first) and count the
// leading streak of failures (`timed_out`). A single recovered session
// (`active`/`idle`/`closed`) at the head resets the streak to 0.
export async function circuitState(backend: AgentBackend): Promise<CircuitState> {
  const rows = await db
    .select({ status: agent_sessions.status })
    .from(agent_sessions)
    .where(eq(agent_sessions.backend, backend))
    .orderBy(desc(agent_sessions.created_at))
    .limit(CIRCUIT_FAILURE_THRESHOLD);

  let failures = 0;
  for (const row of rows) {
    if (row.status === "timed_out") {
      failures += 1;
    } else {
      break;
    }
  }

  return {
    open: failures >= CIRCUIT_FAILURE_THRESHOLD,
    failures,
    threshold: CIRCUIT_FAILURE_THRESHOLD,
  };
}

// ── Dispatch rate limit ──────────────────────────────────────────────────────
// Reuses the Upstash Ratelimit sliding window (mirrors src/lib/ratelimit.ts),
// with an in-memory fallback for local dev / tests where Upstash is unset.

const DISPATCH_LIMIT = 20; // dispatches per minute per user
const DISPATCH_WINDOW_MS = 60_000;

interface MemWindow {
  count: number;
  reset: number; // epoch ms
}
const dispatchStore = new Map<string, MemWindow>();

function inMemoryDispatchCheck(userId: string): {
  success: boolean;
  remaining: number;
  reset: number;
} {
  const now = Date.now();
  const key = `dispatch:${userId}`;
  const existing = dispatchStore.get(key);
  if (!existing || now > existing.reset) {
    const reset = now + DISPATCH_WINDOW_MS;
    dispatchStore.set(key, { count: 1, reset });
    return { success: true, remaining: DISPATCH_LIMIT - 1, reset };
  }
  if (existing.count >= DISPATCH_LIMIT) {
    return { success: false, remaining: 0, reset: existing.reset };
  }
  existing.count += 1;
  return {
    success: true,
    remaining: DISPATCH_LIMIT - existing.count,
    reset: existing.reset,
  };
}

let dispatchLimiter: Ratelimit | null = null;
let dispatchInit: Promise<Ratelimit | null> | null = null;

async function getDispatchLimiter(): Promise<Ratelimit | null> {
  if (dispatchLimiter) return dispatchLimiter;
  const url = process.env.UPSTASH_REDIS_REST_URL;
  const token = process.env.UPSTASH_REDIS_REST_TOKEN;
  if (!url || !token) return null;
  if (dispatchInit) return dispatchInit;

  // Resolve via a runtime-built import so bundlers can't statically link the
  // optional Upstash redis package (same trick as ratelimit.ts).
  dispatchInit = (async () => {
    try {
      const dynamicImport = new Function("s", "return import(s)") as (s: string) => Promise<unknown>;
      const mod = (await dynamicImport("@upstash/redis")) as {
        Redis: new (cfg: { url: string; token: string }) => unknown;
      };
      dispatchLimiter = new Ratelimit({
        redis: new mod.Redis({ url, token }) as never,
        limiter: Ratelimit.slidingWindow(DISPATCH_LIMIT, "60 s"),
        prefix: "daypage:dispatch",
      });
      return dispatchLimiter;
    } catch {
      return null;
    }
  })();
  return dispatchInit;
}

// Rate-limit Gateway dispatches per user. Returns whether the dispatch is
// allowed plus the remaining budget for the current window.
export async function checkDispatchRateLimit(userId: string): Promise<{
  success: boolean;
  remaining: number;
  reset: number;
}> {
  const limiter = await getDispatchLimiter();
  if (limiter) {
    const r = await limiter.limit(userId);
    return { success: r.success, remaining: r.remaining, reset: r.reset };
  }
  return inMemoryDispatchCheck(userId);
}

export const DISPATCH_RATE_LIMIT = DISPATCH_LIMIT;
export const DISPATCH_RATE_WINDOW_MS = DISPATCH_WINDOW_MS;
