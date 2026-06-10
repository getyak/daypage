import { describe, it, expect, vi, beforeEach } from "vitest";

// ── Mocks ─────────────────────────────────────────────────────────────────────
// `vi.hoisted` keeps these initialized before the hoisted vi.mock factories and
// the static import of "../evolver" below eagerly evaluate them.

const mockDb = vi.hoisted(() => ({
  select: vi.fn(),
  insert: vi.fn(),
  update: vi.fn(),
}));
vi.mock("@/lib/db/client", () => ({ db: mockDb }));

vi.mock("@/lib/db/schema", async (importOriginal) => {
  const real = await importOriginal<typeof import("@/lib/db/schema")>();
  return { ...real };
});

const mockChat = vi.hoisted(() => vi.fn());
vi.mock("@/lib/ai/dashscope", () => ({
  dashscope: { chat: mockChat },
}));

const mockLogPrompt = vi.hoisted(() => vi.fn().mockResolvedValue(undefined));
vi.mock("@/lib/ai/prompt-log", () => ({ logPrompt: mockLogPrompt }));

import {
  evolveTree,
  liveEvolveTreeDeps,
  EVOLVE_MIN_EVIDENCE,
  type EvolveTreeDeps,
  type TreeObservation,
  type NodeObservation,
} from "../evolver";

const USER_ID = "00000000-0000-0000-0000-000000000001";
const TREE_ID = "22222222-2222-2222-2222-222222222222";
const NODE_ID = "11111111-1111-1111-1111-111111111111";

beforeEach(() => {
  vi.clearAllMocks();
  vi.spyOn(console, "warn").mockImplementation(() => {});
  vi.spyOn(console, "error").mockImplementation(() => {});
});

// ── Fixtures ────────────────────────────────────────────────────────────────────

function makeNode(over: Partial<NodeObservation> = {}): NodeObservation {
  return {
    node_id: NODE_ID,
    parent_id: null,
    kind: "goal",
    status: "growing",
    title: "Learn Rust",
    heat: 5,
    page_id: null,
    evidence_count: EVOLVE_MIN_EVIDENCE + 1,
    ...over,
  };
}

function makeObs(over: Partial<TreeObservation> = {}): TreeObservation {
  return {
    tree_id: TREE_ID,
    user_id: USER_ID,
    title: "Rust mastery",
    candidates: [makeNode()],
    ...over,
  };
}

function makeDeps(over: Partial<EvolveTreeDeps> = {}): EvolveTreeDeps {
  return {
    observe: vi.fn(async () => makeObs()),
    plan: vi.fn(async () => ({
      decisions: [],
      tokens_in: 0,
      tokens_out: 0,
      degraded: false,
    })),
    growBranch: vi.fn(async () => ({ new_node_id: "new-1", linked: false })),
    markMature: vi.fn(async () => ({ suggestion_id: "sug-1" })),
    ...over,
  };
}

// ── Core loop (dependency-injected) ─────────────────────────────────────────────

