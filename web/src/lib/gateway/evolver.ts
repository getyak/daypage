import "server-only";
import { z } from "zod";
import { and, desc, eq } from "drizzle-orm";
import { db } from "@/lib/db/client";
import {
  trees,
  tree_nodes,
  page_links,
  task_suggestions,
  change_log,
} from "@/lib/db/schema";
import { dashscope } from "@/lib/ai/dashscope";
import { logPrompt } from "@/lib/ai/prompt-log";

// US-019: Evolver loop — observe / plan / act ("long branch" growth).
//
// The evolver grows a task tree when a node has accumulated aligned evidence.
// It runs the classic agent loop, tightly scoped:
//   - observe: read the tree's nodes and their cited evidence (memo counts).
//   - plan:    ask the LLM, per hot node, whether to grow a new branch (the node
//              has spawned a distinct, aligned sub-pursuit) or to mark the node
//              `mature` (its line of pursuit is done / saturated).
//   - act:     ONLY tree-internal writes — insert a new `branch` tree_node under
//              the parent (+ a page_link when both endpoints have linked pages),
//              OR set the node `status='mature'` and emit a `task_suggestion`.
//
// Pruning (status='pruned') and dispatch are deliberately NOT executed here:
// they only ever surface as suggestions awaiting the gate. Every mutation is
// written to `change_log`; LLM token usage is attributed via `prompt_log`.
//
// The LLM is asked for strict JSON validated with zod; a malformed reply is
// retried once, then degraded to a no-op plan (logged, never thrown) so a flaky
// model can never break the Gateway loop.

const EVOLVER_MODEL = "qwen-plus";
// A node must have at least this many cited evidence memos before the evolver
// will even consider growing/maturing it — below this it is still "growing".
export const EVOLVE_MIN_EVIDENCE = 3;
// Cap the nodes we ask the LLM about per run, hottest first.
export const EVOLVE_MAX_CANDIDATES = 8;

// US-020: heat threshold a tree node must reach for the tree to become "hot"
// enough to evolve. compile-memo fires `gateway/evolve.requested` only on the
// commit that pushes a node's heat ACROSS this line (not on every commit), so a
// hot tree evolves once per crossing rather than on every memo.
export const EVOLVE_HEAT_THRESHOLD = 5;

// Did a commit that raised a node's heat from `heatBefore` to `heatAfter` cross
// the evolve threshold? True only on the transition (heatBefore below, heatAfter
// at/above) so repeated commits to an already-hot node don't re-trigger.
export function crossedEvolveThreshold(
  heatBefore: number,
  heatAfter: number
): boolean {
  return heatBefore < EVOLVE_HEAT_THRESHOLD && heatAfter >= EVOLVE_HEAT_THRESHOLD;
}

// ── Observation (read-only view of the tree) ────────────────────────────────────

export interface NodeObservation {
  node_id: string;
  parent_id: string | null;
  kind: "goal" | "branch" | "leaf";
  status: "growing" | "mature" | "merged" | "pruned";
  title: string;
  heat: number;
  page_id: string | null;
  evidence_count: number;
}

export interface TreeObservation {
  tree_id: string;
  user_id: string;
  title: string;
  // Candidate nodes the evolver may act on: growing-status, evidence over the
  // threshold, hottest first, capped. The LLM only ever sees these.
  candidates: NodeObservation[];
}

// ── Plan (LLM decision) ─────────────────────────────────────────────────────────

// One decision for one candidate node. `action`:
//   - "grow_branch": spawn a new child branch node (uses `branch_title`).
//   - "mark_mature": the node's pursuit is saturated; mark mature + suggest a task.
//   - "noop":        leave the node alone this round.
const decisionSchema = z.object({
  node_id: z.string().min(1),
  action: z.enum(["grow_branch", "mark_mature", "noop"]),
  // Required (non-empty) when action === "grow_branch".
  branch_title: z.string().nullish(),
  // Short justification; surfaced in change_log.reason / suggestion rationale.
  rationale: z.string().min(1),
});

const planEnvelopeSchema = z.object({
  decisions: z.array(decisionSchema),
});

export type EvolveDecision = z.infer<typeof decisionSchema>;

// ── Act results ─────────────────────────────────────────────────────────────────

