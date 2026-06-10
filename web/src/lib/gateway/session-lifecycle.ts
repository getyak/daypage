import "server-only";
import { and, eq, inArray, isNull, lt, or } from "drizzle-orm";
import { db } from "@/lib/db/client";
import { agent_sessions, work_orders } from "@/lib/db/schema";

// US-030: agent session lifecycle — heartbeats + timeout reclaim.
//
// An `agent_session` (US-004) is a live connection to an executor backend,
// kept alive by heartbeats. A backend that dies, hangs, or is force-killed
// stops beating but leaves its row `active` (or `idle`) forever, and any
// `work_order` it was running stuck `running`/`gated`. The reaper closes that
// gap: it walks sessions whose heartbeat is older than the timeout window,
// marks them `timed_out`, and fails the in-flight work orders they were
// driving so the queue isn't blocked by a ghost.
//
// `runSessionReaper` takes its DB-facing operations via injected deps so the
// reclaim decision logic is unit testable without a live database.

// How long a session may go without a heartbeat before it is considered dead.
// Generous enough to ride out a slow tick or a transient backend stall.
export const SESSION_TIMEOUT_MINUTES = 15;
const MINUTE_MS = 60 * 1000;

// Session statuses that are still "live" and therefore eligible for timeout
// reclaim. `closed`/`timed_out` sessions are already terminal.
const LIVE_SESSION_STATUSES = ["active", "idle"] as const;

// Work-order statuses that are still in-flight and must be failed when the
// session driving them times out. `done`/`failed` are already terminal.
const INFLIGHT_WORK_ORDER_STATUSES = ["pending", "gated", "running"] as const;

// ── Heartbeat ────────────────────────────────────────────────────────────────

/**
 * Record a fresh heartbeat for a session, bumping `last_heartbeat_at` to now.
 * Idempotent and cheap — a backend calls this periodically while alive. Returns
 * true when a row was updated, false when the session id is unknown (or already
 * torn down). Does not resurrect a `timed_out`/`closed` session.
 */
export async function updateHeartbeat(sessionId: string): Promise<boolean> {
  const updated = await db
    .update(agent_sessions)
    .set({ last_heartbeat_at: new Date() })
    .where(
      and(
        eq(agent_sessions.id, sessionId),
        inArray(agent_sessions.status, [...LIVE_SESSION_STATUSES])
      )
    )
    .returning({ id: agent_sessions.id });

  return updated.length > 0;
}

// ── Reaper ─────────────────────────────────────────────────────────────────

// A live session that has missed its heartbeat window, as seen by the reaper.
export interface StaleSession {
  id: string;
}

// Dependencies the reaper calls out to. Injectable so the reclaim logic can be
// driven with mocks in unit tests.
export interface SessionReaperDeps {
  // Live sessions (`active`/`idle`) whose heartbeat (or, when never beaten,
  // creation time) is older than `cutoff`.
  findStaleSessions: (cutoff: Date) => Promise<StaleSession[]>;
  // Mark a session `timed_out`. Returns the ids actually transitioned.
  markTimedOut: (sessionIds: string[]) => Promise<string[]>;
  // Fail any in-flight work orders associated with the given sessions. Returns
  // how many work orders were failed.
  failInFlightForSessions: (sessionIds: string[]) => Promise<number>;
  // Whether a session has any associated work order at all. Used to single out
  // orphan sessions (no work order) for cleanup.
  hasAssociatedWorkOrder: (sessionId: string) => Promise<boolean>;
  // Tear down an orphan session (no associated work order) by marking `closed`.
  closeOrphan: (sessionId: string) => Promise<void>;
  now: () => number;
}

export interface SessionReaperResult {
  // Sessions found stale this run.
  stale: number;
  // Sessions transitioned to `timed_out`.
  timedOut: number;
  // In-flight work orders failed as a result of the reclaim.
  workOrdersFailed: number;
  // Orphan sessions (no associated work order) closed.
  orphansClosed: number;
}

/**
 * Reclaim dead agent sessions. For each session past the heartbeat window:
 * mark it `timed_out`, then either fail the in-flight work orders it was
 * driving, or — if it has no associated work order at all — close it as an
 * orphan. Pure orchestration over injected deps so it can be unit tested.
 */
