// US-020: Inngest function `evolver.step` — hot trees evolve via a workflow.
//
// Trigger: `gateway/evolve.requested` {treeId}. This event is sent by
// compile-memo whenever a memo commit pushes a tree node's heat across the
// evolve threshold (event-driven; see compile-memo.ts `crossedEvolveThreshold`).
//
// The pipeline is split into independent Inngest steps so a transient failure in
// any stage is retried in isolation rather than re-running the whole flow:
//   1. resolve-owner — load the tree's user_id (needed to scope the budget).
//                      A missing/archived tree ⇒ skip (no-op).
//   2. gate          — policy: checkBudget. Over budget ⇒ skip, do NOT spend
//                      tokens growing the tree. (Tree-internal evolution is
//                      `auto` per the gate classifier, so no approve-first step.)
//   3. evolve        — evolveTreeLive: observe → plan → act. Never throws on a
//                      flaky-LLM path; it degrades to a no-op plan internally.

import { eq } from "drizzle-orm";
import { inngest } from "@/lib/inngest/client";
import { db } from "@/lib/db/client";
import { trees } from "@/lib/db/schema";
import { checkBudget } from "@/lib/gateway/policy";
import { evolveTreeLive, type EvolveTreeResult } from "@/lib/gateway/evolver";

// Minimal step runner contract — Inngest's `step.run` and the test fake both
// satisfy it. Each named step is memoized/retried independently by Inngest.
type StepRunner = <T>(id: string, fn: () => Promise<T>) => Promise<T>;

// Look up the owning user of a tree so the budget can be scoped per-user.
// Returns null when the tree is gone or not active (archived/deleted) — the
// step then no-ops rather than evolving a dead tree.
async function resolveTreeOwner(
  treeId: string
): Promise<{ userId: string } | null> {
  const [row] = await db
    .select({ user_id: trees.user_id, status: trees.status })
    .from(trees)
    .where(eq(trees.id, treeId))
    .limit(1);
  if (!row || row.status !== "active") return null;
  return { userId: row.user_id };
}

// Dependencies the pipeline calls out to. Injectable so unit tests drive the
// over-budget-skip and evolve paths without an Inngest runtime, a live DB, or
// an LLM.
export interface EvolverStepDeps {
  resolveTreeOwner: (treeId: string) => Promise<{ userId: string } | null>;
  checkBudget: typeof checkBudget;
  evolveTree: (args: { treeId: string }) => Promise<EvolveTreeResult>;
}

const defaultDeps: EvolverStepDeps = {
  resolveTreeOwner,
  checkBudget,
  evolveTree: evolveTreeLive,
};

export type EvolverStepResult =
  | { skipped: true; reason: "missing-treeId" | "tree-not-found" | "over-budget" }
  | { skipped: false; treeId: string; result: EvolveTreeResult };

// The pure orchestration: resolve-owner → gate (budget) → evolve. Extracted from
// the Inngest handler so it can be unit tested with a fake `step` and mocked
// `deps`. The policy gate guards spend before the LLM is ever called.
export async function runEvolverStep(
  params: { treeId?: string },
  step: StepRunner,
  deps: EvolverStepDeps = defaultDeps
): Promise<EvolverStepResult> {
  const { treeId } = params;

  if (!treeId) {
    console.warn("[evolver-step] missing treeId in event payload, skipping");
    return { skipped: true, reason: "missing-treeId" };
  }

  // ── 1. Resolve the tree owner (scope the budget) ──────────────────────────
  const owner = await step("resolve-owner", async () =>
    deps.resolveTreeOwner(treeId)
  );
  if (!owner) {
    console.log(`[evolver-step] tree ${treeId} not found/active, skipping`);
    return { skipped: true, reason: "tree-not-found" };
  }

  // ── 2. Policy gate: budget ────────────────────────────────────────────────
  const budget = await step("gate", async () =>
    deps.checkBudget(owner.userId, treeId)
  );
  if (!budget.allowed) {
    console.log(
      `[evolver-step] over budget for user ${owner.userId} ` +
        `(spent ${budget.spent}/${budget.limit}), skipping evolve of tree ${treeId}`
    );
    return { skipped: true, reason: "over-budget" };
  }

  // ── 3. Evolve the tree (observe → plan → act) ─────────────────────────────
  const result = await step("evolve", async () => deps.evolveTree({ treeId }));
  console.log(
    `[evolver-step] tree ${treeId}: observed ${result.observed}, ` +
      `grown ${result.grown}, matured ${result.matured}` +
      (result.degraded ? " (degraded)" : "")
  );

  return { skipped: false, treeId, result };
}

export const evolverStep = inngest.createFunction(
  { id: "evolver-step", name: "Evolver — gate & evolve a hot tree" },
  { event: "gateway/evolve.requested" },
  async ({ event, step }) => {
    const data = event.data as { treeId?: string } | undefined;
    // step.run's return type is Inngest's JSON-serialized projection of the
    // thunk result; our StepRunner contract preserves the original shape, so
    // bridge with a cast.
    const run: StepRunner = (id, fn) =>
      step.run(id, fn) as Promise<Awaited<ReturnType<typeof fn>>>;
    return runEvolverStep({ treeId: data?.treeId }, run);
  }
);
