import "server-only";
import { db } from "@/lib/db/client";
import { gateway_jobs, type GatewayJob } from "@/lib/db/schema";
import { and, asc, eq, sql } from "drizzle-orm";

// US-007: gateway_jobs enqueue/dequeue helpers — the durable work queue the
// Gateway orchestrator pulls from. Enqueue is idempotent (re-enqueuing the same
// logical job is a no-op); claim is atomic across concurrent workers via
// `SELECT ... FOR UPDATE SKIP LOCKED`; complete/fail drive the retry → dead
// lifecycle.

// Retry budget: a job that fails this many times is parked as `dead` rather than
// re-queued, so a persistently-broken job can't spin forever.
export const MAX_ATTEMPTS = 3;

// Resting state for a job after a failure, given its (already-incremented)
// attempt count. Single source of truth for the retry → dead boundary; the SQL
// in `failJob` mirrors this exact comparison so the DB and this helper agree.
export function nextStatusAfterFailure(
  attempts: number
): "queued" | "dead" {
  return attempts >= MAX_ATTEMPTS ? "dead" : "queued";
}

export interface EnqueueJobInput {
  userId: string;
  type: string;
  treeId?: string | null;
  payload?: Record<string, unknown>;
  idempotencyKey: string;
}

// Insert a queued job, deduped on `idempotency_key`. On conflict the insert is a
// no-op and we read back the existing row, so callers always get the canonical
// job for their key whether or not they were the one to create it.
export async function enqueueJob(input: EnqueueJobInput): Promise<GatewayJob> {
  const inserted = await db
    .insert(gateway_jobs)
    .values({
      user_id: input.userId,
      type: input.type,
      tree_id: input.treeId ?? null,
      payload: input.payload ?? {},
      idempotency_key: input.idempotencyKey,
    })
    .onConflictDoNothing({ target: gateway_jobs.idempotency_key })
    .returning();

  if (inserted[0]) return inserted[0];

  // Conflict: another enqueue already owns this idempotency key. Return it.
  const existing = await db
    .select()
    .from(gateway_jobs)
    .where(eq(gateway_jobs.idempotency_key, input.idempotencyKey))
    .limit(1);

  const job = existing[0];
  if (!job) {
    // Should be unreachable: conflict implies a row exists. Treat as a real
    // error rather than silently returning undefined.
    throw new Error(
      `enqueueJob: conflict on idempotency_key "${input.idempotencyKey}" but no existing row found`
    );
  }
  return job;
}

// Atomically claim the oldest queued job and flip it to `running`. Uses
// `FOR UPDATE SKIP LOCKED` inside a transaction so concurrent workers never grab
// the same job and never block on each other's locks. Returns null when the
// queue is empty.
export async function claimJob(): Promise<GatewayJob | null> {
  return db.transaction(async (tx) => {
    const locked = await tx
      .select({ id: gateway_jobs.id })
      .from(gateway_jobs)
      .where(eq(gateway_jobs.status, "queued"))
      .orderBy(asc(gateway_jobs.created_at))
      .limit(1)
      .for("update", { skipLocked: true });

    const target = locked[0];
    if (!target) return null;

    const claimed = await tx
      .update(gateway_jobs)
      .set({ status: "running", attempts: sql`${gateway_jobs.attempts} + 1` })
      .where(eq(gateway_jobs.id, target.id))
      .returning();

    return claimed[0] ?? null;
  });
}

// Mark a running job done. No-op-safe: only transitions a row that exists.
export async function completeJob(id: string): Promise<GatewayJob | null> {
  const rows = await db
    .update(gateway_jobs)
    .set({ status: "done", last_error: null })
    .where(eq(gateway_jobs.id, id))
    .returning();
  return rows[0] ?? null;
}

// Record a failure. The attempt count was already incremented at claim time, so
// here we only decide the resting state: `dead` once attempts have reached the
// retry ceiling, otherwise back to `queued` for another pass.
export async function failJob(
  id: string,
  error: string
): Promise<GatewayJob | null> {
  const rows = await db
    .update(gateway_jobs)
    .set({
      status: sql`case when ${gateway_jobs.attempts} >= ${MAX_ATTEMPTS} then 'dead'::gateway_job_status else 'queued'::gateway_job_status end`,
      last_error: error,
    })
    .where(eq(gateway_jobs.id, id))
    .returning();
  return rows[0] ?? null;
}

// Convenience: jobs currently parked as dead for a user (for ops/inspection).
export async function deadJobs(userId: string): Promise<GatewayJob[]> {
  return db
    .select()
    .from(gateway_jobs)
    .where(and(eq(gateway_jobs.user_id, userId), eq(gateway_jobs.status, "dead")))
    .orderBy(asc(gateway_jobs.created_at));
}