export type EvolveActionResult =
  | {
      action: "grow_branch";
      node_id: string;
      new_node_id: string;
      linked: boolean;
    }
  | {
      action: "mark_mature";
      node_id: string;
      suggestion_id: string;
    };

export interface EvolveTreeResult {
  tree_id: string;
  observed: number;
  grown: number;
  matured: number;
  actions: EvolveActionResult[];
  tokens_in: number;
  tokens_out: number;
  degraded: boolean;
}

// ── Dependency-injected core ────────────────────────────────────────────────────
// Injectable so the loop is unit-testable without a live DB or LLM, mirroring
// `commitMemoToTree` (US-018).
export interface EvolveTreeDeps {
  // observe: read the tree + its actionable candidate nodes. Returns null if the
  // tree does not exist (e.g. archived/deleted) — the loop then no-ops.
  observe: (args: { treeId: string }) => Promise<TreeObservation | null>;
  // plan: ask the LLM for per-node decisions. Returns the decisions plus token
  // usage and a `degraded` flag (true when the model reply could not be parsed
  // and we fell back to an empty plan).
  plan: (obs: TreeObservation) => Promise<{
    decisions: EvolveDecision[];
    tokens_in: number;
    tokens_out: number;
    degraded: boolean;
  }>;
  // act (tree-internal only): insert a new branch node under the parent,
  // optionally creating a page_link from parent→child when both have pages.
  // Returns the new node id and whether a link was created. Writes change_log.
  growBranch: (args: {
    obs: TreeObservation;
    parent: NodeObservation;
    branchTitle: string;
    rationale: string;
  }) => Promise<{ new_node_id: string; linked: boolean }>;
  // act (tree-internal only): set the node status='mature' and emit a
  // task_suggestion linked to it. Writes change_log. Returns the suggestion id.
  markMature: (args: {
    obs: TreeObservation;
    node: NodeObservation;
    rationale: string;
  }) => Promise<{ suggestion_id: string }>;
}

/**
 * Run the evolver loop for one tree: observe → plan → act.
 *
 * Only ever performs tree-internal writes (new branch node + page_link, or
 * mark-mature + task_suggestion). Pruning and dispatch are out of scope and
 * surface only as suggestions for the gate. Never throws on a flaky-LLM path;
 * degrades to a no-op plan instead.
 */
export async function evolveTree(
  deps: EvolveTreeDeps,
  args: { treeId: string }
): Promise<EvolveTreeResult> {
  const obs = await deps.observe({ treeId: args.treeId });
  if (!obs) {
    return {
      tree_id: args.treeId,
      observed: 0,
      grown: 0,
      matured: 0,
      actions: [],
      tokens_in: 0,
      tokens_out: 0,
      degraded: false,
    };
  }

  const { decisions, tokens_in, tokens_out, degraded } = await deps.plan(obs);

  const byId = new Map(obs.candidates.map((c) => [c.node_id, c]));
  const actions: EvolveActionResult[] = [];
  let grown = 0;
  let matured = 0;

  for (const d of decisions) {
    const node = byId.get(d.node_id);
    // Ignore decisions about nodes we never offered (LLM hallucination).
    if (!node) continue;

    if (d.action === "grow_branch") {
      const title = d.branch_title?.trim();
      // A grow decision without a usable title is dropped, not guessed.
      if (!title) continue;
      const { new_node_id, linked } = await deps.growBranch({
        obs,
        parent: node,
        branchTitle: title,
        rationale: d.rationale,
      });
      actions.push({
        action: "grow_branch",
        node_id: node.node_id,
        new_node_id,
        linked,
      });
      grown++;
    } else if (d.action === "mark_mature") {
      // Only mature a node that is still growing; never re-mature.
      if (node.status !== "growing") continue;
      const { suggestion_id } = await deps.markMature({
        obs,
        node,
        rationale: d.rationale,
      });
      actions.push({
        action: "mark_mature",
        node_id: node.node_id,
        suggestion_id,
      });
      matured++;
    }
    // "noop": nothing to do.
  }

  return {
    tree_id: obs.tree_id,
    observed: obs.candidates.length,
    grown,
    matured,
    actions,
    tokens_in,
    tokens_out,
    degraded,
  };
}

// ── Prompt construction + parsing (shared by the live `plan` dep) ───────────────

