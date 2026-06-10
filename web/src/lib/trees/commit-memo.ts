import { db } from "@/lib/db/client";
import { tree_nodes, trees, pages, change_log } from "@/lib/db/schema";
import { eq, sql } from "drizzle-orm";

// US-018: Compiler 升级 — memo commit 进树.
//
// After a memo is compiled into pages, we also try to "commit" it onto the most
// relevant task-tree node (Git-style task tree, US-001). A tree_node links to a
// compiled wiki `page` via `page_id`; we measure relevance by the cosine
// similarity between the memo's embedding and those linked pages' embeddings
// (native pgvector ANN). On a hit within the distance threshold we:
//   - append memo_id to the node's `evidence_memo_ids`
//   - bump the node's `heat`
//   - write a `change_log` row recording the commit
// On no hit (no embedded nodes, or best distance over threshold) we skip
// silently — the memo still compiled into pages normally. This is best-effort:
// it must never roll back an already-compiled page.

// Heat increment applied to a node when a memo is committed onto it.
export const COMMIT_HEAT_INCREMENT = 1;

// Max cosine distance (pgvector `<=>`, range 0..2) for a node to count as a
// match. 0 = identical, 1 = orthogonal. We require a reasonably strong match so
// unrelated memos don't pollute the tree.
export const COMMIT_MATCH_MAX_DISTANCE = 0.6;

export type TreeNodeMatch = {
  node_id: string;
  tree_id: string;
  page_id: string;
  distance: number;
  evidence_memo_ids: string[];
};

export type CommitMemoToTreeResult =
  | { committed: false; reason: "no-embedding" | "no-match" }
  | { committed: true; node_id: string; tree_id: string; heat_to: number };

// Injectable dependencies so the pipeline is unit-testable without a live DB.
export interface CommitMemoTreeDeps {
  // Best (nearest) tree_node for this user whose linked page is similar to the
  // memo embedding, or null when there is no embedded candidate node within
  // the distance threshold.
  findBestTreeNode: (args: {
    userId: string;
    embedding: number[];
  }) => Promise<TreeNodeMatch | null>;
  // Append memo_id to the node's evidence and bump its heat. Returns the new
  // heat value.
  commitToNode: (args: {
    nodeId: string;
    memoId: string;
    evidenceMemoIds: string[];
    heatIncrement: number;
  }) => Promise<{ heat: number }>;
  // Record the commit in the audit trail.
  recordChangeLog: (args: {
    userId: string;
    memoId: string;
    nodeId: string;
    distance: number;
    heatTo: number;
  }) => Promise<void>;
}

// Core pipeline (dependency-injected). Never throws on a "no match" path; the
// caller (compile-memo step) wraps it so any unexpected error is logged as a
// warning and does not roll back the compiled page.
export async function commitMemoToTree(
  deps: CommitMemoTreeDeps,
  args: { userId: string; memoId: string; embedding: number[] | null }
): Promise<CommitMemoToTreeResult> {
  const { userId, memoId, embedding } = args;

  if (!embedding || embedding.length === 0) {
    return { committed: false, reason: "no-embedding" };
  }

  const match = await deps.findBestTreeNode({ userId, embedding });
  if (!match) {
    return { committed: false, reason: "no-match" };
  }

  // Skip if already cited — keep evidence_memo_ids a set, no double heat.
  if (match.evidence_memo_ids.includes(memoId)) {
    return { committed: false, reason: "no-match" };
  }

  const { heat } = await deps.commitToNode({
    nodeId: match.node_id,
    memoId,
    evidenceMemoIds: match.evidence_memo_ids,
    heatIncrement: COMMIT_HEAT_INCREMENT,
  });

  await deps.recordChangeLog({
    userId,
    memoId,
    nodeId: match.node_id,
    distance: match.distance,
    heatTo: heat,
  });

  return {
    committed: true,
    node_id: match.node_id,
    tree_id: match.tree_id,
    heat_to: heat,
  };
}

// ─── Production deps (real Drizzle/pgvector) ────────────────────────────────────

export const liveCommitMemoTreeDeps: CommitMemoTreeDeps = {
  async findBestTreeNode({ userId, embedding }) {
    const memoLiteral = `[${embedding.join(",")}]`;

    // Nearest tree_node (via its linked page's embedding) for this user, within
    // the distance threshold. tree_nodes have no user_id — scope through the
    // owning tree. Only nodes with a linked, embedded page are candidates.
    const rows = await db.execute<{
      node_id: string;
      tree_id: string;
      page_id: string;
      distance: number;
      evidence_memo_ids: unknown;
    }>(sql`
      SELECT
        ${tree_nodes.id} AS node_id,
        ${tree_nodes.tree_id} AS tree_id,
        ${tree_nodes.page_id} AS page_id,
        (${pages.embedding} <=> ${memoLiteral}::vector) AS distance,
        ${tree_nodes.evidence_memo_ids} AS evidence_memo_ids
      FROM ${tree_nodes}
      JOIN ${trees} ON ${trees.id} = ${tree_nodes.tree_id}
      JOIN ${pages} ON ${pages.id} = ${tree_nodes.page_id}
      WHERE ${trees.user_id} = ${userId}
        AND ${pages.embedding} IS NOT NULL
      ORDER BY ${pages.embedding} <=> ${memoLiteral}::vector
      LIMIT 1
    `);

    const best = rows[0];
    if (!best) return null;
    if (Number(best.distance) > COMMIT_MATCH_MAX_DISTANCE) return null;

    const evidence = Array.isArray(best.evidence_memo_ids)
      ? (best.evidence_memo_ids as string[])
      : [];

    return {
      node_id: best.node_id,
      tree_id: best.tree_id,
      page_id: best.page_id,
      distance: Number(best.distance),
      evidence_memo_ids: evidence,
    };
  },

  async commitToNode({ nodeId, memoId, evidenceMemoIds, heatIncrement }) {
    const nextEvidence = [...evidenceMemoIds, memoId];
    const [updated] = await db
      .update(tree_nodes)
      .set({
        evidence_memo_ids: nextEvidence,
        heat: sql`${tree_nodes.heat} + ${heatIncrement}`,
        updated_at: new Date(),
      })
      .where(eq(tree_nodes.id, nodeId))
      .returning({ heat: tree_nodes.heat });

    return { heat: updated?.heat ?? 0 };
  },

  async recordChangeLog({ userId, memoId, nodeId, distance, heatTo }) {
    await db.insert(change_log).values({
      user_id: userId,
      action_kind: "commit_memo_to_tree",
      target_type: "tree_node",
      target_id: nodeId,
      before: null,
      after: { memo_id: memoId, distance, heat: heatTo },
      reason: null,
      performed_by: "agent",
      agent_action_id: memoId,
    });
  },
};
