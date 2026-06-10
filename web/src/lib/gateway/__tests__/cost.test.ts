import { describe, it, expect, vi, beforeEach } from "vitest";

// ── Mocks ─────────────────────────────────────────────────────────────────────

// cost.ts reads prompt_log / change_log / work_orders / user_settings via the
// drizzle `db` builder at call time. Stub `db.select` with a thenable chain so
// each aggregate read resolves to a scripted row set without a real database.
const mockDb = vi.hoisted(() => ({ select: vi.fn() }));
vi.mock("@/lib/db/client", () => ({ db: mockDb }));

vi.mock("@/lib/db/schema", async (importOriginal) => {
  const real = await importOriginal<typeof import("@/lib/db/schema")>();
  return { ...real };
});

import {
  agentCostSummary,
  treeSpentTokens,
  readPerTreeBudgetTokens,
} from "../cost";
import { DEFAULT_PER_TREE_BUDGET_TOKENS } from "@/lib/settings/evolution";

// A thenable select chain resolving to `result`, supporting the builder methods
// the cost queries use (from/where/limit/groupBy). `where` resolves but also
// exposes `limit` and `groupBy` for the per-backend aggregate.
function selectChain(result: unknown[]) {
  const p = Promise.resolve(result);
  return Object.assign(p, {
    from: vi.fn().mockReturnThis(),
    where: vi.fn().mockReturnValue(
      Object.assign(Promise.resolve(result), {
        limit: vi.fn().mockResolvedValue(result),
        groupBy: vi.fn().mockResolvedValue(result),
      })
    ),
  });
}

beforeEach(() => {
  vi.clearAllMocks();
});

// ── agentCostSummary ────────────────────────────────────────────────────────────

describe("agentCostSummary", () => {
  it("aggregates prompt_log token spend and change_log dispatch count", async () => {
    // Three SELECTs run via Promise.all: prompt_log (tokens), change_log (count),
    // then agent_sessions grouped by backend.
    mockDb.select
      .mockReturnValueOnce(selectChain([{ spent: 12_345 }]))
      .mockReturnValueOnce(selectChain([{ count: 7 }]))
      .mockReturnValueOnce(selectChain([]));

    const summary = await agentCostSummary({ userId: "user-1" });

    expect(summary.userId).toBe("user-1");
    expect(summary.tokensSpent).toBe(12_345);
    expect(summary.dispatchCount).toBe(7);
    expect(summary.byBackend).toEqual([]);
    expect(summary.since).toBeNull();
    expect(mockDb.select).toHaveBeenCalledTimes(3);
  });

  it("echoes the since window when provided", async () => {
    const since = new Date("2026-06-01T00:00:00Z");
    mockDb.select
      .mockReturnValueOnce(selectChain([{ spent: 100 }]))
      .mockReturnValueOnce(selectChain([{ count: 1 }]))
      .mockReturnValueOnce(selectChain([]));

    const summary = await agentCostSummary({ userId: "user-1", since });
    expect(summary.since).toEqual(since);
  });

  it("coerces string aggregates (postgres bigint) to numbers", async () => {
    mockDb.select
      .mockReturnValueOnce(selectChain([{ spent: "999" }]))
      .mockReturnValueOnce(selectChain([{ count: "3" }]))
      .mockReturnValueOnce(selectChain([]));

    const summary = await agentCostSummary({ userId: "user-1" });
    expect(summary.tokensSpent).toBe(999);
    expect(summary.dispatchCount).toBe(3);
    expect(typeof summary.tokensSpent).toBe("number");
  });

  it("treats empty result rows as zero", async () => {
    mockDb.select
      .mockReturnValueOnce(selectChain([]))
      .mockReturnValueOnce(selectChain([]))
      .mockReturnValueOnce(selectChain([]));

    const summary = await agentCostSummary({ userId: "user-1" });
    expect(summary.tokensSpent).toBe(0);
    expect(summary.dispatchCount).toBe(0);
    expect(summary.byBackend).toEqual([]);
  });

  it("splits dispatches + tokens by backend, highest cost first", async () => {
    mockDb.select
      .mockReturnValueOnce(selectChain([{ spent: 0 }]))
      .mockReturnValueOnce(selectChain([{ count: 0 }]))
      .mockReturnValueOnce(
        selectChain([
          { backend: "sandbox", count: 4, spent: 1_000 },
          { backend: "claude-code", count: 2, spent: 9_000 },
        ])
      );

    const summary = await agentCostSummary({ userId: "user-1" });
    // Sorted by tokensSpent desc → claude-code first.
    expect(summary.byBackend).toEqual([
      { backend: "claude-code", dispatchCount: 2, tokensSpent: 9_000 },
      { backend: "sandbox", dispatchCount: 4, tokensSpent: 1_000 },
    ]);
  });

  it("coerces per-backend bigint aggregates to numbers", async () => {
    mockDb.select
      .mockReturnValueOnce(selectChain([{ spent: 0 }]))
      .mockReturnValueOnce(selectChain([{ count: 0 }]))
      .mockReturnValueOnce(
        selectChain([{ backend: "ralph", count: "3", spent: "500" }])
      );

    const summary = await agentCostSummary({ userId: "user-1" });
    expect(summary.byBackend[0]).toEqual({
      backend: "ralph",
      dispatchCount: 3,
      tokensSpent: 500,
    });
    expect(typeof summary.byBackend[0].tokensSpent).toBe("number");
  });
});

// ── treeSpentTokens ─────────────────────────────────────────────────────────────

describe("treeSpentTokens", () => {
  it("sums the committed budget of the tree's non-pending work orders", async () => {
    mockDb.select.mockReturnValue(selectChain([{ spent: 8000 }]));
    const spent = await treeSpentTokens("user-1", "tree-1");
    expect(spent).toBe(8000);
  });

  it("returns zero when the tree has no dispatched orders", async () => {
    mockDb.select.mockReturnValue(selectChain([{ spent: 0 }]));
    const spent = await treeSpentTokens("user-1", "tree-1");
    expect(spent).toBe(0);
  });
});

// ── readPerTreeBudgetTokens ──────────────────────────────────────────────────────

describe("readPerTreeBudgetTokens", () => {
  it("reads the per-tree ceiling from the user's evolution config", async () => {
    mockDb.select.mockReturnValue(
      selectChain([{ settings: { evolution: { perTreeBudgetTokens: 9000 } } }])
    );
    const budget = await readPerTreeBudgetTokens("user-1");
    expect(budget).toBe(9000);
  });

  it("falls back to the schema default when no settings row exists", async () => {
    mockDb.select.mockReturnValue(selectChain([]));
    const budget = await readPerTreeBudgetTokens("user-1");
    expect(budget).toBe(DEFAULT_PER_TREE_BUDGET_TOKENS);
  });
});