function buildPlanPrompt(obs: TreeObservation): {
  system: string;
  user: string;
} {
  const system =
    "You are DayPage's task-tree Evolver. Given one task tree and its hottest " +
    "nodes (with how much evidence each has accumulated), decide for each node " +
    "whether to grow a new branch, mark it mature, or leave it. " +
    'Use action "grow_branch" ONLY when a node has accumulated aligned ' +
    "evidence that points to a distinct new sub-pursuit worth its own branch — " +
    'then provide a concise `branch_title`. Use "mark_mature" when a node\'s ' +
    'line of pursuit looks saturated/complete. Otherwise use "noop". ' +
    "Never propose pruning or deleting — that is out of scope. " +
    'Be conservative: most nodes should be "noop". ' +
    "Reply with ONLY a JSON object of the shape " +
    '{"decisions": [{"node_id": string, "action": ' +
    '"grow_branch"|"mark_mature"|"noop", "branch_title"?: string, ' +
    '"rationale": string}]}. No prose, no markdown fences.';

  const nodeLines = obs.candidates
    .map(
      (c) =>
        `- [${c.node_id}] (${c.kind}/${c.status}, heat ${c.heat.toFixed(1)}, ` +
        `${c.evidence_count} evidence) ${c.title}`
    )
    .join("\n");

  const user =
    `## Tree: ${obs.title}\n\n` +
    `## Candidate nodes (hottest first)\n${nodeLines}`;

  return { system, user };
}

// Tolerate a model that wraps JSON in ```fences``` despite instructions.
function stripFences(content: string): string {
  const trimmed = content.trim();
  const fence = trimmed.match(/^```(?:json)?\s*([\s\S]*?)\s*```$/);
  return fence ? fence[1].trim() : trimmed;
}

function parsePlan(content: string): EvolveDecision[] | null {
  let json: unknown;
  try {
    json = JSON.parse(stripFences(content));
  } catch {
    return null;
  }
  const parsed = planEnvelopeSchema.safeParse(json);
  if (!parsed.success) return null;
  return parsed.data.decisions;
}

// ── Production deps (real Drizzle + DashScope) ──────────────────────────────────

