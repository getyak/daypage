import "server-only";
import { eq } from "drizzle-orm";
import { db } from "@/lib/db/client";
import {
  task_suggestions,
  tree_nodes,
  trees,
  work_orders,
  type WorkOrder as WorkOrderRow,
} from "@/lib/db/schema";
import {
  classifyGate,
  classifyRoute,
  type ExecutionTarget,
  type RouteDecision,
  type WorkOrderGate,
} from "@/lib/gateway/policy";

// US-014: WorkOrder contract + builder. A `WorkOrder` is the normalized brief an
// executor runs from. The Gateway builds one when a user selects a suggestion:
// it lifts the suggestion's intent, folds in the linked tree-node context, and
// classifies the side-effect gate (text generation → auto; code mutation /
// external writes → approve-first). The built order is persisted to
// `work_orders` so dispatch (US-015) can pick it up durably.

// ── Contract ────────────────────────────────────────────────────────────────────

// Where an executor reports its result back to. `kind` names the channel; the
// remaining fields are channel-specific (e.g. a Telegram chat id, a tree node to
// flow the artifact back into). Persisted to `work_orders.callback` as JSON.
export interface WorkOrderCallback {
  kind: "telegram" | "tree-node" | "none";
  chat_id?: string;
  tree_node_id?: string;
}

// Context briefing the executor. `tree_node_id`/`tree_id`/`tree_title`/
// `node_title` cite where this work grew from; `rationale` is the Suggester's
// reasoning; `estimate`/`suggested_target` hint the executor tier. Persisted to
// `work_orders.context` as JSON.
export interface WorkOrderContext {
  suggestion_id: string;
  rationale: string;
  tree_id?: string;
  tree_title?: string;
  tree_node_id?: string;
  node_title?: string;
  node_kind?: string;
  estimate?: string;
  suggested_target?: string;
}

// The normalized unit of work handed to an executor. Mirrors the `work_orders`
// table columns (US-004 schema) so a built order maps 1:1 onto a row insert.
export interface WorkOrder {
  intent: string;
  context: WorkOrderContext;
  output_spec: string | null;
  gate: WorkOrderGate;
  callback: WorkOrderCallback | null;
  budget_tokens: number | null;
}

// ── Builder ────────────────────────────────────────────────────────────────────

export interface BuildWorkOrderOptions {
  // Where to report the result back. Defaults to no callback.
  callback?: WorkOrderCallback;
  // Token ceiling for this order; null leaves the executor to use its default.
  budgetTokens?: number;
}

// Default per-order token ceiling. Conservative; overridable per build.
const DEFAULT_BUDGET_TOKENS = 100_000;

export interface BuildWorkOrderResult {
  workOrder: WorkOrder;
  row: WorkOrderRow;
}

/**
 * Build a normalized WorkOrder from a selected suggestion and persist it.
 *
 * Loads the `task_suggestion` and, when it links a `tree_node`, the node + its
 * tree so the executor gets the surrounding goal context. The intent is the
 * suggestion title; `classifyGate(intent)` decides the side-effect gate. The
 * built order is inserted into `work_orders` and both the in-memory order and
 * the persisted row are returned.
 *
 * @throws if the suggestion id does not exist.
 */
export async function buildWorkOrder(
  suggestionId: string,
  opts: BuildWorkOrderOptions = {}
): Promise<BuildWorkOrderResult> {
  const suggRows = await db
    .select()
    .from(task_suggestions)
    .where(eq(task_suggestions.id, suggestionId))
    .limit(1);

  const suggestion = suggRows[0];
  if (!suggestion) {
    throw new Error(`buildWorkOrder: suggestion ${suggestionId} not found`);
  }

  // Pull the linked tree-node context when the suggestion grew from a node. A
  // suggestion with no `tree_node_id` (or whose node was pruned) just yields no
  // tree context — the order is still valid, just less grounded.
  let nodeContext: {
    tree_id: string;
    tree_title: string;
    tree_node_id: string;
    node_title: string;
    node_kind: string;
  } | null = null;

  if (suggestion.tree_node_id) {
    const nodeRows = await db
      .select({
        tree_id: trees.id,
        tree_title: trees.title,
        node_id: tree_nodes.id,
        node_title: tree_nodes.title,
        node_kind: tree_nodes.kind,
      })
      .from(tree_nodes)
      .innerJoin(trees, eq(tree_nodes.tree_id, trees.id))
      .where(eq(tree_nodes.id, suggestion.tree_node_id))
      .limit(1);

    const node = nodeRows[0];
    if (node) {
      nodeContext = {
        tree_id: node.tree_id,
        tree_title: node.tree_title,
        tree_node_id: node.node_id,
        node_title: node.node_title,
        node_kind: node.node_kind,
      };
    }
  }

  const intent = suggestion.title;
  const gate = classifyGate(intent);

  const context: WorkOrderContext = {
    suggestion_id: suggestion.id,
    rationale: suggestion.rationale,
    estimate: suggestion.estimate ?? undefined,
    suggested_target: suggestion.suggested_target ?? undefined,
    ...(nodeContext
      ? {
          tree_id: nodeContext.tree_id,
          tree_title: nodeContext.tree_title,
          tree_node_id: nodeContext.tree_node_id,
          node_title: nodeContext.node_title,
          node_kind: nodeContext.node_kind,
        }
      : {}),
  };

  const callback: WorkOrderCallback | null = opts.callback ?? null;
  const budget_tokens = opts.budgetTokens ?? DEFAULT_BUDGET_TOKENS;

  const workOrder: WorkOrder = {
    intent,
    context,
    // No structured output spec yet; the executor infers it from intent +
    // context. Reserved for a future story to carry an explicit schema/format.
    output_spec: null,
    gate,
    callback,
    budget_tokens,
  };

  const inserted = await db
    .insert(work_orders)
    .values({
      user_id: suggestion.user_id,
      suggestion_id: suggestion.id,
      intent: workOrder.intent,
      context: workOrder.context,
      output_spec: workOrder.output_spec,
      gate: workOrder.gate,
      callback: workOrder.callback,
      budget_tokens: workOrder.budget_tokens,
    })
    .returning();

  return { workOrder, row: inserted[0] };
}

// ── Routing ──────────────────────────────────────────────────────────────────

// US-026: route a built work order to an executor target by side-effect weight.
// Accepts either an in-memory `WorkOrder` or the persisted `work_orders` row —
// both carry the `intent` that drives the decision. The routing rules live in
// the policy (`classifyRoute`); this is the thin wrapper dispatch consults to
// pick a connector: lightweight read/text work → 'sandbox' (self-hosted),
// heavy / side-effecting work → an outsourced backend.
export function routeWorkOrder(
  wo: Pick<WorkOrder, "intent"> | Pick<WorkOrderRow, "intent">
): RouteDecision {
  return classifyRoute(wo.intent);
}

export type { ExecutionTarget, RouteDecision };
