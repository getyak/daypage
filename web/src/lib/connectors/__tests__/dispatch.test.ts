import { describe, it, expect, vi, beforeEach } from "vitest";
import type { WorkOrder as WorkOrderRow } from "@/lib/db/schema";

// US-015 tests. Contract of dispatch(workOrder):
//  - writes a task file (YAML front-matter + Markdown prompt) under the drop dir
//    and registers an `agent_sessions` row (external_ref = task path),
//  - records a `change_log` entry (action_kind='dispatch_workorder',
//    performed_by='agent', before/after),
//  - on failure marks work_orders.status='failed' and returns the error rather
//    than throwing.
//
// fs is mocked so we assert the write without touching disk; db is mocked so we
// assert the session registration / change-log / failure-flip side effects.

// ── Mocks ─────────────────────────────────────────────────────────────────────

const mockFs = vi.hoisted(() => ({
  mkdir: vi.fn().mockResolvedValue(undefined),
  writeFile: vi.fn().mockResolvedValue(undefined),
  readdir: vi.fn(),
  stat: vi.fn(),
  readFile: vi.fn(),
}));
vi.mock("node:fs", () => ({ promises: mockFs }));

const mockDb = vi.hoisted(() => ({
  insert: vi.fn(),
  update: vi.fn(),
}));
vi.mock("@/lib/db/client", () => ({ db: mockDb }));

vi.mock("@/lib/db/schema", async (importOriginal) => {
  const real = await importOriginal<typeof import("@/lib/db/schema")>();
  return { ...real };
});

import { dispatch } from "../claude-code";

// ── Builder-chain helpers ──────────────────────────────────────────────────────

// `db.insert(agent_sessions).values(...).returning({...})` → resolves to result.
function insertReturningChain(result: unknown[]) {
  return {
    values: vi.fn().mockReturnThis(),
    returning: vi.fn().mockResolvedValue(result),
  };
}

// `db.insert(change_log).values(...)` → captures the inserted values.
function insertCaptureChain(captured: { values?: Record<string, unknown> }) {
  return {
    values: vi.fn((v: Record<string, unknown>) => {
      captured.values = v;
      return undefined;
    }),
  };
}

// `db.update(work_orders).set(...).where(...)` → captures the set payload.
function updateCaptureChain(captured: { set?: Record<string, unknown> }) {
  return {
    set: vi.fn((v: Record<string, unknown>) => {
      captured.set = v;
      return { where: vi.fn().mockResolvedValue(undefined) };
    }),
  };
}

const ORDER: WorkOrderRow = {
  id: "wo-1",
  user_id: "user-1",
  suggestion_id: "sugg-1",
  intent: "summarize today's memos into a wiki page",
  context: {
    rationale: "5 recent memos cite this goal",
    tree_title: "Build DayPage Agent OS",
    node_title: "Suggester pipeline",
  },
  output_spec: null,
  gate: "auto",
  callback: null,
  budget_tokens: 100_000,
  status: "pending",
  result_ref: null,
  created_at: new Date("2026-06-10T00:00:00.000Z"),
};

const NOW = new Date("2026-06-10T01:00:00.000Z");

describe("dispatch", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockFs.mkdir.mockResolvedValue(undefined);
    mockFs.writeFile.mockResolvedValue(undefined);
  });

  it("writes a task file and registers an agent session", async () => {
    const changeLogCaptured: { values?: Record<string, unknown> } = {};
    mockDb.insert
      .mockReturnValueOnce(insertReturningChain([{ id: "sess-1" }])) // agent_sessions
      .mockReturnValueOnce(insertCaptureChain(changeLogCaptured)); // change_log
    mockDb.update.mockReturnValue(updateCaptureChain({}));

    const result = await dispatch(ORDER, { dir: "/tmp/drop", now: NOW });

    expect(result.status).toBe("active");
    expect(result.sessionId).toBe("sess-1");
    expect(result.externalRef).toBe("/tmp/drop/wo-1.md");

    // task file written under the drop dir
    expect(mockFs.mkdir).toHaveBeenCalledWith("/tmp/drop", {
      recursive: true,
    });
    expect(mockFs.writeFile).toHaveBeenCalledTimes(1);
    const [writtenPath, contents] = mockFs.writeFile.mock.calls[0];
    expect(writtenPath).toBe("/tmp/drop/wo-1.md");
    expect(contents).toContain("work_order_id: wo-1");
    expect(contents).toContain("gate: auto");
    expect(contents).toContain("dispatched_at: 2026-06-10T01:00:00.000Z");
    expect(contents).toContain("# summarize today's memos into a wiki page");
    expect(contents).toContain("5 recent memos cite this goal");

    // session registered with external_ref = task path
    const sessionInsert = mockDb.insert.mock.results[0].value;
    expect(sessionInsert.values).toHaveBeenCalledWith(
      expect.objectContaining({
        user_id: "user-1",
        backend: "claude-code",
        external_ref: "/tmp/drop/wo-1.md",
        status: "active",
      })
    );
  });

  it("records a change_log entry with action_kind=dispatch_workorder", async () => {
    const changeLogCaptured: { values?: Record<string, unknown> } = {};
    mockDb.insert
      .mockReturnValueOnce(insertReturningChain([{ id: "sess-1" }]))
      .mockReturnValueOnce(insertCaptureChain(changeLogCaptured));
    mockDb.update.mockReturnValue(updateCaptureChain({}));

    await dispatch(ORDER, { dir: "/tmp/drop", now: NOW });

    expect(changeLogCaptured.values).toMatchObject({
      user_id: "user-1",
      action_kind: "dispatch_workorder",
      target_type: "work_order",
      target_id: "wo-1",
      performed_by: "agent",
      before: { status: "pending" },
    });
    const after = changeLogCaptured.values?.after as Record<string, unknown>;
    expect(after.session_id).toBe("sess-1");
    expect(after.external_ref).toBe("/tmp/drop/wo-1.md");
  });

  it("flips the order to failed and returns the error without throwing", async () => {
    mockFs.writeFile.mockRejectedValueOnce(new Error("disk full"));
    const updateCaptured: { set?: Record<string, unknown> } = {};
    mockDb.update.mockReturnValue(updateCaptureChain(updateCaptured));

    const result = await dispatch(ORDER, { dir: "/tmp/drop", now: NOW });

    expect(result.status).toBe("failed");
    expect(result.sessionId).toBeNull();
    expect(result.error).toContain("disk full");

    // work order flipped to failed; no session registered
    expect(updateCaptured.set).toEqual({ status: "failed" });
    expect(mockDb.insert).not.toHaveBeenCalled();
  });
});
