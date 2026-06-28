import { describe, it, expect, vi, beforeEach } from "vitest";
import { NextRequest } from "next/server";

// ── Mocks ─────────────────────────────────────────────────────────────────────

const mockUser = { id: "user-uuid-1" };
const mockUserB = { id: "user-uuid-2" };

vi.mock("@/auth", () => ({ auth: vi.fn() }));

const mockDb = {
  select: vi.fn(),
  insert: vi.fn(),
  update: vi.fn(),
  delete: vi.fn(),
};
vi.mock("@/lib/db/client", () => ({ db: mockDb }));

vi.mock("@/lib/db/schema", async (importOriginal) => {
  const real = await importOriginal<typeof import("@/lib/db/schema")>();
  return { ...real };
});

vi.mock("@/lib/ratelimit", () => ({
  checkMutationRateLimit: vi.fn().mockResolvedValue({
    success: true,
    remaining: 29,
    reset: Date.now() + 60_000,
  }),
}));

// API-key auth is opt-in per request: default to "no API key" so the existing
// session-based tests exercise the NextAuth path unchanged. Individual tests
// override authenticateApiKey to exercise the Bearer path.
vi.mock("@/lib/api-auth", () => ({
  authenticateApiKey: vi.fn().mockResolvedValue(null),
  hasScope: vi.fn((auth: { scopes: string[] }, scope: string) =>
    auth.scopes.includes("admin") || auth.scopes.includes(scope)
  ),
}));

import { auth } from "@/lib/auth/session";
import { checkMutationRateLimit } from "@/lib/ratelimit";
import { authenticateApiKey } from "@/lib/api-auth";

