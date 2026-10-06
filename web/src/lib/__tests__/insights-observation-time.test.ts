import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import type { SQL } from "drizzle-orm";
import { PgDialect } from "drizzle-orm/pg-core";
import type { AgentCostSummaryInput } from "@/lib/gateway/cost";
import { loadActivityStreamData } from "@/app/(app)/insights/_components/ActivityStreamCard";
import { loadAgentCostData } from "@/app/(app)/insights/_components/AgentCostCard";
import { loadDevActivityData } from "@/app/(app)/insights/_components/DevActivityCard";
import { DigitalFootprintCard, loadDigitalFootprintData } from "@/app/(app)/insights/_components/DigitalFootprintCard";
import { loadKnowledgeData } from "@/app/(app)/insights/_components/KnowledgeCard";
import { loadSystemCostData } from "@/app/(app)/insights/_components/SystemCostCard";

type Read = { condition?: SQL; limit?: number; table?: unknown };
interface Fixtures {
  email: string | null;
  reads: Read[];
  rows: unknown[][];
  failRead: number | null;
  advanceAfterReadMs: number;
  costInputs: AgentCostSummaryInput[];
  costFails: boolean;
}
const fixtures = vi.hoisted((): Fixtures => ({
  email: "owner-a@example.invalid", reads: [], rows: [], failRead: null,
  advanceAfterReadMs: 0, costInputs: [], costFails: false,
}));

vi.mock("@/lib/auth/session", () => ({
  auth: vi.fn(async () => fixtures.email ? { user: { email: fixtures.email } } : null),
}));
vi.mock("@/lib/gateway/cost", () => ({
  agentCostSummary: vi.fn(async (input: AgentCostSummaryInput) => {
    fixtures.costInputs.push(input);
    if (fixtures.costFails) throw new Error("controlled aggregate failure");
    return { userId: input.userId, since: input.since, tokensSpent: 7, dispatchCount: 2, byBackend: [] };
  }),
}));
vi.mock("@/app/(app)/insights/_components/ActivityStreamClient", () => ({ ActivityStreamClient: () => null }));
vi.mock("@/lib/db/client", () => {
  interface Query {
    from(table: unknown): Query;
    where(condition: SQL): Query;
    limit(limit: number): Query;
    orderBy(...columns: unknown[]): Query;
    groupBy(...columns: unknown[]): Query;
    then(resolve: (rows: unknown[]) => unknown, reject: (error: unknown) => unknown): Promise<unknown>;
  }
  function select(): Query {
    const read: Read = {};
    const index = fixtures.reads.push(read) - 1;
    const query: Query = {
      from(table) { read.table = table; return query; },
      where(condition) { read.condition = condition; return query; },
      limit(limit) { read.limit = limit; return query; },
      orderBy() { return query; },
      groupBy() { return query; },
      then(resolve, reject) {
        const rows = fixtures.rows.shift() ?? [];
        // A slow query must not move later queries or a deferred heatmap render
        // into a different observation window.
        vi.setSystemTime(new Date(Date.now() + fixtures.advanceAfterReadMs));
        const result = index === fixtures.failRead
          ? Promise.reject(new Error("controlled database failure"))
          : Promise.resolve(rows);
        return result.then(resolve, reject);
      },
    };
    return query;
  }
  return { db: { select, selectDistinct: select } };
});

const DAY = 86_400_000;
const BASE = Date.UTC(2026, 0, 1, 12);
const cards = [
  { name: "Activity", load: (range: string) => loadActivityStreamData({ range }), windowReads: 2 },
  { name: "Dev", load: (range: string) => loadDevActivityData({ range }), windowReads: 2 },
  { name: "Digital", load: (range: string) => loadDigitalFootprintData({ range }), windowReads: 1 },
  { name: "Knowledge", load: (range: string) => loadKnowledgeData({ range }), windowReads: 1 },
  { name: "System", load: (range: string) => loadSystemCostData({ range }), windowReads: 1 },
];
const dialect = new PgDialect();
function compiled(read: Read) {
  if (!read.condition) throw new Error("query did not constrain its tenant");
  return dialect.sqlToQuery(read.condition);
}

beforeEach(() => {
  vi.useFakeTimers();
  vi.setSystemTime(BASE);
  fixtures.email = "owner-a@example.invalid";
  fixtures.reads = [];
  fixtures.rows = [[{ id: "tenant-a" }]];
  fixtures.failRead = null;
  fixtures.advanceAfterReadMs = 0;
  fixtures.costInputs = [];
  fixtures.costFails = false;
});
afterEach(() => { vi.useRealTimers(); vi.restoreAllMocks(); });

