import { describe, it, expect, vi, beforeEach } from "vitest";

// executor-dispatch.ts imports db/client, the gateway helpers, and the
// claude-code connector at module load — all of which would otherwise need a
// real DATABASE_URL / filesystem. Stub the heavy module-load side effects; the
// pipeline itself takes its dependencies via injection, so we drive it directly
// with mocks.
vi.mock("@/lib/db/client", () => ({ db: {} }));
vi.mock("@/lib/inngest/client", () => ({
  inngest: { createFunction: vi.fn(() => ({})) },
}));

import {
  runDispatchPipeline,
  type DispatchDeps,
} from "@/lib/inngest/functions/executor-dispatch";
import type { WorkOrder } from "@/lib/db/schema";
import type { BuildWorkOrderResult } from "@/lib/gateway/work-order";

// A fake step runner that records the order of step ids and invokes the thunk
// inline (Inngest memoizes/retries; for ordering we only need execution order).
function makeFakeStep() {
  const order: string[] = [];
  const step = async <T>(id: string, fn: () => Promise<T>): Promise<T> => {
    order.push(id);
    return fn();
  };
  return { step, order };
}

// Minimal WorkOrder row stand-in. Only the fields the pipeline reads matter:
// id, user_id, gate, context, status, intent.
function makeOrder(over: Partial<WorkOrder> = {}): WorkOrder {
  return {
    id: "wo-1",
    user_id: "user-1",
    suggestion_id: "sug-1",
    intent: "summarize the week",
    context: { tree_id: "tree-1" },
    output_spec: null,
    gate: "auto",
    callback: null,
    budget_tokens: 100_000,
    status: "pending",
    result_ref: null,
    created_at: new Date("2026-06-10T00:00:00Z"),
    ...over,
  } as WorkOrder;
}

function makeBuilt(order: WorkOrder): BuildWorkOrderResult {
  return { row: order, workOrder: {} as never };
}

function makeDeps(over: Partial<DispatchDeps> = {}): DispatchDeps {
  return {
    buildWorkOrder: vi.fn(async () => makeBuilt(makeOrder())),
    // Default to a claude-code route so the existing dispatch-path tests below
    // exercise the connector; the routing-specific tests override this.
    routeWorkOrder: vi.fn(() => ({
      target: "claude-code" as const,
      reason: "test-default",
    })),
    checkBudget: vi.fn(async () => ({ allowed: true, spent: 0, limit: 1_000_000 })),
    circuitState: vi.fn(async () => ({ open: false, failures: 0, threshold: 5 })),
    dispatch: vi.fn(async () => ({
      sessionId: "sess-1",
      status: "active" as const,
      externalRef: "/tmp/wo-1.md",
    })),
    parkAtGate: vi.fn(async () => {}),
    markSuggestionDispatched: vi.fn(async () => {}),
    completeJob: vi.fn(async () => null),
    ...over,
  };
}

beforeEach(() => {
  vi.restoreAllMocks();
  vi.spyOn(console, "log").mockImplementation(() => {});
  vi.spyOn(console, "warn").mockImplementation(() => {});
  vi.spyOn(console, "error").mockImplementation(() => {});
});

