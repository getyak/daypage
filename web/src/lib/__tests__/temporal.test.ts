// US-040: temporal knowledge graph — verifies that the same entity mentioned
// across different months yields an evolution *sequence* (one point per month)
// rather than a single overwritten value, and that invalidated facts surface as
// such. The db client is mocked so this runs without Postgres.
import { describe, it, expect, vi, beforeEach } from "vitest";

// Shared state must be created via vi.hoisted so it exists when the hoisted
// vi.mock factory runs. `getEntityEvolution` issues two queries in order:
//   1. resolve the page by slug  → terminal .limit()
//   2. fetch its dated links     → terminal .orderBy()
// We script those two resolutions through a queue.
const { resultQueue } = vi.hoisted(() => ({ resultQueue: [] as unknown[][] }));

vi.mock("@/lib/db/client", () => {
  const chain: Record<string, unknown> = {};
  for (const m of [
    "select", "from", "where", "leftJoin", "innerJoin", "update", "set", "insert", "values",
  ]) {
    chain[m] = vi.fn(() => chain);
  }
  chain.orderBy = vi.fn(() => Promise.resolve(resultQueue.shift() ?? []));
  chain.limit = vi.fn(() => Promise.resolve(resultQueue.shift() ?? []));
  return { db: chain };
});

describe("getEntityEvolution", () => {
  let getEntityEvolution: typeof import("@/lib/temporal").getEntityEvolution;

  beforeEach(async () => {
    resultQueue.length = 0;
    const mod = await import("@/lib/temporal");
    getEntityEvolution = mod.getEntityEvolution;
  });

  it("returns a multi-month sequence, not an overwrite", async () => {
    // 1st query: page lookup
    resultQueue.push([{ id: "p1", title: "远程工作", slug: "entity/远程工作" }]);
    // 2nd query: dated links across November and December — same entity, 2 months
    resultQueue.push([
      { valid_from: new Date("2025-11-01T08:00:00Z"), valid_to: null, via_memo_id: "m1", rationale: "r1", memo_body: "第一次想到远程工作" },
      { valid_from: new Date("2025-11-20T08:00:00Z"), valid_to: null, via_memo_id: "m2", rationale: "r2", memo_body: "远程工作社群" },
      { valid_from: new Date("2025-12-03T08:00:00Z"), valid_to: null, via_memo_id: "m3", rationale: "r3", memo_body: "对远程工作的理解变了" },
    ]);

    const evo = await getEntityEvolution("u1", "entity/远程工作");
    expect(evo).not.toBeNull();
    expect(evo!.total).toBe(3);
    // The key assertion: distinct months are preserved as a sequence.
    expect(evo!.series.map((p) => p.period)).toEqual(["2025-11", "2025-12"]);
    expect(evo!.series[0].count).toBe(2); // November
    expect(evo!.series[1].count).toBe(1); // December
    expect(evo!.firstSeen).toBe("2025-11-01");
    expect(evo!.lastSeen).toBe("2025-12-03");
  });

  it("flags invalidated (superseded) mentions instead of dropping them", async () => {
    resultQueue.push([{ id: "p1", title: "X", slug: "entity/x" }]);
    resultQueue.push([
      { valid_from: new Date("2025-10-01T00:00:00Z"), valid_to: new Date("2025-11-01T00:00:00Z"), via_memo_id: "m1", rationale: "old view", memo_body: "old" },
    ]);
    const evo = await getEntityEvolution("u1", "entity/x");
    expect(evo!.total).toBe(1);
    expect(evo!.series[0].mentions[0].invalidated).toBe(true);
  });

  it("returns null for an unknown slug", async () => {
    resultQueue.push([]); // page lookup misses
    const evo = await getEntityEvolution("u1", "entity/missing");
    expect(evo).toBeNull();
  });
});
