import "server-only";
import { db } from "@/lib/db/client";
import {
  prompt_log,
  change_log,
  work_orders,
  user_settings,
} from "@/lib/db/schema";
import { and, eq, sql } from "drizzle-orm";
import { readEvolutionConfig } from "@/lib/settings/evolution";

// US-031: cost statistics for the Gateway. Two cheap aggregate reads back the
// budget-circuit-breaker and any cost dashboards:
//   • token spend   — sum prompt_log (tokens_in + tokens_out)
//   • dispatch count — count change_log rows recording a work-order dispatch
//
// Both are reused by `policy.checkBudget` (per-tree budget enforcement) and can
// be surfaced directly to the user as an "agent cost summary".

// The change_log action a dispatch records (see connectors/claude-code.ts). The
// number of these rows is the user's "how many times did I outsource work" tally.
export const DISPATCH_ACTION_KIND = "dispatch_workorder";

export interface AgentCostSummaryInput {
  userId: string;
  // Only count usage at/after this instant. Omit to count all-time spend.
  since?: Date;
}

export interface AgentCostSummary {
  userId: string;
  // Total LLM tokens (in + out) attributed to the user over the window.
  tokensSpent: number;
  // Number of work-order dispatches over the window (change_log dispatch rows).
  dispatchCount: number;
  // The window floor used, echoed for callers that surface it. null = all-time.
  since: Date | null;
}

// Aggregate a user's agent cost over an optional trailing window: prompt_log
// token spend plus change_log dispatch count. Two independent SELECTs (no join)
// so each stays index-friendly and the absence of one source can't skew the other.
export async function agentCostSummary(
  input: AgentCostSummaryInput
): Promise<AgentCostSummary> {
  const { userId, since } = input;

  const tokenWhere = since
    ? and(eq(prompt_log.user_id, userId), sql`${prompt_log.created_at} >= ${since}`)
    : eq(prompt_log.user_id, userId);

  const dispatchWhere = since
    ? and(
        eq(change_log.user_id, userId),
        eq(change_log.action_kind, DISPATCH_ACTION_KIND),
        sql`${change_log.created_at} >= ${since}`
      )
    : and(
        eq(change_log.user_id, userId),
        eq(change_log.action_kind, DISPATCH_ACTION_KIND)
      );

  const [tokenRows, dispatchRows] = await Promise.all([
    db
      .select({
        spent: sql<number>`coalesce(sum(${prompt_log.tokens_in} + ${prompt_log.tokens_out}), 0)`,
      })
      .from(prompt_log)
      .where(tokenWhere),
    db
      .select({ count: sql<number>`count(*)` })
      .from(change_log)
      .where(dispatchWhere),
  ]);

  return {
    userId,
    tokensSpent: Number(tokenRows[0]?.spent ?? 0),
    dispatchCount: Number(dispatchRows[0]?.count ?? 0),
    since: since ?? null,
  };
}

// US-031: token spend attributed to a single evolution tree. prompt_log has no
// tree column, so per-tree spend is approximated by the committed token budget
// of the tree's dispatched work orders — the orders whose `context.tree_id`
// matches and that have left `pending` (i.e. were gated through / dispatched).
// `budget_tokens` is the per-order ceiling agreed at dispatch; summing it gives
// a conservative upper bound on what the tree has spent, which is exactly what a
// budget breaker wants (fail safe / over-count rather than under-count).
export async function treeSpentTokens(
  userId: string,
  treeId: string
): Promise<number> {
  const rows = await db
    .select({
      spent: sql<number>`coalesce(sum(${work_orders.budget_tokens}), 0)`,
    })
    .from(work_orders)
    .where(
      and(
        eq(work_orders.user_id, userId),
        sql`${work_orders.context} ->> 'tree_id' = ${treeId}`,
        sql`${work_orders.status} <> 'pending'`
      )
    );

  return Number(rows[0]?.spent ?? 0);
}

// US-031: the per-tree token ceiling for a user, read from their evolution
// config (`user_settings.evolution.perTreeBudgetTokens`). Falls back to the
// schema default when the user has no settings row / block. The dispatch and
// suggester gates pass this into `checkBudget` for per-tree enforcement.
export async function readPerTreeBudgetTokens(userId: string): Promise<number> {
  const rows = await db
    .select({ settings: user_settings.settings })
    .from(user_settings)
    .where(eq(user_settings.user_id, userId))
    .limit(1);

  const config = readEvolutionConfig(
    rows[0]?.settings as Record<string, unknown> | null | undefined
  );
  return config.perTreeBudgetTokens;
}
