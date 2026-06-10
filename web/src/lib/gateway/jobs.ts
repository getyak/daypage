import "server-only";
import { db } from "@/lib/db/client";
import { api_logs, gateway_jobs, type GatewayJob } from "@/lib/db/schema";
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
// retry ceiling, otherwise back to `queued` for another pass. The SQL `case`
// mirrors `nextStatusAfterFailure` so the boundary lives in one place.
//
// US-029: when this failure is the one that parks the job `dead` (retries
// exhausted), fire exactly one alert. The transition is observed from the
// returned row's status, so the alert fires once — on the queued→dead edge —
// and never on the intermediate requeues.
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

  const job = rows[0] ?? null;
  if (job && job.status === "dead") {
    await alertDeadJob(job);
  }
  return job;
}

// US-029: emit a single dead-letter alert. Writes an `api_logs` row (the
// project's durable error sink — synthesized as a pseudo-request since a dead
// job has no HTTP shape) and forwards to Sentry when wired. Best-effort: an
// alerting failure must never mask or re-throw over the original job failure,
// so both sinks swallow their own errors.
export async function alertDeadJob(job: GatewayJob): Promise<void> {
  // Durable sink: api_logs. Shape a dead job as a 500 "JOB" request so it shows
  // up alongside request errors in the same log.
  try {
    await db.insert(api_logs).values({
      method: "JOB",
      path: `gateway/dead/${job.type}`,
      status: 500,
      duration_ms: 0,
      user_id: job.user_id,
      error:
        `gateway_job ${job.id} dead after ${job.attempts} attempts` +
        (job.last_error ? `: ${job.last_error}` : ""),
    });
  } catch (err) {
    console.error(`[gateway] failed to write dead-job api_log for ${job.id}`, err);
  }

  // Optional sink: Sentry, when the SDK is present at runtime. Loaded lazily so
  // the dependency stays optional and absent in dev/test without breaking.
  try {
    const sentry = (
      globalThis as { Sentry?: { captureMessage?: (m: string) => void } }
    ).Sentry;
    sentry?.captureMessage?.(
      `gateway_job dead: ${job.type} (${job.id}) after ${job.attempts} attempts`
    );
  } catch (err) {
    console.error(`[gateway] failed to send dead-job Sentry alert for ${job.id}`, err);
  }
}

// Convenience: jobs currently parked as dead for a user (for ops/inspection).
export async function deadJobs(userId: string): Promise<GatewayJob[]> {
  return db
    .select()
    .from(gateway_jobs)
    .where(and(eq(gateway_jobs.user_id, userId), eq(gateway_jobs.status, "dead")))
    .orderBy(asc(gateway_jobs.created_at));
}
