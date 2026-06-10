import { describe, it, expect, vi, beforeEach } from "vitest";

// ── Mocks ─────────────────────────────────────────────────────────────────────

// `vi.hoisted` keeps mockDb initialized before the hoisted vi.mock factory and
// the static import of "../jobs" below eagerly evaluate it.
const mockDb = vi.hoisted(() => ({
  insert: vi.fn(),
  select: vi.fn(),
  update: vi.fn(),
  transaction: vi.fn(),
}));
vi.mock("@/lib/db/client", () => ({ db: mockDb }));

vi.mock("@/lib/db/schema", async (importOriginal) => {
  const real = await importOriginal<typeof import("@/lib/db/schema")>();
  return { ...real };
});

import {
  enqueueJob,
  claimJob,
  completeJob,
  failJob,
  alertDeadJob,
  nextStatusAfterFailure,
  MAX_ATTEMPTS,
} from "../jobs";

// ── Builder-chain helpers ──────────────────────────────────────────────────────
// Each drizzle query is a thenable builder; these stub just the methods our
// helpers actually call, resolving the chain to `result`.

function insertChain(result: unknown[]) {
  return {
    values: vi.fn().mockReturnThis(),
    onConflictDoNothing: vi.fn().mockReturnThis(),
    returning: vi.fn().mockResolvedValue(result),
  };
}

// A select builder used by two call shapes:
//  - enqueue read-back:  .from().where().limit(1)        → awaited
//  - claim lock:         .from().where().orderBy().limit().for(...) → awaited
function selectChain(result: unknown[]) {
  const forFn = vi.fn().mockResolvedValue(result);
  const chain: Record<string, unknown> = {
    from: vi.fn().mockReturnThis(),
    where: vi.fn().mockReturnThis(),
    orderBy: vi.fn().mockReturnThis(),
    for: forFn,
  };
  // `.limit()` must be both awaitable (enqueue path ends here) and chainable to
  // `.for()` (claim path continues). Return a promise carrying a `.for` method.
  chain.limit = vi.fn(() => {
    const p = Promise.resolve(result) as Promise<unknown[]> & {
      for: typeof forFn;
    };
    p.for = forFn;
    return p;
  });
  return chain;
}

function updateChain(result: unknown[]) {
  return {
    set: vi.fn().mockReturnThis(),
    where: vi.fn().mockReturnThis(),
    returning: vi.fn().mockResolvedValue(result),
  };
}

const baseJob = {
  id: "job-1",
  user_id: "user-1",
  type: "compile",
  tree_id: null,
  payload: {},
  status: "queued",
  idempotency_key: "compile:memo-1",
  gate_state: null,
  attempts: 0,
  last_error: null,
  created_at: new Date("2026-06-09T00:00:00Z"),
  updated_at: new Date("2026-06-09T00:00:00Z"),
};

beforeEach(() => {
  vi.clearAllMocks();
});

// ── enqueueJob: idempotent dedupe ───────────────────────────────────────────────

