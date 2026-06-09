import { describe, it, expect, vi, beforeEach } from "vitest";

// ── Mocks ─────────────────────────────────────────────────────────────────────

// `vi.hoisted` keeps these initialized before the hoisted vi.mock factories and
// the static import of "../suggester" below eagerly evaluate them.
const mockDb = vi.hoisted(() => ({
  select: vi.fn(),
  insert: vi.fn(),
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

const mockReadProgress = vi.hoisted(() => vi.fn().mockResolvedValue(null));
vi.mock("@/lib/connectors/claude-code", () => ({
  readProgress: mockReadProgress,
}));

import { generateSuggestions } from "../suggester";
import {
  DEFAULT_EVOLUTION_CONFIG,
  type EvolutionConfig,
} from "@/lib/settings/evolution";

// US-021: the Suggester now skips entirely unless the user's evolution config is
// enabled. These tests exercise the LLM path, so they all run with an enabled
// config injected.
const ENABLED_CONFIG: EvolutionConfig = {
  ...DEFAULT_EVOLUTION_CONFIG,
  enabled: true,
};

// ── Query-builder stubs ─────────────────────────────────────────────────────────
// Each drizzle read is a thenable builder; these stub just the methods our
// helper calls, resolving the chain to `result`.

function selectChain(result: unknown[]) {
  return {
    from: vi.fn().mockReturnThis(),
    innerJoin: vi.fn().mockReturnThis(),
    where: vi.fn().mockReturnThis(),
    orderBy: vi.fn().mockReturnThis(),
    limit: vi.fn().mockResolvedValue(result),
  };
}

function insertChain(result: unknown[]) {
  return {
    values: vi.fn().mockReturnThis(),
    returning: vi.fn().mockResolvedValue(result),
  };
}

const USER_ID = "00000000-0000-0000-0000-000000000001";
const NODE_ID = "11111111-1111-1111-1111-111111111111";

// summarizeTrees runs first (select #1), summarizeRecentMemos second (select
// #2). Wire both reads in call order.
function wireReads(nodes: unknown[], memoRows: unknown[]) {
  mockDb.select
    .mockReturnValueOnce(selectChain(nodes))
    .mockReturnValueOnce(selectChain(memoRows));
}

const treeNodeRow = {
  nodeId: NODE_ID,
  treeTitle: "Ship Agent OS",
  nodeTitle: "Wire the Suggester",
  kind: "leaf",
  status: "growing",
  heat: 4.2,
};

const memoRow = {
  body: "Spent the morning sketching the Gateway loop.",
  created_at: new Date("2026-06-09T08:00:00.000Z"),
};

beforeEach(() => {
  vi.clearAllMocks();
  mockReadProgress.mockResolvedValue(null);
  mockLogPrompt.mockResolvedValue(undefined);
});

describe("generateSuggestions", () => {
  it("validates LLM output and persists suggestions to task_suggestions", async () => {
    wireReads([treeNodeRow], [memoRow]);

    const inserted = insertChain([
      {
        id: "row-1",
        user_id: USER_ID,
        tree_node_id: NODE_ID,
        title: "Finish suggester.ts",
        rationale: "Continues the open leaf node.",
        estimate: "1h",
        suggested_target: "self",
        status: "open",
      },
    ]);
    mockDb.insert.mockReturnValue(inserted);

    mockChat.mockResolvedValue({
      content: JSON.stringify({
        suggestions: [
          {
            title: "Finish suggester.ts",
            rationale: "Continues the open leaf node.",
            linked_node_id: NODE_ID,
            estimate: "1h",
            suggested_target: "self",
          },
        ],
      }),
      tokens_in: 120,
      tokens_out: 45,
      model: "qwen-plus",
    });

    const result = await generateSuggestions({ userId: USER_ID, evolutionConfig: ENABLED_CONFIG });

    expect(result.degraded).toBe(false);
    expect(result.suggestions).toHaveLength(1);
    expect(result.tokens_in).toBe(120);
    expect(result.tokens_out).toBe(45);

    // Persisted the validated row, mapping linked_node_id → tree_node_id.
    expect(mockDb.insert).toHaveBeenCalledTimes(1);
    const valuesArg = inserted.values.mock.calls[0][0];
    expect(valuesArg).toEqual([
      {
        user_id: USER_ID,
        tree_node_id: NODE_ID,
        title: "Finish suggester.ts",
        rationale: "Continues the open leaf node.",
        estimate: "1h",
        suggested_target: "self",
      },
    ]);

    // prompt_log written with user_id + token counts.
    expect(mockLogPrompt).toHaveBeenCalledWith(
      expect.objectContaining({
        kind: "chat",
        user_id: USER_ID,
        tokens_in: 120,
        tokens_out: 45,
      })
    );
  });

  it("drops a hallucinated linked_node_id to null", async () => {
    wireReads([treeNodeRow], [memoRow]);
    const inserted = insertChain([{ id: "row-1" }]);
    mockDb.insert.mockReturnValue(inserted);

    mockChat.mockResolvedValue({
      content: JSON.stringify({
        suggestions: [
          {
            title: "Unrelated task",
            rationale: "Made up a node id.",
            linked_node_id: "99999999-9999-9999-9999-999999999999",
          },
        ],
      }),
      tokens_in: 10,
      tokens_out: 5,
      model: "qwen-plus",
    });

    await generateSuggestions({ userId: USER_ID, evolutionConfig: ENABLED_CONFIG });

    const valuesArg = inserted.values.mock.calls[0][0];
    expect(valuesArg[0].tree_node_id).toBeNull();
    expect(valuesArg[0].estimate).toBeNull();
    expect(valuesArg[0].suggested_target).toBeNull();
  });

  it("retries once on invalid JSON, then succeeds", async () => {
    wireReads([treeNodeRow], [memoRow]);
    const inserted = insertChain([{ id: "row-1" }]);
    mockDb.insert.mockReturnValue(inserted);

    mockChat
      .mockResolvedValueOnce({
        content: "not json at all {{{",
        tokens_in: 8,
        tokens_out: 2,
        model: "qwen-plus",
      })
      .mockResolvedValueOnce({
        content: JSON.stringify({
          suggestions: [{ title: "Recovered", rationale: "Second try parsed." }],
        }),
        tokens_in: 100,
        tokens_out: 30,
        model: "qwen-plus",
      });

    const result = await generateSuggestions({ userId: USER_ID, evolutionConfig: ENABLED_CONFIG });

    expect(mockChat).toHaveBeenCalledTimes(2);
    expect(result.degraded).toBe(false);
    expect(result.suggestions).toHaveLength(1);
    // Tokens accumulate across both attempts.
    expect(result.tokens_in).toBe(108);
    expect(result.tokens_out).toBe(32);
  });

  it("degrades to empty array after two invalid JSON replies and logs the error", async () => {
    wireReads([treeNodeRow], [memoRow]);

    const errSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    mockChat.mockResolvedValue({
      content: "still not json",
      tokens_in: 5,
      tokens_out: 1,
      model: "qwen-plus",
    });

    const result = await generateSuggestions({ userId: USER_ID, evolutionConfig: ENABLED_CONFIG });

    expect(mockChat).toHaveBeenCalledTimes(2);
    expect(result.degraded).toBe(true);
    expect(result.suggestions).toEqual([]);
    // Never attempted to insert when degraded.
    expect(mockDb.insert).not.toHaveBeenCalled();
    // Token usage still logged.
    expect(mockLogPrompt).toHaveBeenCalledWith(
      expect.objectContaining({ user_id: USER_ID })
    );
    expect(errSpy).toHaveBeenCalled();
    errSpy.mockRestore();
  });

  it("degrades when the LLM call throws (network/provider error)", async () => {
    wireReads([treeNodeRow], [memoRow]);

    const errSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    mockChat.mockRejectedValue(new Error("network down"));

    const result = await generateSuggestions({ userId: USER_ID, evolutionConfig: ENABLED_CONFIG });

    expect(mockChat).toHaveBeenCalledTimes(2);
    expect(result.degraded).toBe(true);
    expect(result.suggestions).toEqual([]);
    expect(mockDb.insert).not.toHaveBeenCalled();
    errSpy.mockRestore();
  });

  it("folds Claude Code progress into the prompt when a project is given", async () => {
    wireReads([treeNodeRow], [memoRow]);
    const inserted = insertChain([{ id: "row-1" }]);
    mockDb.insert.mockReturnValue(inserted);

    mockReadProgress.mockResolvedValue({
      project: "/Users/me/dev/daypage",
      summary: "User: implement US-009\n\nAssistant: wrote suggester.ts",
      lastActivityAt: "2026-06-09T09:00:00.000Z",
    });

    mockChat.mockResolvedValue({
      content: JSON.stringify({
        suggestions: [{ title: "Review the diff", rationale: "CC just wrote code." }],
      }),
      tokens_in: 50,
      tokens_out: 20,
      model: "qwen-plus",
    });

    await generateSuggestions({
      userId: USER_ID,
      project: "/Users/me/dev/daypage",
      claudeHome: "/tmp/claude",
      evolutionConfig: ENABLED_CONFIG,
    });

    expect(mockReadProgress).toHaveBeenCalledWith({
      project: "/Users/me/dev/daypage",
      claudeHome: "/tmp/claude",
    });
    // The CC digest must reach the user prompt.
    const [messages] = mockChat.mock.calls[0];
    const userMsg = messages.find(
      (m: { role: string }) => m.role === "user"
    ) as { content: string };
    expect(userMsg.content).toContain("wrote suggester.ts");
  });

  it("skips entirely (no LLM call) when the evolution config is disabled", async () => {
    const result = await generateSuggestions({
      userId: USER_ID,
      evolutionConfig: { ...DEFAULT_EVOLUTION_CONFIG, enabled: false },
    });

    expect(result.skipped).toBe(true);
    expect(result.suggestions).toEqual([]);
    expect(result.perTreeBudgetTokens).toBe(
      DEFAULT_EVOLUTION_CONFIG.perTreeBudgetTokens
    );
    // No model call, no DB read/write when disabled.
    expect(mockChat).not.toHaveBeenCalled();
    expect(mockDb.select).not.toHaveBeenCalled();
    expect(mockDb.insert).not.toHaveBeenCalled();
  });

  it("defaults to disabled (skips) when no evolution config is given", async () => {
    const result = await generateSuggestions({ userId: USER_ID });

    expect(result.skipped).toBe(true);
    expect(mockChat).not.toHaveBeenCalled();
  });

  it("handles an empty suggestion list without inserting", async () => {
    wireReads([], []);
    mockChat.mockResolvedValue({
      content: JSON.stringify({ suggestions: [] }),
      tokens_in: 30,
      tokens_out: 4,
      model: "qwen-plus",
    });

    const result = await generateSuggestions({ userId: USER_ID, evolutionConfig: ENABLED_CONFIG });

    expect(result.degraded).toBe(false);
    expect(result.suggestions).toEqual([]);
    expect(mockDb.insert).not.toHaveBeenCalled();
  });
});
