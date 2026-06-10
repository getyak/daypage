import { describe, it, expect, vi, beforeEach } from "vitest";

// ── Mocks ─────────────────────────────────────────────────────────────────────

const mockTree = {
  id: "tree-uuid-1",
  user_id: "user-uuid-1",
  title: "Learn Rust",
  status: "active" as const,
  created_at: new Date("2026-01-01T00:00:00Z"),
};

const mockNode = {
  id: "node-uuid-1",
  tree_id: "tree-uuid-1",
  parent_id: null,
  kind: "goal" as const,
  status: "growing" as const,
  title: "Master ownership",
  heat: 1,
  evidence_memo_ids: [],
  page_id: null,
  created_at: new Date("2026-01-01T00:00:00Z"),
  updated_at: new Date("2026-01-01T00:00:00Z"),
};

// `vi.hoisted` keeps mockDb initialized before the hoisted vi.mock factory and
// the static `import { ... } from "../repo"` below eagerly evaluate it.
const mockDb = vi.hoisted(() => ({
  select: vi.fn(),
  insert: vi.fn(),
}));
vi.mock("@/lib/db/client", () => ({ db: mockDb }));

vi.mock("@/lib/db/schema", async (importOriginal) => {
  const real = await importOriginal<typeof import("@/lib/db/schema")>();
  return { ...real };
});

import {
  createTree,
  listTrees,
  getTree,
  listNodes,
  getTreeWithDiff,
} from "../repo";

// ── Helpers ───────────────────────────────────────────────────────────────────

// Build a thenable chain that resolves to `result` and supports the drizzle
// builder methods the repo uses (from/where/limit/orderBy).
function selectChain(result: unknown[]) {
  const p = Promise.resolve(result);
  return Object.assign(p, {
    from: vi.fn().mockReturnThis(),
    where: vi.fn().mockReturnThis(),
    limit: vi.fn().mockResolvedValue(result),
    orderBy: vi.fn().mockResolvedValue(result),
  });
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("trees repo", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  describe("createTree", () => {
    it("inserts a trimmed title scoped to the user and returns the row", async () => {
      const insertChain = Promise.resolve([mockTree]);
      const valuesSpy = vi.fn().mockReturnThis();
      mockDb.insert.mockReturnValue(
        Object.assign(insertChain, {
          values: valuesSpy,
          returning: vi.fn().mockResolvedValue([mockTree]),
        })
      );

      const result = await createTree({
        user_id: "user-uuid-1",
        title: "  Learn Rust  ",
      });

      expect(result).toEqual(mockTree);
      expect(valuesSpy).toHaveBeenCalledWith({
        user_id: "user-uuid-1",
        title: "Learn Rust",
      });
    });
  });

  describe("listTrees", () => {
    it("returns the user's trees", async () => {
      mockDb.select.mockReturnValue(selectChain([mockTree]));

      const result = await listTrees("user-uuid-1");
      expect(result).toEqual([mockTree]);
      expect(mockDb.select).toHaveBeenCalledOnce();
    });

    it("returns an empty list for a fresh user", async () => {
      mockDb.select.mockReturnValue(selectChain([]));

      const result = await listTrees("user-uuid-2");
      expect(result).toEqual([]);
    });
  });

  describe("getTree", () => {
    it("returns the tree when owned by the user", async () => {
      mockDb.select.mockReturnValue(selectChain([mockTree]));

      const result = await getTree("user-uuid-1", "tree-uuid-1");
      expect(result).toEqual(mockTree);
    });

    it("returns null when the tree is missing or not owned", async () => {
      mockDb.select.mockReturnValue(selectChain([]));

      const result = await getTree("user-uuid-1", "tree-uuid-x");
      expect(result).toBeNull();
    });
  });

  describe("listNodes", () => {
    it("returns nodes for an owned tree", async () => {
      // First select resolves the ownership check (getTree), second the nodes.
      mockDb.select
        .mockReturnValueOnce(selectChain([mockTree]))
        .mockReturnValueOnce(selectChain([mockNode]));

      const result = await listNodes("user-uuid-1", "tree-uuid-1");
      expect(result).toEqual([mockNode]);
      expect(mockDb.select).toHaveBeenCalledTimes(2);
    });

    it("returns an empty list (never another user's nodes) for an unowned tree", async () => {
      // Ownership check fails → no second query for nodes.
      mockDb.select.mockReturnValueOnce(selectChain([]));

      const result = await listNodes("user-uuid-1", "tree-uuid-other");
      expect(result).toEqual([]);
      expect(mockDb.select).toHaveBeenCalledOnce();
    });
  });

  describe("getTreeWithDiff", () => {
    // Fixed "now" so the 7-day window is deterministic.
    const now = new Date("2026-01-10T00:00:00Z");

    it("classifies nodes into added / changed within the past 7 days", async () => {
      const addedNode = {
        ...mockNode,
        id: "node-added",
        created_at: new Date("2026-01-08T00:00:00Z"), // in window → added
        updated_at: new Date("2026-01-08T00:00:00Z"),
      };
      const changedNode = {
        ...mockNode,
        id: "node-changed",
        created_at: new Date("2025-12-01T00:00:00Z"), // old create
        updated_at: new Date("2026-01-09T00:00:00Z"), // recent update → changed
      };
      const staleNode = {
        ...mockNode,
        id: "node-stale",
        created_at: new Date("2025-11-01T00:00:00Z"),
        updated_at: new Date("2025-11-01T00:00:00Z"), // neither
      };

      mockDb.select
        .mockReturnValueOnce(selectChain([mockTree])) // ownership check
        .mockReturnValueOnce(selectChain([addedNode, changedNode, staleNode]));

      const result = await getTreeWithDiff("user-uuid-1", "tree-uuid-1", now);
      expect(result).not.toBeNull();
      expect(result!.tree).toEqual(mockTree);
      expect(result!.nodes).toHaveLength(3);
      expect(result!.diff.added_node_ids).toEqual(["node-added"]);
      expect(result!.diff.changed_node_ids).toEqual(["node-changed"]);
      // added and changed are disjoint sets.
      expect(result!.diff.added_node_ids).not.toContain("node-changed");
      expect(result!.diff.since).toBe("2026-01-03T00:00:00.000Z");
    });

    it("returns null for a missing or unowned tree", async () => {
      mockDb.select.mockReturnValueOnce(selectChain([]));

      const result = await getTreeWithDiff("user-uuid-1", "tree-uuid-x", now);
      expect(result).toBeNull();
      expect(mockDb.select).toHaveBeenCalledOnce();
    });
  });
});