describe("runDispatchPipeline", () => {
  it("auto gate: dispatches directly and advances the suggestion", async () => {
    const { step, order: steps } = makeFakeStep();
    const deps = makeDeps({
      buildWorkOrder: vi.fn(async () => makeBuilt(makeOrder({ gate: "auto" }))),
    });

    const result = await runDispatchPipeline(
      { suggestionId: "sug-1", jobId: "job-1" },
      step,
      deps
    );

    expect(steps).toEqual([
      "build-order",
      "gate",
      "dispatch",
      "mark-dispatched",
      "complete-job",
    ]);
    expect(deps.dispatch).toHaveBeenCalledTimes(1);
    expect(deps.parkAtGate).not.toHaveBeenCalled();
    expect(deps.markSuggestionDispatched).toHaveBeenCalledWith("sug-1");
    expect(deps.completeJob).toHaveBeenCalledWith("job-1");
    expect(result).toMatchObject({
      skipped: false,
      outcome: "dispatched",
      workOrderId: "wo-1",
      sessionId: "sess-1",
    });
  });

  it("approve-first gate (not approved): parks the order gated, no dispatch", async () => {
    const { step, order: steps } = makeFakeStep();
    const deps = makeDeps({
      buildWorkOrder: vi.fn(async () =>
        makeBuilt(makeOrder({ gate: "approve-first" }))
      ),
    });

    const result = await runDispatchPipeline(
      { suggestionId: "sug-1", jobId: "job-1", approved: false },
      step,
      deps
    );

    expect(steps).toEqual([
      "build-order",
      "gate",
      "park-approve-first",
      "complete-job",
    ]);
    expect(deps.dispatch).not.toHaveBeenCalled();
    expect(deps.parkAtGate).toHaveBeenCalledWith("wo-1");
    expect(deps.markSuggestionDispatched).not.toHaveBeenCalled();
    expect(deps.completeJob).toHaveBeenCalledWith("job-1");
    expect(result).toMatchObject({
      skipped: false,
      outcome: "gated",
      workOrderId: "wo-1",
      sessionId: null,
    });
  });

  it("approve-first gate with approved=true: dispatches", async () => {
    const { step } = makeFakeStep();
    const deps = makeDeps({
      buildWorkOrder: vi.fn(async () =>
        makeBuilt(makeOrder({ gate: "approve-first" }))
      ),
    });

    const result = await runDispatchPipeline(
      { suggestionId: "sug-1", jobId: "job-1", approved: true },
      step,
      deps
    );

    expect(deps.dispatch).toHaveBeenCalledTimes(1);
    expect(deps.parkAtGate).not.toHaveBeenCalled();
    expect(result).toMatchObject({ outcome: "dispatched" });
  });

  it("over budget: parks gated, never dispatches", async () => {
    const { step } = makeFakeStep();
    const deps = makeDeps({
      checkBudget: vi.fn(async () => ({
        allowed: false,
        spent: 2_000_000,
        limit: 1_000_000,
      })),
    });

    const result = await runDispatchPipeline({ suggestionId: "sug-1" }, step, deps);

    expect(deps.dispatch).not.toHaveBeenCalled();
    expect(deps.parkAtGate).toHaveBeenCalledWith("wo-1");
    expect(result).toMatchObject({ outcome: "gated" });
  });

  it("circuit open: parks gated, never dispatches", async () => {
    const { step } = makeFakeStep();
    const deps = makeDeps({
      circuitState: vi.fn(async () => ({ open: true, failures: 5, threshold: 5 })),
    });

    const result = await runDispatchPipeline({ suggestionId: "sug-1" }, step, deps);

    expect(deps.dispatch).not.toHaveBeenCalled();
    expect(deps.parkAtGate).toHaveBeenCalledWith("wo-1");
    expect(result).toMatchObject({ outcome: "gated" });
  });

  it("dispatch failure: surfaces error, completes job, does not advance suggestion", async () => {
    const { step } = makeFakeStep();
    const deps = makeDeps({
      dispatch: vi.fn(async () => ({
        sessionId: null,
        status: "failed" as const,
        error: "disk full",
      })),
    });

    const result = await runDispatchPipeline(
      { suggestionId: "sug-1", jobId: "job-1" },
      step,
      deps
    );

    expect(deps.markSuggestionDispatched).not.toHaveBeenCalled();
    expect(deps.completeJob).toHaveBeenCalledWith("job-1");
    expect(result).toMatchObject({ skipped: true, reason: "dispatch-failed" });
  });

  it("missing suggestionId: skips before building", async () => {
    const { step } = makeFakeStep();
    const deps = makeDeps();

    const result = await runDispatchPipeline({}, step, deps);

    expect(deps.buildWorkOrder).not.toHaveBeenCalled();
    expect(result).toMatchObject({ skipped: true, reason: "missing-suggestionId" });
  });

  it("no jobId: dispatches without completing a job", async () => {
    const { step } = makeFakeStep();
    const deps = makeDeps();

    const result = await runDispatchPipeline({ suggestionId: "sug-1" }, step, deps);

    expect(deps.completeJob).not.toHaveBeenCalled();
    expect(result).toMatchObject({ outcome: "dispatched" });
  });

  // ── US-026: connector routing ─────────────────────────────────────────────

  it("claude-code route: dispatches via the connector and tags the target", async () => {
    const { step, order } = makeFakeStep();
    const deps = makeDeps({
      routeWorkOrder: vi.fn(() => ({
        target: "claude-code" as const,
        reason: "code-mutation → claude-code",
      })),
    });

    const result = await runDispatchPipeline(
      { suggestionId: "sug-1", jobId: "job-1" },
      step,
      deps
    );

    expect(deps.dispatch).toHaveBeenCalledOnce();
    expect(order).not.toContain("park-no-connector");
    expect(result).toMatchObject({ outcome: "dispatched", target: "claude-code" });
  });

  it.each(["sandbox", "openclaw", "ralph"] as const)(
    "%s route: no wired connector → parks gated, does not dispatch",
    async (target) => {
      const { step, order } = makeFakeStep();
      const deps = makeDeps({
        routeWorkOrder: vi.fn(() => ({ target, reason: `routed → ${target}` })),
      });

      const result = await runDispatchPipeline(
        { suggestionId: "sug-1", jobId: "job-1" },
        step,
        deps
      );

      expect(deps.dispatch).not.toHaveBeenCalled();
      expect(deps.markSuggestionDispatched).not.toHaveBeenCalled();
      expect(order).toContain("park-no-connector");
      expect(deps.parkAtGate).toHaveBeenCalledWith("wo-1");
      expect(deps.completeJob).toHaveBeenCalledWith("job-1");
      expect(result).toMatchObject({ outcome: "gated", target });
    }
  );
});
