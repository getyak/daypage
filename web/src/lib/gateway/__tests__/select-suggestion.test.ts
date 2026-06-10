import { describe, it, expect, vi, beforeEach } from "vitest";

// US-013 tests. Contract of selectSuggestion:
//  - first tap on an `open` suggestion → flip to `selected` + enqueue a
//    `dispatch` job keyed `dispatch:<id>`, return { status: "selected" }.
//  - any later tap (already selected/dispatched) → UPDATE matches no row, we
//    read the row back and return { status: "already" } WITHOUT enqueuing again.
//  - unknown id → { status: "not_found" }, no enqueue.

// ── Mocks ─────────────────────────────────────────────────────────────────────

const mockDb = vi.hoisted(() => ({
  update: vi.fn(),
  select: vi.fn(),
}));
vi.mock("@/lib/db/client", () => ({ db: mockDb }));

vi.mock("@/lib/db/schema", async (importOriginal) => {
  const real = await importOriginal<typeof import("@/lib/db/schema")>();
  return { ...real };
});

const enqueueJob = vi.hoisted(() => vi.fn());
vi.mock("@/lib/gateway/jobs", () => ({ enqueueJob }));

import { selectSuggestion } from "../select-suggestion";

// ── Builder-chain helpers ──────────────────────────────────────────────────────

// `db.update(...).set(...).where(...).returning()` → returns `result`.
function updateChain(result: unknown[]) {
  return {
    set: vi.fn().mockReturnThis(),
    where: vi.fn().mockReturnThis(),
    returning: vi.fn().mockResolvedValue(result),
  };
}

// `db.select().from(...).where(...).limit(1)` → resolves to `result`.
function selectChain(result: unknown[]) {
  return {
    from: vi.fn().mockReturnThis(),
    where: vi.fn().mockReturnThis(),
    limit: vi.fn().mockResolvedValue(result),
  };
}

const OPEN_ROW = {
  id: "sugg-1",
  user_id: "user-1",
  status: "selected", // returning() reflects the post-update value
  title: "Draft the wiki concept page",
  rationale: "3 memos cite it",
};

const ALREADY_ROW = {
  id: "sugg-1",
  user_id: "user-1",
  status: "dispatched",
  title: "Draft the wiki concept page",
  rationale: "3 memos cite it",
};

beforeEach(() => {
  vi.clearAllMocks();
});

describe("selectSuggestion", () => {
  it("flips an open suggestion to selected and enqueues a dispatch job", async () => {
    // UPDATE ... WHERE status='open' matches the row and returns it.
    mockDb.update.mockReturnValue(updateChain([OPEN_ROW]));
    enqueueJob.mockResolvedValue({ id: "job-1" });

    const result = await selectSuggestion("sugg-1");

    expect(result.status).toBe("selected");
    if (result.status === "selected") {
      expect(result.suggestion.id).toBe("sugg-1");
    }

    // The dispatch job is enqueued exactly once with the idempotency contract.
    expect(enqueueJob).toHaveBeenCalledTimes(1);
    expect(enqueueJob).toHaveBeenCalledWith({
      userId: "user-1",
      type: "dispatch",
      payload: { suggestion_id: "sugg-1" },
      idempotencyKey: "dispatch:sugg-1",
    });

    // Happy path never touches the read-back select.
    expect(mockDb.select).not.toHaveBeenCalled();
  });

  it("is idempotent on a repeated tap: no second UPDATE match, no re-enqueue", async () => {
    // UPDATE matches no row (status no longer 'open'); read-back finds it.
    mockDb.update.mockReturnValue(updateChain([]));
    mockDb.select.mockReturnValue(selectChain([ALREADY_ROW]));

    const result = await selectSuggestion("sugg-1");

    expect(result.status).toBe("already");
    if (result.status === "already") {
      expect(result.suggestion.status).toBe("dispatched");
    }

    // Critical: a duplicate tap must NOT enqueue a second dispatch job.
    expect(enqueueJob).not.toHaveBeenCalled();
  });

  it("returns not_found for an unknown suggestion id", async () => {
    mockDb.update.mockReturnValue(updateChain([]));
    mockDb.select.mockReturnValue(selectChain([]));

    const result = await selectSuggestion("does-not-exist");

    expect(result.status).toBe("not_found");
    expect(enqueueJob).not.toHaveBeenCalled();
  });
});