describe("evolveTree (core loop)", () => {
  it("grows a new branch when the plan says grow_branch", async () => {
    const deps = makeDeps({
      plan: vi.fn(async () => ({
        decisions: [
          {
            node_id: NODE_ID,
            action: "grow_branch" as const,
            branch_title: "Async runtimes",
            rationale: "Accumulated tokio notes warrant their own branch",
          },
        ],
        tokens_in: 100,
        tokens_out: 20,
        degraded: false,
      })),
    });

    const res = await evolveTree(deps, { treeId: TREE_ID });

    expect(deps.growBranch).toHaveBeenCalledOnce();
    expect(deps.growBranch).toHaveBeenCalledWith(
      expect.objectContaining({
        branchTitle: "Async runtimes",
        parent: expect.objectContaining({ node_id: NODE_ID }),
      })
    );
    expect(deps.markMature).not.toHaveBeenCalled();
    expect(res.grown).toBe(1);
    expect(res.matured).toBe(0);
    expect(res.actions).toEqual([
      {
        action: "grow_branch",
        node_id: NODE_ID,
        new_node_id: "new-1",
        linked: false,
      },
    ]);
    expect(res.tokens_in).toBe(100);
  });

  it("marks a node mature (and suggests) when the plan says mark_mature", async () => {
    const deps = makeDeps({
      plan: vi.fn(async () => ({
        decisions: [
          {
            node_id: NODE_ID,
            action: "mark_mature" as const,
            rationale: "Pursuit saturated",
          },
        ],
        tokens_in: 0,
        tokens_out: 0,
        degraded: false,
      })),
    });

    const res = await evolveTree(deps, { treeId: TREE_ID });

    expect(deps.markMature).toHaveBeenCalledOnce();
    expect(deps.growBranch).not.toHaveBeenCalled();
    expect(res.matured).toBe(1);
    expect(res.actions).toEqual([
      { action: "mark_mature", node_id: NODE_ID, suggestion_id: "sug-1" },
    ]);
  });

  it("drops a grow_branch decision with no usable title", async () => {
    const deps = makeDeps({
      plan: vi.fn(async () => ({
        decisions: [
          {
            node_id: NODE_ID,
            action: "grow_branch" as const,
            branch_title: "   ",
            rationale: "no title",
          },
        ],
        tokens_in: 0,
        tokens_out: 0,
        degraded: false,
      })),
    });

    const res = await evolveTree(deps, { treeId: TREE_ID });
    expect(deps.growBranch).not.toHaveBeenCalled();
    expect(res.grown).toBe(0);
  });

  it("ignores decisions about nodes that were never offered", async () => {
    const deps = makeDeps({
      plan: vi.fn(async () => ({
        decisions: [
          {
            node_id: "hallucinated-node",
            action: "grow_branch" as const,
            branch_title: "ghost",
            rationale: "hallucinated",
          },
        ],
        tokens_in: 0,
        tokens_out: 0,
        degraded: false,
      })),
    });

    const res = await evolveTree(deps, { treeId: TREE_ID });
    expect(deps.growBranch).not.toHaveBeenCalled();
    expect(res.grown).toBe(0);
  });

  it("no-ops cleanly when the tree is not found", async () => {
    const deps = makeDeps({ observe: vi.fn(async () => null) });
    const res = await evolveTree(deps, { treeId: TREE_ID });
    expect(deps.plan).not.toHaveBeenCalled();
    expect(res).toMatchObject({
      observed: 0,
      grown: 0,
      matured: 0,
      actions: [],
    });
  });

  it("does not re-mature a node that is already mature", async () => {
    const deps = makeDeps({
      observe: vi.fn(async () =>
        makeObs({ candidates: [makeNode({ status: "mature" })] })
      ),
      plan: vi.fn(async () => ({
        decisions: [
          { node_id: NODE_ID, action: "mark_mature" as const, rationale: "x" },
        ],
        tokens_in: 0,
        tokens_out: 0,
        degraded: false,
      })),
    });

    const res = await evolveTree(deps, { treeId: TREE_ID });
    expect(deps.markMature).not.toHaveBeenCalled();
    expect(res.matured).toBe(0);
  });
});

// ── Live deps (mocked LLM) — verify a grown branch lands in the DB ──────────────

// A drizzle read builder whose chain resolves to `result`.
function insertChain(result: unknown[]) {
  return {
    values: vi.fn().mockReturnThis(),
    returning: vi.fn().mockResolvedValue(result),
  };
}

describe("liveEvolveTreeDeps.plan (mocked LLM)", () => {
  it("parses a grow_branch decision from the LLM and logs the prompt", async () => {
    mockChat.mockResolvedValueOnce({
      content: JSON.stringify({
        decisions: [
          {
            node_id: NODE_ID,
            action: "grow_branch",
            branch_title: "Async runtimes",
            rationale: "Enough tokio evidence to branch",
          },
        ],
      }),
      tokens_in: 120,
      tokens_out: 30,
      model: "qwen-plus",
    });

    const obs = makeObs();
    const result = await liveEvolveTreeDeps.plan(obs);

    expect(mockChat).toHaveBeenCalledOnce();
    expect(result.degraded).toBe(false);
    expect(result.decisions).toHaveLength(1);
    expect(result.decisions[0]).toMatchObject({
      node_id: NODE_ID,
      action: "grow_branch",
      branch_title: "Async runtimes",
    });
    expect(result.tokens_in).toBe(120);
    // token usage attributed to the tree owner for per-user budgeting
    expect(mockLogPrompt).toHaveBeenCalledWith(
      expect.objectContaining({ kind: "chat", user_id: USER_ID })
    );
  });

  it("degrades to a no-op plan after a retry when the LLM returns junk", async () => {
    mockChat.mockResolvedValue({
      content: "not json at all",
      tokens_in: 10,
      tokens_out: 5,
      model: "qwen-plus",
    });

    const result = await liveEvolveTreeDeps.plan(makeObs());

    expect(mockChat).toHaveBeenCalledTimes(2); // attempt + one retry
    expect(result.degraded).toBe(true);
    expect(result.decisions).toEqual([]);
  });

  it("skips the LLM entirely when there are no candidates", async () => {
    const result = await liveEvolveTreeDeps.plan(makeObs({ candidates: [] }));
    expect(mockChat).not.toHaveBeenCalled();
    expect(result).toMatchObject({ decisions: [], degraded: false });
  });
});

