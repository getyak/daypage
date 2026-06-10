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
// the cost queries use (from/where/limit). `where` and `limit` both resolve.
function selectChain(result: unknown[]) {
  const p = Promise.resolve(result);
  return Object.assign(p, {
    from: vi.fn().mockReturnThis(),
    where: vi.fn().mockReturnValue(
      Object.assign(Promise.resolve(result), {
        limit: vi.fn().mockResolvedValue(result),
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
    // Two SELECTs run via Promise.all: first prompt_log (tokens), then change_log (count).
    mockDb.select
      .mockReturnValueOnce(selectChain([{ spent: 12_345 }]))
      .mockReturnValueOnce(selectChain([{ count: 7 }]));

    const summary = await agentCostSummary({ userId: "user-1" });

    expect(summary.userId).toBe("user-1");
    expect(summary.tokensSpent).toBe(12_345);
    expect(summary.dispatchCount).toBe(7);
    expect(summary.since).toBeNull();
    expect(mockDb.select).toHaveBeenCalledTimes(2);
  });

  it("echoes the since window when provided", async () => {
    const since = new Date("2026-06-01T00:00:00Z");
    mockDb.select
      .mockReturnValueOnce(selectChain([{ spent: 100 }]))
      .mockReturnValueOnce(selectChain([{ count: 1 }]));

    const summary = await agentCostSummary({ userId: "user-1", since });
    expect(summary.since).toEqual(since);
  });

  it("coerces string aggregates (postgres bigint) to numbers", async () => {
    mockDb.select
      .mockReturnValueOnce(selectChain([{ spent: "999" }]))
      .mockReturnValueOnce(selectChain([{ count: "3" }]));

    const summary = await agentCostSummary({ userId: "user-1" });
    expect(summary.tokensSpent).toBe(999);
    expect(summary.dispatchCount).toBe(3);
    expect(typeof summary.tokensSpent).toBe("number");
  });

  it("treats empty result rows as zero", async () => {
    mockDb.select
      .mockReturnValueOnce(selectChain([]))
      .mockReturnValueOnce(selectChain([]));

    const summary = await agentCostSummary({ userId: "user-1" });
    expect(summary.tokensSpent).toBe(0);
    expect(summary.dispatchCount).toBe(0);
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