describe("enqueueJob", () => {
  it("returns the freshly inserted job on the happy path", async () => {
    mockDb.insert.mockReturnValue(insertChain([baseJob]));

    const job = await enqueueJob({
      userId: "user-1",
      type: "compile",
      idempotencyKey: "compile:memo-1",
    });

    expect(job.id).toBe("job-1");
    // No read-back needed when the insert returned a row.
    expect(mockDb.select).not.toHaveBeenCalled();
  });

  it("no-ops on idempotency_key conflict and returns the existing job", async () => {
    // Insert hits the unique conflict → onConflictDoNothing returns [].
    mockDb.insert.mockReturnValue(insertChain([]));
    // Read-back finds the pre-existing row.
    const existing = { ...baseJob, id: "existing-1" };
    mockDb.select.mockReturnValue(selectChain([existing]));

    const job = await enqueueJob({
      userId: "user-1",
      type: "compile",
      idempotencyKey: "compile:memo-1",
    });

    expect(job.id).toBe("existing-1");
    expect(mockDb.select).toHaveBeenCalledOnce();
  });

  it("throws if a conflict yields no existing row (unreachable invariant)", async () => {
    mockDb.insert.mockReturnValue(insertChain([]));
    mockDb.select.mockReturnValue(selectChain([]));

    await expect(
      enqueueJob({
        userId: "user-1",
        type: "compile",
        idempotencyKey: "compile:memo-1",
      })
    ).rejects.toThrow(/no existing row/);
  });

  // US-029: re-enqueuing the same logical job must not create a second
  // executable row. The first enqueue inserts; the second hits the unique
  // idempotency_key conflict (onConflictDoNothing → []) and reads back the SAME
  // job. Both calls resolve to one job id → exactly one execution downstream.
  it("dedupes a repeated enqueue to a single job (no duplicate execution)", async () => {
    const input = {
      userId: "user-1",
      type: "dispatch",
      idempotencyKey: "dispatch:sug-1",
    };

    // First enqueue: clean insert returns the canonical row.
    const created = { ...baseJob, id: "job-A", idempotency_key: input.idempotencyKey };
    mockDb.insert.mockReturnValueOnce(insertChain([created]));
    const first = await enqueueJob(input);

    // Second enqueue: insert conflicts (returns []), read-back yields the same row.
    mockDb.insert.mockReturnValueOnce(insertChain([]));
    mockDb.select.mockReturnValueOnce(selectChain([created]));
    const second = await enqueueJob(input);

    // Same job both times: nothing new to execute on the repeat.
    expect(first.id).toBe("job-A");
    expect(second.id).toBe("job-A");
    expect(second.id).toBe(first.id);
    // The repeat never produced a fresh row — the only row read back is the
    // pre-existing one (insert returned [] on the conflict).
    expect(mockDb.select).toHaveBeenCalledOnce();
  });
});

// ── claimJob: atomic FOR UPDATE SKIP LOCKED ─────────────────────────────────────

describe("claimJob", () => {
  // Run the transaction callback against a stubbed `tx` and capture its result.
  function runTransaction(opts: { locked: unknown[]; claimed: unknown[] }) {
    mockDb.transaction.mockImplementation(
      async (fn: (tx: unknown) => unknown) => {
        const tx = {
          select: vi.fn().mockReturnValue(selectChain(opts.locked)),
          update: vi.fn().mockReturnValue(updateChain(opts.claimed)),
        };
        return fn(tx);
      }
    );
  }

  it("returns null when the queue is empty", async () => {
    runTransaction({ locked: [], claimed: [] });
    const job = await claimJob();
    expect(job).toBeNull();
  });

  it("claims the locked job and returns it flipped to running", async () => {
    const running = { ...baseJob, status: "running", attempts: 1 };
    runTransaction({ locked: [{ id: "job-1" }], claimed: [running] });

    const job = await claimJob();
    expect(job).not.toBeNull();
    expect(job?.status).toBe("running");
    expect(job?.attempts).toBe(1);
  });
});

// ── completeJob ─────────────────────────────────────────────────────────────────

describe("completeJob", () => {
  it("transitions the job to done and clears the error", async () => {
    const done = { ...baseJob, status: "done", last_error: null };
    mockDb.update.mockReturnValue(updateChain([done]));

    const job = await completeJob("job-1");
    expect(job?.status).toBe("done");
  });

  it("returns null when no row matches the id", async () => {
    mockDb.update.mockReturnValue(updateChain([]));
    const job = await completeJob("missing");
    expect(job).toBeNull();
  });
});

// ── failJob: retry → dead transition ────────────────────────────────────────────