describe("authenticated Insights observations", () => {
  for (const card of cards) {
    it.each([["7d", 7], ["30d", 30], ["90d", 90], ["1y", 365], ["unknown", 30]])(
      `${card.name}: preserves the %s window and tenant while queries advance time`,
      async (range, days) => {
        fixtures.advanceAfterReadMs = DAY;
        const data = await card.load(String(range));
        // Profile resolution happens first; the actual data load captures once.
        expect(data.asOfMs).toBe(BASE + DAY);
        expect(compiled(fixtures.reads[0]).params).toEqual(["owner-a@example.invalid"]);
        const since = new Date(BASE + DAY - Number(days) * DAY).toISOString();
        const windowReads = fixtures.reads.slice(1).filter((read) => compiled(read).sql.includes(" >= "));
        expect(windowReads).toHaveLength(card.windowReads);
        for (const read of fixtures.reads.slice(1)) expect(compiled(read).params).toContain("tenant-a");
        for (const read of windowReads) expect(compiled(read).params).toContain(since);
      },
    );
    it(`${card.name}: anonymous requests never query any tenant`, async () => {
      fixtures.email = null;
      await card.load("30d");
      expect(fixtures.reads).toHaveLength(0);
    });
    it(`${card.name}: a missing profile does not query another user's data`, async () => {
      fixtures.rows = [[]];
      await card.load("30d");
      expect(fixtures.reads).toHaveLength(1);
    });
    it(`${card.name}: failed data reads retain the existing empty fallback`, async () => {
      fixtures.failRead = 1;
      const data = await card.load("30d");
      expect(data.asOfMs).toBe(BASE);
      expect(fixtures.reads).toHaveLength(2);
      if ("items" in data) expect(data.items).toEqual([]);
      if ("daily" in data) expect(data.daily).toEqual([]);
      if ("heatmap" in data) expect(data.heatmap).toEqual([]);
      if ("claudeCodeCalls" in data) expect(data.claudeCodeCalls).toBe(0);
    });
  }

  it("Activity keeps verb filtering, the exclusive timestamp cursor and 20+1 paging", async () => {
    const cursor = new Date(BASE - DAY).toISOString();
    const rows = Array.from({ length: 21 }, (_, i) => ({
      id: `memo-${i}`, verb: "compile", subject: "own activity", target_type: null,
      target_id: null, created_at: new Date(BASE - i * 1000),
    }));
    fixtures.rows.push([{ verb: "z" }, { verb: "a" }], rows);
    const result = await loadActivityStreamData({ range: "7d", type: "compile", cursor });
    const query = compiled(fixtures.reads[2]);
    expect(query.sql).toContain(" < ");
    expect(query.params).toEqual(["tenant-a", new Date(BASE - 7 * DAY).toISOString(), "compile", cursor]);
    expect(fixtures.reads[2].limit).toBe(21);
    expect(result.verbOptions).toEqual(["a", "z"]);
    expect(result.items).toHaveLength(20);
    expect(result.hasMore).toBe(true);
    expect(result.nextCursor).toBe(rows[19].created_at.toISOString());
  });

  it("Agent captures one clock for both user-scoped 7d and 30d aggregates", async () => {
    fixtures.advanceAfterReadMs = DAY;
    const result = await loadAgentCostData();
    expect(result.asOfMs).toBe(BASE + DAY);
    expect(fixtures.costInputs).toEqual([
      { userId: "tenant-a", since: new Date(BASE + DAY - 7 * DAY) },
      { userId: "tenant-a", since: new Date(BASE + DAY - 30 * DAY) },
    ]);
    expect(result.week?.tokensSpent).toBe(7);
    expect(result.month?.dispatchCount).toBe(2);
  });
  it.each(["anonymous", "missing profile", "failed aggregate"])("Agent retains %s empty state", async (kind) => {
    if (kind === "anonymous") fixtures.email = null;
    if (kind === "missing profile") fixtures.rows = [[]];
    if (kind === "failed aggregate") fixtures.costFails = true;
    const result = await loadAgentCostData();
    expect(result.week).toBeNull();
    expect(result.month).toBeNull();
    expect(fixtures.costInputs).toHaveLength(kind === "failed aggregate" ? 2 : 0);
  });

  it("Digital's full-year grid keeps the query's date after deferred rendering crosses a year", async () => {
    fixtures.rows.push([{ n: 3 }], [{ n: 2 }], [{ n: 1 }], [{ date: "2026-01-01", count: 3 }]);
    const element = await DigitalFootprintCard({ range: "1y" });
    const markup = renderToStaticMarkup(element);
    expect(markup).toContain(": 3 memos");
    expect(markup).toContain("Total annotations");
    vi.setSystemTime(BASE + 400 * DAY);
    expect(renderToStaticMarkup(element)).toBe(markup);
  });

  it("Knowledge and System preserve their actual aggregate values", async () => {
    fixtures.rows.push([{ date: "2026-01-01", count: 4 }, { date: "2025-12-31", count: 2 }]);
    const knowledge = await loadKnowledgeData({ range: "7d" });
    expect(knowledge.total).toBe(6);
    expect(knowledge.avg).toBe(3);
    expect(knowledge.busiest).toEqual({ date: "2026-01-01", count: 4 });
    fixtures.rows = [[{ id: "tenant-b" }], [{ date: "2026-01-01", calls: 2, tokens_in: 1000, tokens_out: 2000 }]];
    const system = await loadSystemCostData({ range: "90d" });
    expect(system.totalCalls).toBe(2);
    expect(system.estimatedCost).toBe(0.033);
    expect(compiled(fixtures.reads[fixtures.reads.length - 1]).params).toContain("tenant-b");
    expect(compiled(fixtures.reads[fixtures.reads.length - 1]).params).not.toContain("tenant-a");
  });
});