export const liveEvolveTreeDeps: EvolveTreeDeps = {
  async observe({ treeId }) {
    const [tree] = await db
      .select({
        tree_id: trees.id,
        user_id: trees.user_id,
        title: trees.title,
        status: trees.status,
      })
      .from(trees)
      .where(eq(trees.id, treeId))
      .limit(1);

    if (!tree || tree.status !== "active") return null;

    const rows = await db
      .select({
        node_id: tree_nodes.id,
        parent_id: tree_nodes.parent_id,
        kind: tree_nodes.kind,
        status: tree_nodes.status,
        title: tree_nodes.title,
        heat: tree_nodes.heat,
        page_id: tree_nodes.page_id,
        evidence_memo_ids: tree_nodes.evidence_memo_ids,
      })
      .from(tree_nodes)
      .where(
        and(eq(tree_nodes.tree_id, treeId), eq(tree_nodes.status, "growing"))
      )
      .orderBy(desc(tree_nodes.heat))
      .limit(EVOLVE_MAX_CANDIDATES);

    const candidates: NodeObservation[] = rows
      .map((r) => {
        const evidence = Array.isArray(r.evidence_memo_ids)
          ? (r.evidence_memo_ids as string[])
          : [];
        return {
          node_id: r.node_id,
          parent_id: r.parent_id,
          kind: r.kind,
          status: r.status,
          title: r.title,
          heat: r.heat,
          page_id: r.page_id,
          evidence_count: evidence.length,
        };
      })
      .filter((c) => c.evidence_count >= EVOLVE_MIN_EVIDENCE);

    return {
      tree_id: tree.tree_id,
      user_id: tree.user_id,
      title: tree.title,
      candidates,
    };
  },

  async plan(obs) {
    if (obs.candidates.length === 0) {
      return { decisions: [], tokens_in: 0, tokens_out: 0, degraded: false };
    }

    const { system, user } = buildPlanPrompt(obs);

    let decisions: EvolveDecision[] | null = null;
    let tokens_in = 0;
    let tokens_out = 0;

    // One attempt + one retry. A non-JSON / schema-mismatched reply triggers
    // the retry; a thrown ProviderError is caught and degrades to no-op.
    for (let attempt = 0; attempt < 2 && decisions === null; attempt++) {
      try {
        const res = await dashscope.chat(
          [
            { role: "system", content: system },
            { role: "user", content: user },
          ],
          { model: EVOLVER_MODEL, temperature: 0.3, jsonMode: true }
        );
        tokens_in += res.tokens_in;
        tokens_out += res.tokens_out;
        decisions = parsePlan(res.content);
        if (decisions === null) {
          console.warn(
            `[evolver] tree ${obs.tree_id}: invalid LLM JSON (attempt ${attempt + 1})`
          );
        }
      } catch (err) {
        console.error(
          `[evolver] tree ${obs.tree_id}: LLM call failed (attempt ${attempt + 1})`,
          err
        );
      }
    }

    // Attribute token usage to the tree's owner for per-user budgeting.
    await logPrompt({
      kind: "chat",
      model: EVOLVER_MODEL,
      tokens_in,
      tokens_out,
      user_id: obs.user_id,
    }).catch(() => undefined);

    if (decisions === null) {
      console.error(
        `[evolver] tree ${obs.tree_id}: degraded to no-op plan after retry`
      );
      return { decisions: [], tokens_in, tokens_out, degraded: true };
    }

    return { decisions, tokens_in, tokens_out, degraded: false };
  },

  async growBranch({ obs, parent, branchTitle, rationale }) {
    // Insert the new branch node under the parent, inheriting the tree.
    const [inserted] = await db
      .insert(tree_nodes)
      .values({
        tree_id: obs.tree_id,
        parent_id: parent.node_id,
        kind: "branch",
        status: "growing",
        title: branchTitle,
      })
      .returning({ id: tree_nodes.id, page_id: tree_nodes.page_id });

    const newNodeId = inserted.id;

    // page_links is page↔page; only create one when BOTH the parent node and
    // the new branch carry linked pages. A freshly grown branch has no page
    // yet, so in practice this stays false until the branch is compiled — the
    // relation is created here only when a page already exists (e.g. seeded).
    let linked = false;
    if (parent.page_id && inserted.page_id) {
      await db.insert(page_links).values({
        user_id: obs.user_id,
        from_page_id: parent.page_id,
        to_page_id: inserted.page_id,
        rationale: `evolver: grew branch "${branchTitle}"`,
      });
      linked = true;
    }

    await db.insert(change_log).values({
      user_id: obs.user_id,
      action_kind: "evolve_grow_branch",
      target_type: "tree_node",
      target_id: newNodeId,
      before: null,
      after: {
        tree_id: obs.tree_id,
        parent_id: parent.node_id,
        title: branchTitle,
        linked,
      },
      reason: rationale,
      performed_by: "agent",
      agent_action_id: parent.node_id,
    });

    return { new_node_id: newNodeId, linked };
  },

  async markMature({ obs, node, rationale }) {
    // Mark the node mature (tree-internal write).
    await db
      .update(tree_nodes)
      .set({ status: "mature", updated_at: new Date() })
      .where(eq(tree_nodes.id, node.node_id));

    await db.insert(change_log).values({
      user_id: obs.user_id,
      action_kind: "evolve_mark_mature",
      target_type: "tree_node",
      target_id: node.node_id,
      before: { status: node.status },
      after: { status: "mature" },
      reason: rationale,
      performed_by: "agent",
      agent_action_id: node.node_id,
    });

    // Emit a suggestion (awaiting the gate) — NOT a dispatch.
    const [suggestion] = await db
      .insert(task_suggestions)
      .values({
        user_id: obs.user_id,
        tree_node_id: node.node_id,
        title: `Wrap up: ${node.title}`,
        rationale,
      })
      .returning({ id: task_suggestions.id });

    await db.insert(change_log).values({
      user_id: obs.user_id,
      action_kind: "evolve_suggest_mature",
      target_type: "task_suggestion",
      target_id: suggestion.id,
      before: null,
      after: { tree_node_id: node.node_id },
      reason: rationale,
      performed_by: "agent",
      agent_action_id: node.node_id,
    });

    return { suggestion_id: suggestion.id };
  },
};

// Convenience wrapper used by the Gateway / Inngest: run the live loop for a tree.
export function evolveTreeLive(args: {
  treeId: string;
}): Promise<EvolveTreeResult> {
  return evolveTree(liveEvolveTreeDeps, args);
}
