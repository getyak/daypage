import { describe, it, expect, vi, beforeEach } from "vitest";

// evolver-step.ts imports db/client, the gateway policy/evolver modules, and the
// inngest client at module load — all of which would otherwise need a real
// DATABASE_URL / event key. Stub the heavy module-load side effects; the
// pipeline itself takes its dependencies via injection, so we drive it directly
// with mocks. `server-only` and db/client are stubbed so evolver.ts (which is
// `server-only`) can be imported for its pure threshold helpers without booting
// a real DB / LLM client.
vi.mock("server-only", () => ({}));
vi.mock("@/lib/db/client", () => ({ db: {} }));
vi.mock("@/lib/inngest/client", () => ({
  inngest: { createFunction: vi.fn(() => ({})) },
}));

import {
  runEvolverStep,
  type EvolverStepDeps,
} from "@/lib/inngest/functions/evolver-step";
import {
  crossedEvolveThreshold,
  EVOLVE_HEAT_THRESHOLD,
} from "@/lib/gateway/evolver";

// A fake step runner that records the order of step ids and invokes the thunk
// inline. Inngest memoizes/retries; for ordering we only need execution order.
function makeFakeStep() {
  const order: string[] = [];
  const step = async <T>(id: string, fn: () => Promise<T>): Promise<T> => {
    order.push(id);
    return fn();
  };
  return { step, order };
}

function makeEvolveResult(over: Record<string, unknown> = {}) {
  return {
    tree_id: "tree-1",
    observed: 2,
    grown: 1,
    matured: 0,
    actions: [],
    tokens_in: 100,
    tokens_out: 50,
    degraded: false,
    ...over,
  };
}

function makeDeps(over: Partial<EvolverStepDeps> = {}): EvolverStepDeps {
  return {
    resolveTreeOwner: vi.fn(async () => ({ userId: "user-1" })),
    checkBudget: vi.fn(async () => ({
      allowed: true,
      spent: 0,
      limit: 1_000_000,
      scope: "daily" as const,
    })),
    evolveTree: vi.fn(async () => makeEvolveResult()),
    ...over,
  };
}

beforeEach(() => {
  vi.restoreAllMocks();
  vi.spyOn(console, "log").mockImplementation(() => {});
  vi.spyOn(console, "warn").mockImplementation(() => {});
});

// ── heat threshold trigger (the event-driven trigger from compile-memo) ───────
describe("crossedEvolveThreshold", () => {
  it("fires on the commit that pushes heat across the threshold", () => {
    // heat goes from one-below to exactly the threshold → cross.
    expect(
      crossedEvolveThreshold(EVOLVE_HEAT_THRESHOLD - 1, EVOLVE_HEAT_THRESHOLD)
    ).toBe(true);
  });

  it("does not fire when heat stays below the threshold", () => {
    expect(crossedEvolveThreshold(0, EVOLVE_HEAT_THRESHOLD - 1)).toBe(false);
  });

  it("does not re-fire once the node is already hot", () => {
    // both endpoints at/above the threshold → already hot, no re-trigger.
    expect(
      crossedEvolveThreshold(EVOLVE_HEAT_THRESHOLD, EVOLVE_HEAT_THRESHOLD + 1)
    ).toBe(false);
  });

  it("fires when a single commit jumps from below to above the threshold", () => {
    expect(
      crossedEvolveThreshold(EVOLVE_HEAT_THRESHOLD - 1, EVOLVE_HEAT_THRESHOLD + 3)
    ).toBe(true);
  });
});

// ── pipeline: resolve-owner → gate → evolve ───────────────────────────────────
describe("runEvolverStep", () => {
  it("evolves the tree when within budget", async () => {
    const { step, order } = makeFakeStep();
    const deps = makeDeps();

    const result = await runEvolverStep({ treeId: "tree-1" }, step, deps);

    expect(deps.resolveTreeOwner).toHaveBeenCalledWith("tree-1");
    expect(deps.checkBudget).toHaveBeenCalledWith("user-1", "tree-1");
    expect(deps.evolveTree).toHaveBeenCalledWith({ treeId: "tree-1" });
    expect(order).toEqual(["resolve-owner", "gate", "evolve"]);
    expect(result).toEqual({
      skipped: false,
      treeId: "tree-1",
      result: makeEvolveResult(),
    });
  });

  it("skips (does NOT evolve) when the user is over budget — policy gate", async () => {
    const { step, order } = makeFakeStep();
    const deps = makeDeps({
      checkBudget: vi.fn(async () => ({
        allowed: false,
        spent: 2_000_000,
        limit: 1_000_000,
        scope: "daily" as const,
      })),
    });

    const result = await runEvolverStep({ treeId: "tree-1" }, step, deps);

    expect(deps.evolveTree).not.toHaveBeenCalled();
    expect(order).toEqual(["resolve-owner", "gate"]);
    expect(result).toEqual({ skipped: true, reason: "over-budget" });
  });

  it("skips when the tree is missing/archived (resolveTreeOwner → null)", async () => {
    const { step, order } = makeFakeStep();
    const deps = makeDeps({ resolveTreeOwner: vi.fn(async () => null) });

    const result = await runEvolverStep({ treeId: "gone" }, step, deps);

    expect(deps.checkBudget).not.toHaveBeenCalled();
    expect(deps.evolveTree).not.toHaveBeenCalled();
    expect(order).toEqual(["resolve-owner"]);
    expect(result).toEqual({ skipped: true, reason: "tree-not-found" });
  });

  it("skips on a missing treeId before touching any dependency", async () => {
    const { step, order } = makeFakeStep();
    const deps = makeDeps();

    const result = await runEvolverStep({}, step, deps);

    expect(deps.resolveTreeOwner).not.toHaveBeenCalled();
    expect(order).toEqual([]);
    expect(result).toEqual({ skipped: true, reason: "missing-treeId" });
  });
});
