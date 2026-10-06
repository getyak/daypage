import { beforeEach, describe, expect, it, vi } from "vitest";

const { select } = vi.hoisted(() => ({ select: vi.fn() }));
vi.mock("@/lib/db/client", () => ({ db: { select } }));
vi.mock("@/lib/evaluation/config", () => ({
  evaluationConfig: () => ({
    environment: "isolated-test",
    pseudonymSalt: "synthetic-projection-test-salt",
  }),
}));

// Keep the real SDK import so this catches missing runtime exports.
import { buildOpikTraceProjection } from "@/lib/evaluation/opik-exporter";

function queryRows(rows: unknown[]) {
  return {
    from: vi.fn().mockReturnThis(),
    where: vi.fn().mockReturnThis(),
    limit: vi.fn().mockResolvedValue(rows),
    orderBy: vi.fn().mockResolvedValue(rows),
  };
}

beforeEach(() => select.mockReset());

describe("Opik projection with the installed SDK runtime exports", () => {
  it.each([
    { tool: "calendar.lookup", key: "plan", details: {}, expected: "tool" },
    { tool: null, key: "synthesize", details: {}, expected: "llm" },
    { tool: null, key: "custom", details: { model: "synthetic-model" }, expected: "llm" },
    { tool: null, key: "capture", details: {}, expected: "general" },
  ])("classifies $key / $tool as $expected without a missing export", async (item) => {
    const now = new Date("2026-10-06T00:00:00Z");
    select
      .mockReturnValueOnce(queryRows([{
        id: "synthetic-run", user_id: "synthetic-user", memo_id: null,
        created_at: now, trigger_type: "memo", status: "completed",
        skill_snapshot: {}, agent_snapshot: {}, trigger_snapshot: {},
      }]))
      .mockReturnValueOnce(queryRows([{
        id: "synthetic-step", step_key: item.key, tool_key: item.tool,
        receipt: { details: item.details }, created_at: now, status: "completed",
        tokens_in: 3, tokens_out: 4, input_hash: "input", output_hash: "output",
      }]))
      .mockReturnValueOnce(queryRows([]));

    const projection = await buildOpikTraceProjection({
      runId: "synthetic-run", requestedMode: "metadata_only",
    });

    expect(projection.spans).toHaveLength(1);
    expect(projection.spans[0].type).toBe(item.expected);
    expect(projection.spans[0].usage?.total_tokens).toBe(7);
    expect(projection.input).not.toHaveProperty("content");
    expect(projection.metadata.user_pseudonym).not.toBe("synthetic-user");
    expect(select).toHaveBeenCalledTimes(3);
  });
});