describe("failJob", () => {
  it("requeues a job that still has retries left", async () => {
    // attempts=1 (< MAX) → DB resolves it back to queued.
    const requeued = {
      ...baseJob,
      status: "queued",
      attempts: 1,
      last_error: "boom",
    };
    mockDb.update.mockReturnValue(updateChain([requeued]));

    const job = await failJob("job-1", "boom");
    expect(job?.status).toBe("queued");
    expect(job?.last_error).toBe("boom");
  });

  it("parks a job as dead once attempts reach maxAttempts", async () => {
    // attempts=3 (>= MAX) → DB resolves it to dead.
    const dead = {
      ...baseJob,
      status: "dead",
      attempts: 3,
      last_error: "fatal",
    };
    mockDb.update.mockReturnValue(updateChain([dead]));
    // Dead transition fires a single api_logs alert (US-029).
    mockDb.insert.mockReturnValue(insertChain([{ id: "log-1" }]));

    const job = await failJob("job-1", "fatal");
    expect(job?.status).toBe("dead");
    expect(job?.last_error).toBe("fatal");
  });

  // ── US-029: dead-letter alert fires exactly once ────────────────────────────

  it("writes one api_logs alert on the queued→dead transition", async () => {
    const dead = { ...baseJob, status: "dead", attempts: 3, last_error: "fatal" };
    mockDb.update.mockReturnValue(updateChain([dead]));
    mockDb.insert.mockReturnValue(insertChain([{ id: "log-1" }]));

    await failJob("job-1", "fatal");

    expect(mockDb.insert).toHaveBeenCalledOnce();
  });

  it("does NOT alert when the job is requeued (still has retries)", async () => {
    const requeued = { ...baseJob, status: "queued", attempts: 1, last_error: "boom" };
    mockDb.update.mockReturnValue(updateChain([requeued]));

    await failJob("job-1", "boom");

    expect(mockDb.insert).not.toHaveBeenCalled();
  });

  it("does not throw if the alert write fails (best-effort)", async () => {
    const dead = { ...baseJob, status: "dead", attempts: 3, last_error: "fatal" };
    mockDb.update.mockReturnValue(updateChain([dead]));
    mockDb.insert.mockReturnValue({
      values: vi.fn().mockRejectedValue(new Error("log sink down")),
    });

    // The original failure must surface as a normal return, not be masked by an
    // alerting error.
    const job = await failJob("job-1", "fatal");
    expect(job?.status).toBe("dead");
  });
});

// ── alertDeadJob: durable sink shape ────────────────────────────────────────────

describe("alertDeadJob", () => {
  it("inserts a 500 JOB pseudo-request into api_logs", async () => {
    const valuesSpy = vi.fn().mockResolvedValue([{ id: "log-1" }]);
    mockDb.insert.mockReturnValue({ values: valuesSpy });

    await alertDeadJob({ ...baseJob, status: "dead", attempts: 3, last_error: "fatal" });

    expect(valuesSpy).toHaveBeenCalledOnce();
    const row = valuesSpy.mock.calls[0][0];
    expect(row.method).toBe("JOB");
    expect(row.status).toBe(500);
    expect(row.path).toContain(baseJob.type);
    expect(row.user_id).toBe(baseJob.user_id);
    expect(row.error).toContain("fatal");
  });
});

// ── nextStatusAfterFailure: dead boundary (pure, SQL-mirroring) ──────────────────

describe("nextStatusAfterFailure", () => {
  it("requeues below the retry ceiling", () => {
    expect(nextStatusAfterFailure(0)).toBe("queued");
    expect(nextStatusAfterFailure(1)).toBe("queued");
    expect(nextStatusAfterFailure(MAX_ATTEMPTS - 1)).toBe("queued");
  });

  it("goes dead at or beyond the retry ceiling", () => {
    expect(nextStatusAfterFailure(MAX_ATTEMPTS)).toBe("dead");
    expect(nextStatusAfterFailure(MAX_ATTEMPTS + 1)).toBe("dead");
  });

  it("uses 3 as the retry ceiling", () => {
    expect(MAX_ATTEMPTS).toBe(3);
  });
});