describe("liveEvolveTreeDeps.growBranch (DB writes)", () => {
  it("inserts a new branch tree_node and writes a change_log row", async () => {
    const treeNodeInsert = insertChain([{ id: "branch-1", page_id: null }]);
    const changeLogInsert = insertChain([]);
    const queue = [treeNodeInsert, changeLogInsert];
    mockDb.insert.mockImplementation(() => queue.shift());

    const obs = makeObs();
    const parent = makeNode();
    const res = await liveEvolveTreeDeps.growBranch({
      obs,
      parent,
      branchTitle: "Async runtimes",
      rationale: "branch worthy",
    });

    // a new branch node was inserted with the right shape
    expect(treeNodeInsert.values).toHaveBeenCalledWith(
      expect.objectContaining({
        tree_id: TREE_ID,
        parent_id: NODE_ID,
        kind: "branch",
        status: "growing",
        title: "Async runtimes",
      })
    );
    // change_log captured the grow
    expect(changeLogInsert.values).toHaveBeenCalledWith(
      expect.objectContaining({
        user_id: USER_ID,
        action_kind: "evolve_grow_branch",
        target_type: "tree_node",
        target_id: "branch-1",
        performed_by: "agent",
      })
    );
    // no parent page → no page_link, so only tree_nodes + change_log inserts
    expect(mockDb.insert).toHaveBeenCalledTimes(2);
    expect(res).toEqual({ new_node_id: "branch-1", linked: false });
  });

  it("creates a page_link when both parent and new node carry pages", async () => {
    const treeNodeInsert = insertChain([
      { id: "branch-2", page_id: "child-page" },
    ]);
    const pageLinkInsert = insertChain([]);
    const changeLogInsert = insertChain([]);
    const queue = [treeNodeInsert, pageLinkInsert, changeLogInsert];
    mockDb.insert.mockImplementation(() => queue.shift());

    const obs = makeObs();
    const parent = makeNode({ page_id: "parent-page" });
    const res = await liveEvolveTreeDeps.growBranch({
      obs,
      parent,
      branchTitle: "Async runtimes",
      rationale: "branch worthy",
    });

    expect(pageLinkInsert.values).toHaveBeenCalledWith(
      expect.objectContaining({
        user_id: USER_ID,
        from_page_id: "parent-page",
        to_page_id: "child-page",
      })
    );
    expect(res).toEqual({ new_node_id: "branch-2", linked: true });
  });
});

describe("liveEvolveTreeDeps.markMature (DB writes)", () => {
  it("sets status=mature, emits a suggestion, and logs both to change_log", async () => {
    const updateChain = {
      set: vi.fn().mockReturnThis(),
      where: vi.fn().mockResolvedValue(undefined),
    };
    mockDb.update.mockReturnValue(updateChain);

    const changeLog1 = insertChain([]);
    const suggestionInsert = insertChain([{ id: "sug-99" }]);
    const changeLog2 = insertChain([]);
    const queue = [changeLog1, suggestionInsert, changeLog2];
    mockDb.insert.mockImplementation(() => queue.shift());

    const obs = makeObs();
    const node = makeNode();
    const res = await liveEvolveTreeDeps.markMature({
      obs,
      node,
      rationale: "saturated",
    });

    expect(updateChain.set).toHaveBeenCalledWith(
      expect.objectContaining({ status: "mature" })
    );
    // suggestion linked to the matured node
    expect(suggestionInsert.values).toHaveBeenCalledWith(
      expect.objectContaining({
        user_id: USER_ID,
        tree_node_id: NODE_ID,
        rationale: "saturated",
      })
    );
    expect(res).toEqual({ suggestion_id: "sug-99" });
    // two change_log rows: mark_mature + suggest_mature
    expect(mockDb.insert).toHaveBeenCalledTimes(3);
  });
});
