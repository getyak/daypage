import { describe, it, expect, vi, beforeEach } from "vitest";
import { NextRequest } from "next/server";

// ── Mocks ─────────────────────────────────────────────────────────────────────

const mockMemo = {
  id: "550e8400-e29b-41d4-a716-446655440001",
  user_id: "user-uuid-1",
  type: "text" as const,
  body: "Integration test memo",
  created_at: new Date("2026-01-01T00:00:00Z"),
  updated_at: new Date("2026-01-01T00:00:00Z"),
  pinned_at: null,
  location: null,
  weather: null,
  device: null,
  source_url: null,
  ingest_mode: "light" as const,
  compile_status: "pending" as const,
  origin: "web" as const,
  vault_path: null,
  compile_error: null,
  compile_step: null,
  embedding: null,
  idempotency_key: null,
  source: "web",
  device_id: null,
  mood: null,
  word_count: 3,
};

const mockUser = { id: "user-uuid-1" };

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

vi.mock("@/lib/inngest/client", () => ({
  sendEvent: vi.fn().mockResolvedValue(undefined),
}));

vi.mock("@/lib/sanitize", () => ({
  sanitizeMemoBody: (s: string) => s,
}));

import { auth } from "@/lib/auth/session";

// ── Helpers ───────────────────────────────────────────────────────────────────

function makePostRequest(body: unknown): NextRequest {
  return new NextRequest("http://localhost/api/memos", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

function mockSession(email: string) {
  vi.mocked(auth).mockResolvedValue({
    user: { email, name: "Test User", image: null },
    expires: "2099-01-01",
  } as unknown as Awaited<ReturnType<typeof auth>>);
}

function mockUserLookup() {
  const p = Promise.resolve([mockUser]);
  mockDb.select.mockReturnValue(
    Object.assign(p, {
      from: vi.fn().mockReturnThis(),
      where: vi.fn().mockReturnThis(),
      limit: vi.fn().mockResolvedValue([mockUser]),
    })
  );
}

function mockInsert() {
  const p = Promise.resolve([mockMemo]);
  mockDb.insert.mockReturnValue(
    Object.assign(p, {
      values: vi.fn().mockReturnThis(),
      returning: vi.fn().mockResolvedValue([mockMemo]),
      onConflictDoNothing: vi.fn().mockResolvedValue([]),
    })
  );
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("POST /api/memos with auth returns 201", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("creates a memo and returns 201", async () => {
    mockSession("alice@example.com");
    mockUserLookup();
    mockInsert();

    const { POST } = await import("../memos/route");
    const res = await POST(makePostRequest({ body: "Integration test memo", origin: "web" }));

    expect(res.status).toBe(201);
    const data = await res.json() as typeof mockMemo;
    expect(data.id).toBe(mockMemo.id);
    expect(data.body).toBe(mockMemo.body);
  });

  it("returns 401 without auth", async () => {
    vi.mocked(auth).mockResolvedValue(null as unknown as Awaited<ReturnType<typeof auth>>);
    const { POST } = await import("../memos/route");
    const res = await POST(makePostRequest({ body: "test" }));
    expect(res.status).toBe(401);
  });

  it("accepts new US-033 fields (source, device_id, mood, word_count)", async () => {
    mockSession("alice@example.com");
    mockUserLookup();
    mockInsert();

    const { POST } = await import("../memos/route");
    const res = await POST(
      makePostRequest({
        body: "Memo with new fields",
        source: "ios",
        device_id: "iphone-abc123",
        mood: "happy",
        word_count: 4,
      })
    );
    expect(res.status).toBe(201);
  });
});
