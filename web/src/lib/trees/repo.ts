import "server-only";
import { db } from "@/lib/db/client";
import { trees, tree_nodes } from "@/lib/db/schema";
import type { Tree, TreeNode } from "@/lib/db/schema";
import { and, eq, desc } from "drizzle-orm";

// Repository for task trees (US-001 Git-style goal evolution). Every function is
// strictly user_id-scoped: a tree belongs to one user, and its tree_nodes are
// scoped transitively through the owning tree (tree_nodes have no direct
// user_id). Callers are responsible for resolving the user_id from the session.

export interface CreateTreeInput {
  user_id: string;
  title: string;
}

// Insert a new active task tree for the given user and return the created row.
export async function createTree(input: CreateTreeInput): Promise<Tree> {
  const [tree] = await db
    .insert(trees)
    .values({
      user_id: input.user_id,
      title: input.title.trim(),
    })
    .returning();
  return tree;
}

// List a user's trees, newest first.
export async function listTrees(userId: string): Promise<Tree[]> {
  return db
    .select()
    .from(trees)
    .where(eq(trees.user_id, userId))
    .orderBy(desc(trees.created_at));
}

// Fetch a single tree by id, scoped to the owning user. Returns null when the
// tree does not exist or belongs to another user.
export async function getTree(
  userId: string,
  treeId: string
): Promise<Tree | null> {
  const [tree] = await db
    .select()
    .from(trees)
    .where(and(eq(trees.id, treeId), eq(trees.user_id, userId)))
    .limit(1);
  return tree ?? null;
}

// List the nodes of a tree, scoped to the owning user. The user_id filter is
// enforced by first confirming the tree belongs to the user; an unowned or
// missing tree yields an empty list (never another user's nodes).
export async function listNodes(
  userId: string,
  treeId: string
): Promise<TreeNode[]> {
  const tree = await getTree(userId, treeId);
  if (!tree) return [];

  return db
    .select()
    .from(tree_nodes)
    .where(eq(tree_nodes.tree_id, treeId))
    .orderBy(desc(tree_nodes.heat), desc(tree_nodes.created_at));
}

// "This week" diff for a tree: node ids created or updated within the last 7
// days. A node counts as `added` when its created_at is in-window; otherwise an
// in-window updated_at marks it as `changed`. The two sets are disjoint so the
// UI can highlight fresh growth (added) distinctly from re-touched nodes
// (changed). Computed in-process over the already user-scoped node list.
export interface TreeWeeklyDiff {
  since: string; // ISO timestamp marking the start of the 7-day window
  added_node_ids: string[];
  changed_node_ids: string[];
}

export interface TreeDetail {
  tree: Tree;
  nodes: TreeNode[];
  diff: TreeWeeklyDiff;
}

// Fetch a tree, its nodes, and the past-7-day diff in one user-scoped read.
// Returns null when the tree does not exist or belongs to another user.
export async function getTreeWithDiff(
  userId: string,
  treeId: string,
  now: Date = new Date()
): Promise<TreeDetail | null> {
  const tree = await getTree(userId, treeId);
  if (!tree) return null;

  const nodes = await db
    .select()
    .from(tree_nodes)
    .where(eq(tree_nodes.tree_id, treeId))
    .orderBy(desc(tree_nodes.heat), desc(tree_nodes.created_at));

  const since = new Date(now.getTime() - 7 * 24 * 60 * 60 * 1000);
  const added_node_ids: string[] = [];
  const changed_node_ids: string[] = [];
  for (const node of nodes) {
    if (node.created_at >= since) {
      added_node_ids.push(node.id);
    } else if (node.updated_at >= since) {
      changed_node_ids.push(node.id);
    }
  }

  return {
    tree,
    nodes,
    diff: { since: since.toISOString(), added_node_ids, changed_node_ids },
  };
}