// Build a UUID for index `i` by zero-padding it into the last segment, so bulk
// payloads of N memos all carry distinct, schema-valid UUIDs (the zod schema
// rejects non-UUID ids before the count check, so naive string concatenation
// would mask count-limit assertions).
function uuidFor(i: number): string {
  return `550e8400-e29b-41d4-a716-${String(i).padStart(12, "0")}`;
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeRequest(body?: unknown): NextRequest {
  return new NextRequest("http://localhost/api/memos/bulk", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
}

function mockSession(email: string) {
  vi.mocked(auth).mockResolvedValue({
    user: { email, name: "Test", image: null },
    expires: "2099-01-01",
  } as unknown as Awaited<ReturnType<typeof auth>>);
}

function mockNoSession() {
  vi.mocked(auth).mockResolvedValue(null as unknown as Awaited<ReturnType<typeof auth>>);
}

function mockUserLookup(user: { id: string }) {
  const p = Promise.resolve([user]);
  mockDb.select.mockReturnValue(
    Object.assign(p, {
      from: vi.fn().mockReturnThis(),
      where: vi.fn().mockReturnThis(),
      limit: vi.fn().mockResolvedValue([user]),
    })
  );
}

function mockInsertChain() {
  const p = Promise.resolve([]);
  const chain = Object.assign(p, {
    values: vi.fn().mockReturnThis(),
    onConflictDoUpdate: vi.fn().mockResolvedValue([]),
  });
  mockDb.insert.mockReturnValue(chain);

  // delete chain for attachment replacement
  const delChain = Object.assign(Promise.resolve([]), {
    where: vi.fn().mockResolvedValue([]),
  });
  mockDb.delete.mockReturnValue(delChain);
  return chain;
}

function makeMemo(overrides: Record<string, unknown> = {}) {
  return {
    id: "550e8400-e29b-41d4-a716-446655440001",
    body: "Hello from iOS",
    type: "text",
    origin: "ios",
    ingest_mode: "light",
    created_at: "2026-01-01T10:00:00.000Z",
    updated_at: "2026-01-01T10:00:00.000Z",
    ...overrides,
  };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("POST /api/memos/bulk", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("returns 401 when not authenticated", async () => {
    mockNoSession();
    const { POST } = await import("../route");
    const res = await POST(makeRequest({ memos: [makeMemo()] }));
    expect(res.status).toBe(401);
  });

  it("returns 401 when user not found in DB", async () => {
    mockSession("ghost@example.com");
    const p = Promise.resolve([]);
    mockDb.select.mockReturnValue(
      Object.assign(p, {
        from: vi.fn().mockReturnThis(),
        where: vi.fn().mockReturnThis(),
        limit: vi.fn().mockResolvedValue([]),
      })
    );
    const { POST } = await import("../route");
    const res = await POST(makeRequest({ memos: [makeMemo()] }));
    expect(res.status).toBe(401);
  });

  it("returns 400 for invalid JSON body", async () => {
    mockSession("alice@example.com");
    mockUserLookup(mockUser); // auth must resolve before body parsing is reached
    const req = new NextRequest("http://localhost/api/memos/bulk", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "not-json",
    });
    const { POST } = await import("../route");
    const res = await POST(req);
    expect(res.status).toBe(400);
  });

  it("returns 400 when memos array is empty", async () => {
    mockSession("alice@example.com");
    mockUserLookup(mockUser);
    const { POST } = await import("../route");
    const res = await POST(makeRequest({ memos: [] }));
    expect(res.status).toBe(400);
    const data = await res.json() as { error: string };
    expect(data.error).toMatch(/at least one/i);
  });

  it("returns 400 when memos array exceeds 100", async () => {
    mockSession("alice@example.com");
    mockUserLookup(mockUser);
    const { POST } = await import("../route");
    const tooMany = Array.from({ length: 101 }, (_, i) =>
      makeMemo({ id: uuidFor(i) })
    );
    const res = await POST(makeRequest({ memos: tooMany }));
    expect(res.status).toBe(400);
    const data = await res.json() as { error: string };
    expect(data.error).toMatch(/maximum 100/i);
  });

  it("returns 400 when a memo is missing required id", async () => {
    mockSession("alice@example.com");
    mockUserLookup(mockUser);
    const { POST } = await import("../route");
    const res = await POST(makeRequest({ memos: [{ body: "no id here" }] }));
    expect(res.status).toBe(400);
  });

  it("upserts memos and returns accepted ids", async () => {
    mockSession("alice@example.com");
    mockUserLookup(mockUser);
    mockInsertChain();

    const { POST } = await import("../route");
    const memo = makeMemo();
    const res = await POST(makeRequest({ memos: [memo] }));
    expect(res.status).toBe(200);
    const data = await res.json() as { accepted: string[]; skipped: unknown[] };
    expect(data.accepted).toContain(memo.id);
    expect(data.skipped).toHaveLength(0);
  });

  it("is idempotent: same payload twice produces same accepted list", async () => {
    mockSession("alice@example.com");
    const { POST } = await import("../route");
    const memo = makeMemo();

    for (let i = 0; i < 2; i++) {
      vi.clearAllMocks();
      mockSession("alice@example.com");
      mockUserLookup(mockUser);
      mockInsertChain();

      const res = await POST(makeRequest({ memos: [memo] }));
      expect(res.status).toBe(200);
      const data = await res.json() as { accepted: string[] };
      expect(data.accepted).toContain(memo.id);
    }
  });

  it("moves failed inserts to skipped", async () => {
    mockSession("alice@example.com");
    mockUserLookup(mockUser);

    // Make insert throw
    const p = Promise.resolve([]);
    mockDb.insert.mockReturnValue(
      Object.assign(p, {
        values: vi.fn().mockReturnThis(),
        onConflictDoUpdate: vi.fn().mockRejectedValue(new Error("DB error")),
      })
    );

    const { POST } = await import("../route");
    const memo = makeMemo();
    const res = await POST(makeRequest({ memos: [memo] }));
    expect(res.status).toBe(200);
    const data = await res.json() as { accepted: string[]; skipped: { id: string; reason: string }[] };
    expect(data.accepted).toHaveLength(0);
    expect(data.skipped[0].id).toBe(memo.id);
    expect(data.skipped[0].reason).toMatch(/DB error/);
  });

  it("enforces rate limit (429)", async () => {
    mockSession("alice@example.com");
    vi.mocked(checkMutationRateLimit).mockResolvedValueOnce({
      success: false,
      remaining: 0,
      reset: Date.now() + 60_000,
    });
    const { POST } = await import("../route");
    const res = await POST(makeRequest({ memos: [makeMemo()] }));
    expect(res.status).toBe(429);
  });

  it("scope isolation: user A memos use user A id in upsert", async () => {
    // User B session — their userId must be used in insert, not user A's
    mockSession("bob@example.com");
    mockUserLookup(mockUserB);
    const insertChain = mockInsertChain();

    const { POST } = await import("../route");
    await POST(makeRequest({ memos: [makeMemo()] }));

    // The first insert call's values should include user_id = mockUserB.id
    const insertValuesMock = insertChain.values as ReturnType<typeof vi.fn>;
    expect(insertValuesMock).toHaveBeenCalled();
    const callArg = insertValuesMock.mock.calls[0][0] as { user_id: string };
    expect(callArg.user_id).toBe(mockUserB.id);
  });

  it("accepts max 100 memos exactly", async () => {
    mockSession("alice@example.com");

    const { POST } = await import("../route");

    vi.clearAllMocks();
    mockSession("alice@example.com");
    mockUserLookup(mockUser);
    mockInsertChain();

    const exactly100 = Array.from({ length: 100 }, (_, i) =>
      makeMemo({
        id: `550e8400-e29b-41d4-a716-${String(i).padStart(12, "0")}`,
      })
    );
    const res = await POST(makeRequest({ memos: exactly100 }));
    expect(res.status).toBe(200);
    const data = await res.json() as { accepted: string[] };
    expect(data.accepted).toHaveLength(100);
  });
});

// ── API-key Bearer auth (iOS sync path) ─────────────────────────────────────────

describe("POST /api/memos/bulk — API key auth", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  function makeKeyRequest(body: unknown, key = "dp_live_testkey"): NextRequest {
    return new NextRequest("http://localhost/api/memos/bulk", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${key}`,
      },
      body: JSON.stringify(body),
    });
  }

  it("accepts a memo when a valid write-scoped API key is presented (no session)", async () => {
    // No NextAuth session — auth resolves purely from the API key.
    mockNoSession();
    vi.mocked(authenticateApiKey).mockResolvedValue({
      userId: mockUser.id,
      scopes: ["write"],
    });
    const insertChain = mockInsertChain();

    const { POST } = await import("../route");
    const memo = makeMemo();
    const res = await POST(makeKeyRequest({ memos: [memo] }));

    expect(res.status).toBe(200);
    const data = (await res.json()) as { accepted: string[]; skipped: unknown[] };
    expect(data.accepted).toContain(memo.id);
    // The memo must be bound to the key's user, not anyone else.
    const callArg = (insertChain.values as ReturnType<typeof vi.fn>).mock
      .calls[0][0] as { user_id: string };
    expect(callArg.user_id).toBe(mockUser.id);
  });

  it("returns 403 when the API key lacks the write scope", async () => {
    mockNoSession();
    vi.mocked(authenticateApiKey).mockResolvedValue({
      userId: mockUser.id,
      scopes: ["read"],
    });
    const { POST } = await import("../route");
    const res = await POST(makeKeyRequest({ memos: [makeMemo()] }));
    expect(res.status).toBe(403);
    const data = (await res.json()) as { error: string };
    expect(data.error).toMatch(/write/i);
  });

  it("admin-scoped key implicitly satisfies the write requirement", async () => {
    mockNoSession();
    vi.mocked(authenticateApiKey).mockResolvedValue({
      userId: mockUser.id,
      scopes: ["admin"],
    });
    mockInsertChain();
    const { POST } = await import("../route");
    const res = await POST(makeKeyRequest({ memos: [makeMemo()] }));
    expect(res.status).toBe(200);
  });

  it("falls back to 401 when neither API key nor session is present", async () => {
    mockNoSession();
    vi.mocked(authenticateApiKey).mockResolvedValue(null);
    const { POST } = await import("../route");
    // No Authorization header at all.
    const res = await POST(makeRequest({ memos: [makeMemo()] }));
    expect(res.status).toBe(401);
  });

  it("API key takes precedence over a session (key user wins)", async () => {
    // A session exists for user B, but a key for user A is presented; memos
    // must bind to user A (the key holder).
    mockSession("bob@example.com");
    vi.mocked(authenticateApiKey).mockResolvedValue({
      userId: mockUser.id,
      scopes: ["write"],
    });
    const insertChain = mockInsertChain();
    const { POST } = await import("../route");
    await POST(makeKeyRequest({ memos: [makeMemo()] }));
    const callArg = (insertChain.values as ReturnType<typeof vi.fn>).mock
      .calls[0][0] as { user_id: string };
    expect(callArg.user_id).toBe(mockUser.id);
  });
});
