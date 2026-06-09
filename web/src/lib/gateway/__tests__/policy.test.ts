import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

// ── Mocks ─────────────────────────────────────────────────────────────────────

// `vi.hoisted` keeps mockDb initialized before the hoisted vi.mock factory and
// the static import of "../policy" below eagerly evaluate it.
const mockDb = vi.hoisted(() => ({
  select: vi.fn(),
}));
vi.mock("@/lib/db/client", () => ({ db: mockDb }));

vi.mock("@/lib/db/schema", async (importOriginal) => {
  const real = await importOriginal<typeof import("@/lib/db/schema")>();
  return { ...real };
});

import { classifyGate, checkBudget, dailyTokenLimit } from "../policy";

// Build a thenable select chain resolving to `result`, supporting the drizzle
// builder methods checkBudget uses (from/where).
function selectChain(result: unknown[]) {
  const p = Promise.resolve(result);
  return Object.assign(p, {
    from: vi.fn().mockReturnThis(),
    where: vi.fn().mockResolvedValue(result),
  });
}

// ── classifyGate ──────────────────────────────────────────────────────────────

describe("classifyGate", () => {
  it("auto-runs tree-internal evolution intents", () => {
    expect(classifyGate("grow a new branch node under the goal")).toBe("auto");
    expect(classifyGate("prune the dead node")).toBe("auto");
    expect(classifyGate("evolve the task tree")).toBe("auto");
  });

  it("auto-runs text generation / compilation intents", () => {
    expect(classifyGate("summarize today's memos")).toBe("auto");
    expect(classifyGate("compile the daily page")).toBe("auto");
    expect(classifyGate("draft an outline")).toBe("auto");
    expect(classifyGate("suggest next tasks")).toBe("auto");
  });

  it("auto-runs external read-only intents", () => {
    expect(classifyGate("fetch the latest docs")).toBe("auto");
    expect(classifyGate("search the web for prior art")).toBe("auto");
    expect(classifyGate("analyze the repository")).toBe("auto");
  });

  it("requires approval for external write / messaging intents", () => {
    expect(classifyGate("post a tweet about the launch")).toBe("approve-first");
    expect(classifyGate("send an email to the team")).toBe("approve-first");
    expect(classifyGate("notify the user on telegram")).toBe("approve-first");
  });

  it("requires approval for code-mutation intents", () => {
    expect(classifyGate("commit and push the fix")).toBe("approve-first");
    expect(classifyGate("deploy to production")).toBe("approve-first");
    expect(classifyGate("refactor the auth module")).toBe("approve-first");
  });

  it("requires approval for destructive / external-write intents", () => {
    expect(classifyGate("delete the stale records")).toBe("approve-first");
    expect(classifyGate("create a PR on github")).toBe("approve-first");
    expect(classifyGate("charge the customer")).toBe("approve-first");
  });

  it("lets side-effects win when auto + write keywords both appear", () => {
    // "summarize" is auto, but "post" forces approval.
    expect(classifyGate("summarize the page then post it")).toBe("approve-first");
  });

  it("defaults unknown intents to approve-first", () => {
    expect(classifyGate("frobnicate the widget")).toBe("approve-first");
    expect(classifyGate("")).toBe("approve-first");
  });
});

// ── checkBudget ───────────────────────────────────────────────────────────────

describe("checkBudget", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    delete process.env.GATEWAY_DAILY_TOKEN_LIMIT;
  });

  afterEach(() => {
    delete process.env.GATEWAY_DAILY_TOKEN_LIMIT;
  });

  it("allows when spend is under the limit", async () => {
    mockDb.select.mockReturnValue(selectChain([{ spent: 1234 }]));
    const r = await checkBudget("user-1");
    expect(r.allowed).toBe(true);
    expect(r.spent).toBe(1234);
    expect(r.limit).toBe(dailyTokenLimit());
  });

  it("blocks when spend reaches the limit", async () => {
    process.env.GATEWAY_DAILY_TOKEN_LIMIT = "1000";
    mockDb.select.mockReturnValue(selectChain([{ spent: 1000 }]));
    const r = await checkBudget("user-1");
    expect(r.allowed).toBe(false);
    expect(r.spent).toBe(1000);
    expect(r.limit).toBe(1000);
  });

  it("blocks when spend exceeds the limit", async () => {
    process.env.GATEWAY_DAILY_TOKEN_LIMIT = "500";
    mockDb.select.mockReturnValue(selectChain([{ spent: 9000 }]));
    const r = await checkBudget("user-1");
    expect(r.allowed).toBe(false);
  });

  it("treats no usage rows as zero spend", async () => {
    mockDb.select.mockReturnValue(selectChain([{ spent: 0 }]));
    const r = await checkBudget("user-1");
    expect(r.spent).toBe(0);
    expect(r.allowed).toBe(true);
  });

  it("coerces string sums (postgres bigint) to numbers", async () => {
    mockDb.select.mockReturnValue(selectChain([{ spent: "4242" }]));
    const r = await checkBudget("user-1");
    expect(r.spent).toBe(4242);
    expect(typeof r.spent).toBe("number");
  });

  it("accepts an optional treeId without throwing", async () => {
    mockDb.select.mockReturnValue(selectChain([{ spent: 10 }]));
    const r = await checkBudget("user-1", "tree-1");
    expect(r.allowed).toBe(true);
  });
});

// ── dailyTokenLimit ───────────────────────────────────────────────────────────

describe("dailyTokenLimit", () => {
  afterEach(() => {
    delete process.env.GATEWAY_DAILY_TOKEN_LIMIT;
  });

  it("falls back to the default when env is unset or invalid", () => {
    delete process.env.GATEWAY_DAILY_TOKEN_LIMIT;
    expect(dailyTokenLimit()).toBe(1_000_000);
    process.env.GATEWAY_DAILY_TOKEN_LIMIT = "-5";
    expect(dailyTokenLimit()).toBe(1_000_000);
    process.env.GATEWAY_DAILY_TOKEN_LIMIT = "not-a-number";
    expect(dailyTokenLimit()).toBe(1_000_000);
  });

  it("honors a valid positive env override", () => {
    process.env.GATEWAY_DAILY_TOKEN_LIMIT = "250000";
    expect(dailyTokenLimit()).toBe(250000);
  });
});
