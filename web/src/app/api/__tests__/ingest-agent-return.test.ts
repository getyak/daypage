import { describe, it, expect, vi, beforeEach } from "vitest";
import { NextRequest } from "next/server";

// US-017: agent product flow-back — claude-code source + agent-return channel.
// These tests verify the return creates a memo marked source='agent-return',
// links it back to the originating tree node, and triggers the compile flow.

// ── Mocks ─────────────────────────────────────────────────────────────────────

const mockMemo = {
  id: "agent-return-memo-uuid-1",
  user_id: "user-uuid-1",
  type: "text",
  body: "Compiled research summary.",
  origin: "api",
  source: "agent-return",
  device: "claude-code",
  created_at: new Date(),
  updated_at: new Date(),
};

const mockUser = { id: "user-uuid-1" };

vi.mock("@/auth", () => ({ auth: vi.fn() }));

const mockDb = {
  select: vi.fn(),
  insert: vi.fn(),
  update: vi.fn(),
};
vi.mock("@/lib/db/client", () => ({ db: mockDb }));

vi.mock("@/lib/db/schema", async (importOriginal) => {
  const real = await importOriginal<typeof import("@/lib/db/schema")>();
  return { ...real };
});

// API key auth (US-017 reuses the existing middleware).
const authenticateApiKey = vi.fn();
vi.mock("@/lib/api-auth", () => ({
  authenticateApiKey: (...args: unknown[]) => authenticateApiKey(...args),
  hasScope: (
    auth: { scopes: string[] },
    scope: string
  ) => auth.scopes.includes("admin") || auth.scopes.includes(scope),
}));

const sendEvent = vi.fn().mockResolvedValue(undefined);
vi.mock("@/lib/inngest/client", () => ({
  sendEvent: (...args: unknown[]) => sendEvent(...args),
}));

import { auth } from "@/auth";

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeRequest(body: unknown, apiKey?: string): NextRequest {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (apiKey) headers["Authorization"] = `Bearer ${apiKey}`;
  return new NextRequest("http://localhost/api/ingest", {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
}

function mockSession(email: string) {
  vi.mocked(auth).mockResolvedValue({
    user: { email, name: "Test", image: null },
    expires: "2099-01-01",
  } as unknown as Awaited<ReturnType<typeof auth>>);
}

// Capture the row passed to db.insert(...).values(...) for assertions.
function mockInsertMemo(): { values: ReturnType<typeof vi.fn> } {
  const values = vi.fn().mockReturnThis();
  const p = Promise.resolve([mockMemo]);
  mockDb.insert.mockReturnValue(
    Object.assign(p, {
      values,
      returning: vi.fn().mockResolvedValue([mockMemo]),
    })
  );
  return { values };
}

// Drive db.select results in call order: user lookup → tree node / work_order.
function mockSelectSequence(results: unknown[][]) {
  let call = 0;
  mockDb.select.mockImplementation(() => {
    const result = results[call] ?? [];
    call++;
    const p = Promise.resolve(result);
    return Object.assign(p, {
      from: vi.fn().mockReturnThis(),
      where: vi.fn().mockReturnThis(),
      limit: vi.fn().mockResolvedValue(result),
    });
  });
}

function mockUpdate(): { set: ReturnType<typeof vi.fn> } {
  const set = vi.fn().mockReturnThis();
  mockDb.update.mockReturnValue({
    set,
    where: vi.fn().mockResolvedValue(undefined),
  });
  return { set };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("US-017 agent-return ingest", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    authenticateApiKey.mockResolvedValue(null);
  });

  it("creates a memo marked source='agent-return' and triggers compile", async () => {
    mockSession("alice@example.com");
    // call 1: user lookup; call 2: tree node lookup for explicit tree_node_id.
    mockSelectSequence([
      [mockUser],
      [{ evidence_memo_ids: [] }],
    ]);
    const { values } = mockInsertMemo();
    mockUpdate();

    const { POST } = await import("../ingest/route");
    const res = await POST(
      makeRequest({
        source: "claude-code",
        channel: "agent-return",
        type: "memo",
        payload: {
          body: "Compiled research summary.",
          tree_node_id: "11111111-1111-1111-1111-111111111111",
        },
      })
    );

    expect(res.status).toBe(201);

    const row = values.mock.calls[0][0] as {
      body: string;
      source: string;
      device: string;
      origin: string;
    };
    expect(row.source).toBe("agent-return");
    expect(row.device).toBe("claude-code");
    expect(row.body).toBe("Compiled research summary.");

    // Compile flow is triggered for the new memo.
    expect(sendEvent).toHaveBeenCalledWith({
      name: "memo/created",
      data: { memo_id: mockMemo.id },
    });
  });

  it("links the memo back to the tree node from work_order.callback", async () => {
    mockSession("alice@example.com");
    // call 1: user lookup; call 2: work_order callback; call 3: tree node lookup.
    mockSelectSequence([
      [mockUser],
      [{ callback: { tree_node_id: "22222222-2222-2222-2222-222222222222" } }],
      [{ evidence_memo_ids: ["existing-memo-id"] }],
    ]);
    mockInsertMemo();
    const { set } = mockUpdate();

    const { POST } = await import("../ingest/route");
    const res = await POST(
      makeRequest({
        source: "claude-code",
        channel: "agent-return",
        type: "memo",
        payload: {
          result: "Agent output text.",
          work_order_id: "33333333-3333-3333-3333-333333333333",
        },
      })
    );

    expect(res.status).toBe(201);
    // The new memo id is appended to the node's evidence list.
    expect(set).toHaveBeenCalledWith({
      evidence_memo_ids: ["existing-memo-id", mockMemo.id],
    });
  });

  it("authenticates via API key (reuses existing middleware)", async () => {
    authenticateApiKey.mockResolvedValue({
      userId: "user-uuid-1",
      scopes: ["write"],
    });
    mockSelectSequence([[{ evidence_memo_ids: [] }]]);
    const { values } = mockInsertMemo();
    mockUpdate();

    const { POST } = await import("../ingest/route");
    const res = await POST(
      makeRequest(
        {
          source: "claude-code",
          channel: "agent-return",
          type: "memo",
          payload: {
            body: "Via API key.",
            tree_node_id: "44444444-4444-4444-4444-444444444444",
          },
        },
        "secret-api-key"
      )
    );

    expect(res.status).toBe(201);
    expect(authenticateApiKey).toHaveBeenCalled();
    const row = values.mock.calls[0][0] as { source: string };
    expect(row.source).toBe("agent-return");
  });

  it("rejects an agent-return with an empty body", async () => {
    mockSession("alice@example.com");
    mockSelectSequence([[mockUser]]);

    const { POST } = await import("../ingest/route");
    const res = await POST(
      makeRequest({
        source: "claude-code",
        channel: "agent-return",
        type: "memo",
        payload: { tree_node_id: "55555555-5555-5555-5555-555555555555" },
      })
    );

    expect(res.status).toBe(400);
  });
});