export async function runSessionReaper(
  deps: SessionReaperDeps
): Promise<SessionReaperResult> {
  const now = deps.now();
  const cutoff = new Date(now - SESSION_TIMEOUT_MINUTES * MINUTE_MS);

  const stale = await deps.findStaleSessions(cutoff);
  if (stale.length === 0) {
    return { stale: 0, timedOut: 0, workOrdersFailed: 0, orphansClosed: 0 };
  }

  const staleIds = stale.map((s) => s.id);
  const timedOutIds = await deps.markTimedOut(staleIds);

  if (timedOutIds.length === 0) {
    return {
      stale: stale.length,
      timedOut: 0,
      workOrdersFailed: 0,
      orphansClosed: 0,
    };
  }

  // Partition timed-out sessions into those tied to a work order (fail the
  // in-flight work) vs orphans (close them out). Checked per session so a
  // mixed batch is handled correctly.
  const orphanIds: string[] = [];
  for (const id of timedOutIds) {
    const hasWorkOrder = await deps.hasAssociatedWorkOrder(id);
    if (!hasWorkOrder) orphanIds.push(id);
  }

  const workOrdersFailed = await deps.failInFlightForSessions(timedOutIds);

  for (const id of orphanIds) {
    await deps.closeOrphan(id);
  }

  return {
    stale: stale.length,
    timedOut: timedOutIds.length,
    workOrdersFailed,
    orphansClosed: orphanIds.length,
  };
}

// ── Default (live DB) deps ─────────────────────────────────────────────────

// Session → in-flight work order association is implicit in this schema:
// `agent_sessions` has no `work_order_id`, but a session and the work order it
// drives share a `user_id`, and dispatch flips that order to `running`. So a
// timed-out session's in-flight work is "the user's in-flight work orders".
// This is coarse (a user with multiple concurrent sessions over-reclaims), but
// safe — a falsely-failed order is re-dispatchable, a ghost-blocked queue is
// not. A future story can add an explicit FK to tighten this.

async function findStaleSessions(cutoff: Date): Promise<StaleSession[]> {
  return db
    .select({ id: agent_sessions.id })
    .from(agent_sessions)
    .where(
      and(
        inArray(agent_sessions.status, [...LIVE_SESSION_STATUSES]),
        or(
          lt(agent_sessions.last_heartbeat_at, cutoff),
          and(
            isNull(agent_sessions.last_heartbeat_at),
            lt(agent_sessions.created_at, cutoff)
          )
        )
      )
    );
}

async function markTimedOut(sessionIds: string[]): Promise<string[]> {
  if (sessionIds.length === 0) return [];
  const updated = await db
    .update(agent_sessions)
    .set({ status: "timed_out" })
    .where(
      and(
        inArray(agent_sessions.id, sessionIds),
        inArray(agent_sessions.status, [...LIVE_SESSION_STATUSES])
      )
    )
    .returning({ id: agent_sessions.id });
  return updated.map((r) => r.id);
}

// The set of user_ids owning the given (timed-out) sessions. Their in-flight
// work orders are the ones to fail.
async function userIdsForSessions(sessionIds: string[]): Promise<string[]> {
  if (sessionIds.length === 0) return [];
  const rows = await db
    .select({ user_id: agent_sessions.user_id })
    .from(agent_sessions)
    .where(inArray(agent_sessions.id, sessionIds));
  return [...new Set(rows.map((r) => r.user_id))];
}

async function failInFlightForSessions(sessionIds: string[]): Promise<number> {
  const userIds = await userIdsForSessions(sessionIds);
  if (userIds.length === 0) return 0;
  const failed = await db
    .update(work_orders)
    .set({ status: "failed" })
    .where(
      and(
        inArray(work_orders.user_id, userIds),
        inArray(work_orders.status, [...INFLIGHT_WORK_ORDER_STATUSES])
      )
    )
    .returning({ id: work_orders.id });
  return failed.length;
}

async function hasAssociatedWorkOrder(sessionId: string): Promise<boolean> {
  const rows = await db
    .select({ user_id: agent_sessions.user_id })
    .from(agent_sessions)
    .where(eq(agent_sessions.id, sessionId))
    .limit(1);
  const userId = rows[0]?.user_id;
  if (!userId) return false;

  const wo = await db
    .select({ id: work_orders.id })
    .from(work_orders)
    .where(eq(work_orders.user_id, userId))
    .limit(1);
  return wo.length > 0;
}

async function closeOrphan(sessionId: string): Promise<void> {
  await db
    .update(agent_sessions)
    .set({ status: "closed" })
    .where(eq(agent_sessions.id, sessionId));
}

export const defaultSessionReaperDeps: SessionReaperDeps = {
  findStaleSessions,
  markTimedOut,
  failInFlightForSessions,
  hasAssociatedWorkOrder,
  closeOrphan,
  now: () => Date.now(),
};
