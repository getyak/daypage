// US-016: Inngest workflow that processes a dispatch job through the policy gate
// and then hands the work order to an executor.
//
// Trigger: `gateway/dispatch.requested` {suggestionId, jobId?, approved?}. This
// event is produced when a user-selected suggestion's dispatch job is pulled
// from `gateway_jobs` (type='dispatch', enqueued by US-013 selectSuggestion).
//
// The pipeline is split into independent Inngest steps so a transient failure in
// any stage is retried in isolation rather than re-running the whole flow (and
// re-spending tokens or re-materializing a task file):
//   1. build-order   — buildWorkOrder: lift the suggestion into a normalized
//                      WorkOrder row, classifying its side-effect gate.
//   2. gate          — policy: checkBudget + circuitState (claude-code). Over
//                      budget or breaker-open ⇒ park the order `gated`, stop.
//   3. dispatch      — gate==='auto' (or approved) ⇒ dispatch() to claude-code,
//                      flip suggestion → 'dispatched'. gate==='approve-first'
//                      and not yet approved ⇒ park the order `gated`, stop at
//                      the gate awaiting user OK.
//   4. complete-job  — mark the gateway_jobs row done (best-effort).
//
// `dispatch()` (the claude-code connector) never throws — it returns a
// discriminated result — so the dispatch step surfaces failures in its return
// value rather than forcing an Inngest retry on, e.g., an fs error.

import { eq } from "drizzle-orm";
import { inngest } from "@/lib/inngest/client";
import { db } from "@/lib/db/client";
import { task_suggestions, work_orders } from "@/lib/db/schema";
import {
  buildWorkOrder,
  routeWorkOrder,
  type BuildWorkOrderResult,
} from "@/lib/gateway/work-order";
import {
  checkBudget,
  circuitState,
  type ExecutionTarget,
} from "@/lib/gateway/policy";
import { readPerTreeBudgetTokens } from "@/lib/gateway/cost";
import { dispatch, type DispatchResult } from "@/lib/connectors/claude-code";
import { completeJob } from "@/lib/gateway/jobs";

// The executor backend dispatch targets. US-015's connector materializes work
// for the `claude-code` backend, so that is the backend we gate against.
const DISPATCH_BACKEND = "claude-code" as const;

// Park a built work order at its gate: the order stays paused (`gated`) awaiting
// either user approval (approve-first) or budget/circuit recovery. The linked
// suggestion is left `selected` (not advanced to `dispatched`) so a later
// approval can re-drive dispatch.
async function parkAtGate(workOrderId: string): Promise<void> {
  await db
    .update(work_orders)
    .set({ status: "gated" })
    .where(eq(work_orders.id, workOrderId));
}

// Advance the suggestion to `dispatched` once the executor has accepted the
// order. Idempotent: the WHERE guard means a re-run after the suggestion is
// already `dispatched` is a no-op.
async function markSuggestionDispatched(suggestionId: string): Promise<void> {
  await db
    .update(task_suggestions)
    .set({ status: "dispatched" })
    .where(eq(task_suggestions.id, suggestionId));
}

// Minimal step runner contract — Inngest's `step.run` and the test fake both
// satisfy it. Each named step is memoized/retried independently by Inngest.
type StepRunner = <T>(id: string, fn: () => Promise<T>) => Promise<T>;

// Dependencies the pipeline calls out to. Injectable so unit tests drive the
// auto-dispatch and approve-first-block paths without an Inngest runtime or a
// live database / filesystem.
export interface DispatchDeps {
  buildWorkOrder: typeof buildWorkOrder;
  routeWorkOrder: typeof routeWorkOrder;
  checkBudget: typeof checkBudget;
  // US-031: read the user's per-tree token ceiling so the budget gate can
  // enforce it alongside the daily limit.
  readPerTreeBudgetTokens: typeof readPerTreeBudgetTokens;
  circuitState: typeof circuitState;
  dispatch: typeof dispatch;
  parkAtGate: (workOrderId: string) => Promise<void>;
  markSuggestionDispatched: (suggestionId: string) => Promise<void>;
  completeJob: typeof completeJob;
}

const defaultDeps: DispatchDeps = {
  buildWorkOrder,
  routeWorkOrder,
  checkBudget,
  readPerTreeBudgetTokens,
  circuitState,
  dispatch,
  parkAtGate,
  markSuggestionDispatched,
  completeJob,
};

// US-026: which executor targets have a wired connector. Only `claude-code` has
// a real connector today (US-015); orders routed to the self-hosted `sandbox`
// or the other outsourced backends (`openclaw`/`ralph`) are parked `gated` until
// their connectors land, rather than mis-dispatched to claude-code.
const CONNECTED_TARGETS: ReadonlySet<ExecutionTarget> = new Set<ExecutionTarget>([
  "claude-code",
]);

export type DispatchPipelineResult =
  | { skipped: true; reason: string; [k: string]: unknown }
  | {
      skipped: false;
      suggestionId: string;
      workOrderId: string;
      outcome: "dispatched" | "gated";
      sessionId: string | null;
      // US-026: the executor target chosen by routeWorkOrder, when routing ran.
      // Absent on the pre-routing gates (budget / circuit / approve-first).
      target?: ExecutionTarget;
    };

// Close out the gateway_jobs row when one is linked. No jobId (event fired
// without a job) is fine — there is simply nothing to complete.
async function finishJob(deps: DispatchDeps, jobId?: string): Promise<void> {
  if (jobId) {
    await deps.completeJob(jobId);
  }
}

