import { describe, it, expect, vi, beforeEach } from "vitest";
import { NextRequest } from "next/server";

// ── Mocks ─────────────────────────────────────────────────────────────────────

vi.mock("@/lib/api-auth", () => ({
  authenticateApiKey: vi.fn(),
  // Re-implement hasScope faithfully so scope enforcement is exercised for real.
  hasScope: (auth: { scopes: string[] }, scope: string) =>
    auth.scopes.includes("admin") || auth.scopes.includes(scope),
}));

vi.mock("@/lib/ai/rag", () => ({
  retrievePages: vi.fn(),
}));

const { mockDb } = vi.hoisted(() => ({
  mockDb: { select: vi.fn(), insert: vi.fn() },
}));
vi.mock("@/lib/db/client", () => ({ db: mockDb }));

const { sendEventMock } = vi.hoisted(() => ({ sendEventMock: vi.fn() }));
vi.mock("@/lib/inngest/client", () => ({
  sendEvent: (...args: unknown[]) => sendEventMock(...args),
}));

import { authenticateApiKey } from "@/lib/api-auth";
import { retrievePages } from "@/lib/ai/rag";
import { POST } from "../route";

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeRequest(body: unknown, key?: string): NextRequest {
  return new NextRequest("http://localhost/api/mcp", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...(key ? { Authorization: `Bearer ${key}` } : {}),
    },
    body: JSON.stringify(body),
  });
}

const USER_ID = "user-uuid-1";

function mockKey(scopes: string[]) {
  vi.mocked(authenticateApiKey).mockResolvedValue({ userId: USER_ID, scopes });
}

beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(authenticateApiKey).mockResolvedValue(null);
});

// ── Auth ────────────────────────────────────────────────────────────────────

describe("MCP auth", () => {
  it("rejects an invalid / missing key with 401", async () => {
    const res = await POST(makeRequest({ jsonrpc: "2.0", id: 1, method: "tools/list" }));
    expect(res.status).toBe(401);
  });

  it("rejects a valid key lacking the 'read' scope with 403", async () => {
    mockKey(["write"]);
    const res = await POST(
      makeRequest({ jsonrpc: "2.0", id: 1, method: "tools/list" }, "k")
    );
    expect(res.status).toBe(403);
  });
});

// ── Protocol ──────────────────────────────────────────────────────────────────

describe("MCP protocol", () => {
  it("responds to initialize with serverInfo + tools capability", async () => {
    mockKey(["read"]);
    const res = await POST(
      makeRequest({ jsonrpc: "2.0", id: 1, method: "initialize" }, "k")
    );
    const json = await res.json();
    expect(json.result.serverInfo.name).toBe("daypage-wiki");
    expect(json.result.capabilities.tools).toBeDefined();
  });

  it("lists the available tools", async () => {
    mockKey(["read"]);
    const res = await POST(
      makeRequest({ jsonrpc: "2.0", id: 2, method: "tools/list" }, "k")
    );
    const json = await res.json();
    const names = json.result.tools.map((t: { name: string }) => t.name).sort();
    expect(names).toEqual(["add_memo", "get_page", "list_domains", "search_wiki"]);
  });

  it("returns 202 for the initialized notification (no id)", async () => {
    mockKey(["read"]);
    const res = await POST(
      makeRequest({ jsonrpc: "2.0", method: "notifications/initialized" }, "k")
    );
    expect(res.status).toBe(202);
  });
});

// ── search_wiki ────────────────────────────────────────────────────────────────

describe("search_wiki", () => {
  it("returns results with a slug and link-back url", async () => {
    mockKey(["read"]);
    vi.mocked(retrievePages).mockResolvedValue([
      {
        page_id: "p1",
        slug: "kyoto-trip",
        title: "Kyoto Trip",
        type: "entity",
        body_md: "Visited the temples and ate ramen.",
        score: 0.91,
      },
    ]);

    const res = await POST(
      makeRequest(
        {
          jsonrpc: "2.0",
          id: 3,
          method: "tools/call",
          params: { name: "search_wiki", arguments: { query: "kyoto" } },
        },
        "k"
      )
    );
    const json = await res.json();
    const hit = json.result.structuredContent.results[0];
    expect(hit.slug).toBe("kyoto-trip");
    expect(hit.url).toContain("/wiki/kyoto-trip");
    expect(retrievePages).toHaveBeenCalledWith(USER_ID, "kyoto", { topK: 8 });
  });

  it("rejects an empty query with INVALID_PARAMS", async () => {
    mockKey(["read"]);
    const res = await POST(
      makeRequest(
        {
          jsonrpc: "2.0",
          id: 4,
          method: "tools/call",
          params: { name: "search_wiki", arguments: { query: "  " } },
        },
        "k"
      )
    );
    const json = await res.json();
    expect(json.error.code).toBe(-32602);
  });
});

// ── list_domains ────────────────────────────────────────────────────────────────

describe("list_domains", () => {
  it("returns the user's domains", async () => {
    mockKey(["read"]);
    const rows = [{ slug: "travel", label: "Travel", color: null, position: 0 }];
    mockDb.select.mockReturnValue({
      from: vi.fn().mockReturnThis(),
      where: vi.fn().mockReturnThis(),
      orderBy: vi.fn().mockResolvedValue(rows),
    });

    const res = await POST(
      makeRequest(
        {
          jsonrpc: "2.0",
          id: 5,
          method: "tools/call",
          params: { name: "list_domains", arguments: {} },
        },
        "k"
      )
    );
    const json = await res.json();
    expect(json.result.structuredContent.domains[0].slug).toBe("travel");
  });
});

// ── add_memo ──────────────────────────────────────────────────────────────────

describe("add_memo", () => {
  function callAddMemo(text: unknown, key = "k") {
    return POST(
      makeRequest(
        {
          jsonrpc: "2.0",
          id: 6,
          method: "tools/call",
          params: { name: "add_memo", arguments: { text } },
        },
        key
      )
    );
  }

  it("saves a memo and emits memo/created when the key has the 'write' scope", async () => {
    mockKey(["read", "write"]);
    mockDb.insert.mockReturnValue({
      values: vi.fn().mockReturnThis(),
      returning: vi.fn().mockResolvedValue([{ id: "memo-1" }]),
    });
    sendEventMock.mockResolvedValue(undefined);

    const res = await callAddMemo("hello from an agent");
    const json = await res.json();

    expect(json.result.structuredContent.memo_id).toBe("memo-1");
    expect(sendEventMock).toHaveBeenCalledWith({
      name: "memo/created",
      data: { memo_id: "memo-1" },
    });
  });

  it("rejects with a clear error when the key lacks the 'write' scope", async () => {
    mockKey(["read"]);

    const res = await callAddMemo("hello from an agent");
    const json = await res.json();

    expect(json.error).toBeTruthy();
    expect(json.error.message).toMatch(/write/i);
    expect(mockDb.insert).not.toHaveBeenCalled();
    expect(sendEventMock).not.toHaveBeenCalled();
  });

  it("rejects an empty text with INVALID_PARAMS", async () => {
    mockKey(["read", "write"]);

    const res = await callAddMemo("   ");
    const json = await res.json();

    expect(json.error.code).toBe(-32602);
    expect(mockDb.insert).not.toHaveBeenCalled();
  });
});
