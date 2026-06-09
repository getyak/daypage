import { describe, it, expect, vi, beforeEach } from "vitest";

// US-014 tests. Contract of buildWorkOrder:
//  - loads the suggestion, folds in linked tree-node context, classifies the
//    side-effect gate from the intent (suggestion title), and inserts a row.
//  - gate grading: text-generation intent → "auto"; code-mutation intent →
//    "approve-first" (delegated to policy.classifyGate).
//  - a missing suggestion throws; a suggestion with no tree_node_id skips the
//    node join and still builds a valid order.

// ── Mocks ─────────────────────────────────────────────────────────────────────

const mockDb = vi.hoisted(() => ({
  select: vi.fn(),
  insert: vi.fn(),
}));
vi.mock("@/lib/db/client", () => ({ db: mockDb }));

// Use the real schema (table objects) and the real policy.classifyGate so the
// test exercises the actual gate-grading logic, not a stub.
vi.mock("@/lib/db/schema", async (importOriginal) => {
  const real = await importOriginal<typeof import("@/lib/db/schema")>();
  return { ...real };
});

import { buildWorkOrder } from "../work-order";

// ── Builder-chain helpers ──────────────────────────────────────────────────────

// `db.select(...).from(...).where(...).limit(1)` → resolves to `result`.
// Also supports the node query's `.innerJoin(...)` link in the chain.
function selectChain(result: unknown[]) {
  return {
    from: vi.fn().mockReturnThis(),
    innerJoin: vi.fn().mockReturnThis(),
    where: vi.fn().mockReturnThis(),
    limit: vi.fn().mockResolvedValue(result),
  };
}

// `db.insert(...).values(...).returning()` → resolves to `result`.
function insertChain(result: unknown[]) {
  return {
    values: vi.fn().mockReturnThis(),
    returning: vi.fn().mockResolvedValue(result),
  };
}

const NODE_SUGGESTION = {
  id: "sugg-1",
  user_id: "user-1",
  tree_node_id: "node-1",
  title: "summarize today's memos into a wiki page",
  rationale: "5 recent memos cite this goal",
  estimate: "30m",
  suggested_target: "self",
  status: "selected",
  payload: {},
  created_at: new Date("2026-06-10T00:00:00Z"),
};

const NODE_ROW = {
  tree_id: "tree-1",
  tree_title: "Build DayPage Agent OS",
  node_id: "node-1",
  node_title: "Suggester pipeline",
  node_kind: "branch",
};

// Capture what gets inserted so we can assert the persisted shape, and echo it
// back as the returned row (mirrors RETURNING semantics closely enough).
function makeInsert(captured: { values?: Record<string, unknown> }) {
  return {
    values: vi.fn((v: Record<string, unknown>) => {
      captured.values = v;
      return {
        returning: vi
          .fn()
          .mockResolvedValue([{ id: "wo-1", ...v, status: "pending" }]),
      };
    }),
  };
}

describe("buildWorkOrder", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("grades a text-generation intent as auto and persists the order", async () => {
    // 1st select → suggestion; 2nd select → linked node join.
    mockDb.select
      .mockReturnValueOnce(selectChain([NODE_SUGGESTION]))
      .mockReturnValueOnce(selectChain([NODE_ROW]));
    const captured: { values?: Record<string, unknown> } = {};
    mockDb.insert.mockReturnValue(makeInsert(captured));

    const { workOrder, row } = await buildWorkOrder("sugg-1");

    // gate grading: "summarize ..." → auto
    expect(workOrder.gate).toBe("auto");
    expect(workOrder.intent).toBe(NODE_SUGGESTION.title);

    // tree-node context folded in
    expect(workOrder.context.tree_node_id).toBe("node-1");
    expect(workOrder.context.tree_title).toBe("Build DayPage Agent OS");
    expect(workOrder.context.node_title).toBe("Suggester pipeline");
    expect(workOrder.context.rationale).toBe(NODE_SUGGESTION.rationale);
    expect(workOrder.context.estimate).toBe("30m");

    // persisted row carries the same fields
    expect(captured.values).toMatchObject({
      user_id: "user-1",
      suggestion_id: "sugg-1",
      intent: NODE_SUGGESTION.title,
      gate: "auto",
    });
    expect(row.id).toBe("wo-1");
    expect(row.gate).toBe("auto");
  });

  it("grades a code-mutation intent as approve-first", async () => {
    const codeSuggestion = {
      ...NODE_SUGGESTION,
      id: "sugg-2",
      title: "refactor the auth module and commit the fix",
    };
    mockDb.select
      .mockReturnValueOnce(selectChain([codeSuggestion]))
      .mockReturnValueOnce(selectChain([NODE_ROW]));
    const captured: { values?: Record<string, unknown> } = {};
    mockDb.insert.mockReturnValue(makeInsert(captured));

    const { workOrder } = await buildWorkOrder("sugg-2");

    expect(workOrder.gate).toBe("approve-first");
    expect(captured.values).toMatchObject({ gate: "approve-first" });
  });

  it("grades an external-write intent as approve-first", async () => {
    const publishSuggestion = {
      ...NODE_SUGGESTION,
      id: "sugg-3",
      title: "publish the draft and post it to the channel",
    };
    mockDb.select
      .mockReturnValueOnce(selectChain([publishSuggestion]))
      .mockReturnValueOnce(selectChain([NODE_ROW]));
    mockDb.insert.mockReturnValue(
      insertChain([{ id: "wo-3", gate: "approve-first" }])
    );

    const { workOrder } = await buildWorkOrder("sugg-3");

    expect(workOrder.gate).toBe("approve-first");
  });

  it("builds a valid order without tree context when no node is linked", async () => {
    const orphan = {
      ...NODE_SUGGESTION,
      id: "sugg-4",
      tree_node_id: null,
      title: "draft an outline for the week",
    };
    // Only ONE select (the suggestion); no node join when tree_node_id is null.
    mockDb.select.mockReturnValueOnce(selectChain([orphan]));
    const captured: { values?: Record<string, unknown> } = {};
    mockDb.insert.mockReturnValue(makeInsert(captured));

    const { workOrder } = await buildWorkOrder("sugg-4");

    expect(workOrder.gate).toBe("auto"); // "draft an outline" → auto
    expect(workOrder.context.tree_node_id).toBeUndefined();
    expect(workOrder.context.tree_id).toBeUndefined();
    // the node join must not have been attempted
    expect(mockDb.select).toHaveBeenCalledTimes(1);
  });

  it("honors an explicit callback and budget override", async () => {
    mockDb.select
      .mockReturnValueOnce(selectChain([NODE_SUGGESTION]))
      .mockReturnValueOnce(selectChain([NODE_ROW]));
    const captured: { values?: Record<string, unknown> } = {};
    mockDb.insert.mockReturnValue(makeInsert(captured));

    const { workOrder } = await buildWorkOrder("sugg-1", {
      callback: { kind: "telegram", chat_id: "12345" },
      budgetTokens: 50_000,
    });

    expect(workOrder.callback).toEqual({ kind: "telegram", chat_id: "12345" });
    expect(workOrder.budget_tokens).toBe(50_000);
    expect(captured.values).toMatchObject({ budget_tokens: 50_000 });
  });

  it("throws when the suggestion does not exist", async () => {
    mockDb.select.mockReturnValueOnce(selectChain([]));
    await expect(buildWorkOrder("missing")).rejects.toThrow(/not found/);
    expect(mockDb.insert).not.toHaveBeenCalled();
  });
});
