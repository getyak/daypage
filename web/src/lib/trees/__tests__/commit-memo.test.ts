import { describe, it, expect, vi, beforeEach } from "vitest";

// commit-memo.ts imports db/client at module load (only used by the live deps,
// which these tests don't exercise). Stub it so no real DATABASE_URL is needed.
vi.mock("@/lib/db/client", () => ({ db: {} }));

import {
  commitMemoToTree,
  COMMIT_HEAT_INCREMENT,
  type CommitMemoTreeDeps,
  type TreeNodeMatch,
} from "@/lib/trees/commit-memo";

function makeMatch(over: Partial<TreeNodeMatch> = {}): TreeNodeMatch {
  return {
    node_id: "node-1",
    tree_id: "tree-1",
    page_id: "page-1",
    distance: 0.2,
    evidence_memo_ids: [],
    ...over,
  };
}

function makeDeps(over: Partial<CommitMemoTreeDeps> = {}): CommitMemoTreeDeps {
  return {
    findBestTreeNode: vi.fn(async () => makeMatch()),
    // Default: simulate heat 5 → 6 after the +1 increment.
    commitToNode: vi.fn(async ({ heatIncrement }) => ({
      heat: 5 + heatIncrement,
    })),
    recordChangeLog: vi.fn(async () => {}),
    ...over,
  };
}

beforeEach(() => {
  vi.restoreAllMocks();
  vi.spyOn(console, "log").mockImplementation(() => {});
  vi.spyOn(console, "warn").mockImplementation(() => {});
});

describe("commitMemoToTree", () => {
  it("commits to the matched node: bumps heat and appends evidence", async () => {
    const deps = makeDeps({
      findBestTreeNode: vi.fn(async () =>
        makeMatch({ node_id: "node-X", evidence_memo_ids: ["m-old"] }),
      ),
    });

    const result = await commitMemoToTree(deps, {
      userId: "user-1",
      memoId: "memo-new",
      embedding: [0.1, 0.2, 0.3],
    });

    // heat raised by COMMIT_HEAT_INCREMENT, prior evidence passed for append
    expect(deps.commitToNode).toHaveBeenCalledWith({
      nodeId: "node-X",
      memoId: "memo-new",
      evidenceMemoIds: ["m-old"],
      heatIncrement: COMMIT_HEAT_INCREMENT,
    });

    // change_log recorded with the resulting heat
    expect(deps.recordChangeLog).toHaveBeenCalledWith({
      userId: "user-1",
      memoId: "memo-new",
      nodeId: "node-X",
      distance: 0.2,
      heatTo: 5 + COMMIT_HEAT_INCREMENT,
    });

    expect(result).toEqual({
      committed: true,
      node_id: "node-X",
      tree_id: "tree-1",
      heat_to: 5 + COMMIT_HEAT_INCREMENT,
    });
  });

  it("passes prior evidence plus the new memo_id to commitToNode", async () => {
    const captured: { evidenceMemoIds: string[]; memoId: string }[] = [];
    const deps = makeDeps({
      findBestTreeNode: vi.fn(async () =>
        makeMatch({ evidence_memo_ids: ["a", "b"] }),
      ),
      commitToNode: vi.fn(async (args) => {
        captured.push({
          evidenceMemoIds: args.evidenceMemoIds,
          memoId: args.memoId,
        });
        return { heat: 1 };
      }),
    });

    await commitMemoToTree(deps, {
      userId: "u",
      memoId: "c",
      embedding: [1, 0],
    });

    expect(captured[0].evidenceMemoIds).toEqual(["a", "b"]);
    expect(captured[0].memoId).toEqual("c");
  });

  it("skips silently when there is no embedding (memo still compiled)", async () => {
    const deps = makeDeps();

    const result = await commitMemoToTree(deps, {
      userId: "u",
      memoId: "m",
      embedding: null,
    });

    expect(result).toEqual({ committed: false, reason: "no-embedding" });
    expect(deps.findBestTreeNode).not.toHaveBeenCalled();
    expect(deps.commitToNode).not.toHaveBeenCalled();
    expect(deps.recordChangeLog).not.toHaveBeenCalled();
  });

  it("skips when no tree node matches (no heat bump, no change_log)", async () => {
    const deps = makeDeps({
      findBestTreeNode: vi.fn(async () => null),
    });

    const result = await commitMemoToTree(deps, {
      userId: "u",
      memoId: "m",
      embedding: [0.5, 0.5],
    });

    expect(result).toEqual({ committed: false, reason: "no-match" });
    expect(deps.commitToNode).not.toHaveBeenCalled();
    expect(deps.recordChangeLog).not.toHaveBeenCalled();
  });

  it("does not double-commit when the memo is already cited as evidence", async () => {
    const deps = makeDeps({
      findBestTreeNode: vi.fn(async () =>
        makeMatch({ evidence_memo_ids: ["memo-dup"] }),
      ),
    });

    const result = await commitMemoToTree(deps, {
      userId: "u",
      memoId: "memo-dup",
      embedding: [0.1],
    });

    expect(result).toEqual({ committed: false, reason: "no-match" });
    expect(deps.commitToNode).not.toHaveBeenCalled();
    expect(deps.recordChangeLog).not.toHaveBeenCalled();
  });
});
