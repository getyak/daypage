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
import { treeSpentTokens } from "@/lib/gateway/cost";

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
  // Which budget the decision was made against: the user's trailing-24h daily
  // token ceiling, or a single evolution tree's per-tree ceiling. Surfaced so
  // the skip/park reason can name the right budget.
  scope: "daily" | "per-tree";
}

// US-031: optional per-tree budget enforcement. When the caller passes both a
// `treeId` and a positive `perTreeBudgetTokens` (read from the user's
// `user_settings.evolution.perTreeBudgetTokens`), the targeted tree's committed
// spend is checked against its own ceiling *in addition to* the user-level daily
// limit — whichever budget is exhausted first blocks the dispatch.
export interface CheckBudgetOptions {
  // The evolution tree the work targets (from work_order.context.tree_id).
  treeId?: string;
  // The tree's token ceiling from the user's evolution config. Only enforced
  // when > 0; omit/0 to skip per-tree enforcement and use the daily limit only.
  perTreeBudgetTokens?: number;
}

// Sum a user's prompt_log token usage over the trailing 24h window and compare
// against the daily limit. When per-tree options are supplied, additionally
// gate the targeted tree's committed spend against its per-tree ceiling and
// return the first budget that blocks.
//
// Backward-compatible: `checkBudget(userId)` and `checkBudget(userId, treeId)`
// (the legacy positional string signature) both still work — a bare string
// treeId enforces the daily limit only (no per-tree ceiling without a budget).
export async function checkBudget(
  userId: string,
  options?: string | CheckBudgetOptions
): Promise<BudgetCheck> {
  const opts: CheckBudgetOptions =
    typeof options === "string" ? { treeId: options } : options ?? {};

  // ── Per-tree gate (only when both a tree and a positive budget are given) ──
  if (opts.treeId && opts.perTreeBudgetTokens && opts.perTreeBudgetTokens > 0) {
    const treeSpent = await treeSpentTokens(userId, opts.treeId);
    if (treeSpent >= opts.perTreeBudgetTokens) {
      return {
        allowed: false,
        spent: treeSpent,
        limit: opts.perTreeBudgetTokens,
        scope: "per-tree",
      };
    }
  }

  // ── Daily user-level gate ─────────────────────────────────────────────────
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
  return { allowed: spent < limit, spent, limit, scope: "daily" };
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

// ── Execution routing ────────────────────────────────────────────────────────
// US-026: route a work order to an executor target by side-effect weight.
// Lightweight, no-side-effect work (fetch a page, read, generate text) runs on
// the self-hosted `sandbox`. Heavy / side-effecting work (mutate code, long
// multi-step tasks, external writes) is outsourced to a heavy backend. The
// rules live here in the policy so routing stays centralized and unit-tested.

// The executor an order is dispatched to. `sandbox` is the self-hosted cheap
// runner; the rest are outsourced heavy backends. Mirrors `agentBackendEnum`.
export type ExecutionTarget = AgentBackend;

// The three outsourced heavy backends. Code-mutation work goes to `claude-code`
// (the only connector wired today); long/multi-step work to `ralph`; any other
// side-effecting / external-write work to `openclaw`.
export type OutsourcedBackend = Exclude<ExecutionTarget, "sandbox">;

// Code-mutation intents — outsource to claude-code (repo edits, refactors, PRs).
const CODE_MUTATION_PATTERNS: RegExp[] = [
  /\b(commit|push|merge\s+pr|deploy|release|refactor|patch|rewrite\s+code|write\s+code|edit\s+code|implement)\b/i,
  // "create [a] PR" — allow an optional intervening word ("create a PR").
  /\bcreate\b\s+(?:\w+\s+)?\bpr\b/i,
  // "modify [the] [config] file/code/repo" — allow intervening words.
  /\bmodify\b\s+(?:\w+\s+)*(?:file|code|repo)\b/i,
  // "fix [the] bug" — allow an optional intervening word.
  /\bfix\b\s+(?:\w+\s+)?\bbug\b/i,
];

// Long-running / multi-step intents — outsource to ralph (the autonomous loop).
const LONG_TASK_PATTERNS: RegExp[] = [
  /\b(migrate|migration|backfill|build\s+(?:feature|system)|long[-\s]?running|multi[-\s]?step|campaign|overnight|loop\s+until|autonomous)\b/i,
];

// Lightweight, read-only / text-only intents — keep on the self-hosted sandbox.
const SANDBOX_PATTERNS: RegExp[] = [
  // external read-only
  /\b(read|fetch|search|lookup|browse|scrape|crawl|analyze|review|inspect)\b/i,
  // text generation / compilation (no external side effect)
  /\b(summarize|compile|draft|generate\s+text|write\s+up|outline|suggest|annotate|embed|translate|format)\b/i,
];

export interface RouteDecision {
  target: ExecutionTarget;
  // Why this target was chosen — surfaced in logs / change_log for auditing.
  reason: string;
}

/**
 * Route a work-order intent to an executor target by side-effect weight.
 *
 * Order of precedence (heaviest side effect wins, so a mixed intent like
 * "refactor then summarize" still outsources):
 *   1. code mutation         → 'claude-code'
 *   2. long / multi-step      → 'ralph'
 *   3. lightweight read/text  → 'sandbox'
 *   4. otherwise side-effecting → 'openclaw' (safe default for unknown intents,
 *      since an unclassified intent may write to the outside world)
 */
export function classifyRoute(intent: string): RouteDecision {
  const text = intent.trim();

  if (CODE_MUTATION_PATTERNS.some((re) => re.test(text))) {
    return { target: "claude-code", reason: "code-mutation → claude-code" };
  }
  if (LONG_TASK_PATTERNS.some((re) => re.test(text))) {
    return { target: "ralph", reason: "long/multi-step → ralph" };
  }
  if (SANDBOX_PATTERNS.some((re) => re.test(text))) {
    return { target: "sandbox", reason: "lightweight read/text → sandbox" };
  }
  // Unknown intent: assume it may have side effects and outsource it rather
  // than running it unsupervised on the sandbox.
  return { target: "openclaw", reason: "unclassified side-effecting → openclaw" };
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