// The pure orchestration: build → gate (budget + circuit) → dispatch-or-park →
// complete-job. `approved` short-circuits the approve-first gate (a prior user
// OK). Extracted from the Inngest handler so it can be unit tested with a fake
// `step` and mocked `deps`.
export async function runDispatchPipeline(
  params: { suggestionId?: string; jobId?: string; approved?: boolean },
  step: StepRunner,
  deps: DispatchDeps = defaultDeps
): Promise<DispatchPipelineResult> {
  const { suggestionId, jobId, approved = false } = params;

  if (!suggestionId) {
    console.warn(
      "[executor-dispatch] missing suggestionId in event payload, skipping"
    );
    return { skipped: true, reason: "missing-suggestionId" };
  }

  // ── 1. Build the work order from the selected suggestion ──────────────────
  const built: BuildWorkOrderResult = await step("build-order", async () => {
    return deps.buildWorkOrder(suggestionId);
  });
  const order = built.row;

  // ── 2. Policy gate: budget (daily + per-tree) + circuit breaker ───────────
  const treeId = (order.context as { tree_id?: string } | null)?.tree_id;
  const gate = await step("gate", async () => {
    // Read the per-tree ceiling only when the order targets a tree, so a
    // tree-less order skips the extra settings read.
    const perTreeBudgetTokens = treeId
      ? await deps.readPerTreeBudgetTokens(order.user_id)
      : 0;
    const [budget, circuit] = await Promise.all([
      deps.checkBudget(order.user_id, { treeId, perTreeBudgetTokens }),
      deps.circuitState(DISPATCH_BACKEND),
    ]);
    return { budget, circuit };
  });

  if (!gate.budget.allowed) {
    await step("park-over-budget", async () => deps.parkAtGate(order.id));
    await step("complete-job", async () => finishJob(deps, jobId));
    console.log(
      `[executor-dispatch] over ${gate.budget.scope} budget for user ${order.user_id} ` +
        `(spent ${gate.budget.spent}/${gate.budget.limit}), parking order ${order.id} gated`
    );
    return {
      skipped: false,
      suggestionId,
      workOrderId: order.id,
      outcome: "gated",
      sessionId: null,
    };
  }

  if (gate.circuit.open) {
    await step("park-circuit-open", async () => deps.parkAtGate(order.id));
    await step("complete-job", async () => finishJob(deps, jobId));
    console.warn(
      `[executor-dispatch] circuit open for ${DISPATCH_BACKEND} ` +
        `(${gate.circuit.failures} consecutive failures), parking order ${order.id} gated`
    );
    return {
      skipped: false,
      suggestionId,
      workOrderId: order.id,
      outcome: "gated",
      sessionId: null,
    };
  }

  // ── 3. Side-effect gate: approve-first pauses unless already approved ──────
  const needsApproval = order.gate === "approve-first" && !approved;
  if (needsApproval) {
    await step("park-approve-first", async () => deps.parkAtGate(order.id));
    await step("complete-job", async () => finishJob(deps, jobId));
    console.log(
      `[executor-dispatch] order ${order.id} gate=approve-first and not approved, ` +
        `parking at gate awaiting user OK`
    );
    return {
      skipped: false,
      suggestionId,
      workOrderId: order.id,
      outcome: "gated",
      sessionId: null,
    };
  }

  // ── 4. Route by side-effect weight, then dispatch via the matching connector ─
  // routeWorkOrder picks an executor target from the intent: lightweight
  // read/text work → 'sandbox'; heavy / side-effecting work → an outsourced
  // backend. Only 'claude-code' has a wired connector today, so other targets
  // park `gated` awaiting their connector rather than dispatching to the wrong
  // backend.
  const route = deps.routeWorkOrder(order);

  if (!CONNECTED_TARGETS.has(route.target)) {
    await step("park-no-connector", async () => deps.parkAtGate(order.id));
    await step("complete-job", async () => finishJob(deps, jobId));
    console.log(
      `[executor-dispatch] order ${order.id} routed to '${route.target}' ` +
        `(${route.reason}) — no connector wired, parking gated`
    );
    return {
      skipped: false,
      suggestionId,
      workOrderId: order.id,
      outcome: "gated",
      sessionId: null,
      target: route.target,
    };
  }

  const result: DispatchResult = await step("dispatch", async () => {
    return deps.dispatch(order);
  });

  if (result.status === "failed") {
    // The connector already flipped the order to `failed`; report and let the
    // job complete (the failure is recorded on the order, not retried blindly).
    await step("complete-job", async () => finishJob(deps, jobId));
    console.error(
      `[executor-dispatch] dispatch failed for order ${order.id}: ${result.error}`
    );
    return {
      skipped: true,
      reason: "dispatch-failed",
      suggestionId,
      workOrderId: order.id,
      error: result.error,
    };
  }

  // Success: advance the suggestion to `dispatched`, then close the job.
  await step("mark-dispatched", async () =>
    deps.markSuggestionDispatched(suggestionId)
  );
  await step("complete-job", async () => finishJob(deps, jobId));

  return {
    skipped: false,
    suggestionId,
    workOrderId: order.id,
    outcome: "dispatched",
    sessionId: result.sessionId,
    target: route.target,
  };
}

export const executorDispatch = inngest.createFunction(
  { id: "executor-dispatch", name: "Executor — gate & dispatch work order" },
  { event: "gateway/dispatch.requested" },
  async ({ event, step }) => {
    const data = event.data as
      | { suggestionId?: string; jobId?: string; approved?: boolean }
      | undefined;
    // step.run's return type is Inngest's JSON-serialized projection of the
    // thunk result; our StepRunner contract preserves the original shape, so
    // bridge with a cast.
    const run: StepRunner = (id, fn) =>
      step.run(id, fn) as Promise<Awaited<ReturnType<typeof fn>>>;
    return runDispatchPipeline(
      {
        suggestionId: data?.suggestionId,
        jobId: data?.jobId,
        approved: data?.approved,
      },
      run
    );
  }
);
