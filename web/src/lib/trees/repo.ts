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
