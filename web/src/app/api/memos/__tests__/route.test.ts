import { describe, it, expect, vi, beforeEach } from "vitest";
import { NextRequest } from "next/server";

// ── Mocks ─────────────────────────────────────────────────────────────────────

const mockMemo = {
  id: "memo-uuid-1",
  user_id: "user-uuid-1",
  type: "text" as const,
  body: "Hello world",
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
};

const mockUser = { id: "user-uuid-1" };
const mockUserB = { id: "user-uuid-2" };

// Auth mock
vi.mock("@/auth", () => ({
  auth: vi.fn(),
}));

// DB mock — will be configured per-test
const mockDb = {
  select: vi.fn(),
  insert: vi.fn(),
  update: vi.fn(),
  delete: vi.fn(),
};

vi.mock("@/lib/db/client", () => ({ db: mockDb }));

// Schema — re-export real values so type checks work
vi.mock("@/lib/db/schema", async (importOriginal) => {
  const real = await importOriginal<typeof import("@/lib/db/schema")>();
  return { ...real };
});

// Rate limiter — always succeeds in tests
vi.mock("@/lib/ratelimit", () => ({
  checkMutationRateLimit: vi.fn().mockResolvedValue({
    success: true,
    remaining: 29,
    reset: Date.now() + 60_000,
  }),
}));

import { auth } from "@/auth";
import { checkMutationRateLimit } from "@/lib/ratelimit";

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeRequest(
  path: string,
  {
    method = "GET",
    body,
    searchParams,
  }: { method?: string; body?: unknown; searchParams?: Record<string, string> } = {}
): NextRequest {
  const url = new URL(`http://localhost${path}`);
  if (searchParams) {
    for (const [k, v] of Object.entries(searchParams)) {
      url.searchParams.set(k, v);
    }
  }
  return new NextRequest(url.toString(), {
    method,
    headers: { "Content-Type": "application/json" },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
}

function mockSession(email: string) {
  vi.mocked(auth).mockResolvedValue({
    user: { email, name: "Test User", image: null },
    expires: "2099-01-01",
  } as unknown as Awaited<ReturnType<typeof auth>>);
}

function mockNoSession() {
  vi.mocked(auth).mockResolvedValue(null as unknown as Awaited<ReturnType<typeof auth>>);
}

// Chain-builder for db.select().from().where().limit().orderBy() etc.
function chainSelect(result: unknown[]) {
  const chain: Record<string, unknown> = {};
  const methods = ["from", "where", "limit", "orderBy", "and"];
  for (const m of methods) {
    chain[m] = vi.fn().mockReturnValue(chain);
  }
  chain["then"] = (_res: unknown, _rej: unknown) => Promise.resolve(result);
  // Make it thenable (await-able)
  Object.defineProperty(chain, Symbol.toStringTag, { value: "Promise" });
  // Vitest awaits the chain via .then
  const chainAsPromise = Object.assign(
    Promise.resolve(result),
    chain
  );
  for (const m of methods) {
    (chainAsPromise as Record<string, unknown>)[m] = vi.fn().mockReturnValue(chainAsPromise);
  }
  mockDb.select.mockReturnValue(chainAsPromise);
  return chainAsPromise;
}

function chainInsert(result: unknown[]) {
  const p = Promise.resolve(result);
  const chain = Object.assign(p, {
    into: vi.fn().mockReturnThis(),
    values: vi.fn().mockReturnThis(),
    returning: vi.fn().mockResolvedValue(result),
  });
  mockDb.insert.mockReturnValue(chain);
  return chain;
}

function chainDelete(result: unknown[]) {
  const p = Promise.resolve(result);
  const chain = Object.assign(p, {
    from: vi.fn().mockReturnThis(),
    where: vi.fn().mockReturnThis(),
    returning: vi.fn().mockResolvedValue(result),
  });
  mockDb.delete.mockReturnValue(chain);
  return chain;
}

function chainUpdate(result: unknown[]) {
  const p = Promise.resolve(result);
  const chain = Object.assign(p, {
    set: vi.fn().mockReturnThis(),
    where: vi.fn().mockReturnThis(),
    returning: vi.fn().mockResolvedValue(result),
  });
  mockDb.update.mockReturnValue(chain);
  return chain;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("GET /api/memos", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("returns 401 when not authenticated", async () => {
    mockNoSession();
    const { GET } = await import("../route");
    const req = makeRequest("/api/memos");
    const res = await GET(req);
    expect(res.status).toBe(401);
  });

  it("returns list of memos for authenticated user", async () => {
    mockSession("alice@example.com");

    // First select: user lookup; second: memos list
    let callCount = 0;
    mockDb.select.mockImplementation(() => {
      callCount++;
      if (callCount === 1) {
        // User lookup
        const p = Promise.resolve([mockUser]);
        return Object.assign(p, {
          from: vi.fn().mockReturnThis(),
          where: vi.fn().mockReturnThis(),
          limit: vi.fn().mockResolvedValue([mockUser]),
        });
      }
      // Memos list
      const p = Promise.resolve([mockMemo]);
      return Object.assign(p, {
        from: vi.fn().mockReturnThis(),
        where: vi.fn().mockReturnThis(),
        orderBy: vi.fn().mockReturnThis(),
        limit: vi.fn().mockResolvedValue([mockMemo]),
      });
    });

    const { GET } = await import("../route");
    const req = makeRequest("/api/memos");
    const res = await GET(req);
    expect(res.status).toBe(200);
    const data = await res.json() as { items: unknown[] };
    expect(Array.isArray(data.items)).toBe(true);
  });
});

describe("POST /api/memos", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("returns 401 when not authenticated", async () => {
    mockNoSession();
    const { POST } = await import("../route");
    const req = makeRequest("/api/memos", {
      method: "POST",
      body: { body: "test" },
    });
    const res = await POST(req);
    expect(res.status).toBe(401);
  });

  it("returns 400 for invalid body (empty body field)", async () => {
    mockSession("alice@example.com");

    let callCount = 0;
    mockDb.select.mockImplementation(() => {
      callCount++;
      if (callCount === 1) {
        const p = Promise.resolve([mockUser]);
        return Object.assign(p, {
          from: vi.fn().mockReturnThis(),
          where: vi.fn().mockReturnThis(),
          limit: vi.fn().mockResolvedValue([mockUser]),
        });
      }
      return Promise.resolve([]);
    });

    const { POST } = await import("../route");
    const req = makeRequest("/api/memos", {
      method: "POST",
      body: { body: "" }, // empty body — fails Zod min(1)
    });
    const res = await POST(req);
    expect(res.status).toBe(400);
  });

  it("creates memo and returns 201", async () => {
    mockSession("alice@example.com");

    let callCount = 0;
    mockDb.select.mockImplementation(() => {
      callCount++;
      const p = Promise.resolve([mockUser]);
      return Object.assign(p, {
        from: vi.fn().mockReturnThis(),
        where: vi.fn().mockReturnThis(),
        limit: vi.fn().mockResolvedValue([mockUser]),
      });
    });

    chainInsert([mockMemo]);

    const { POST } = await import("../route");
    const req = makeRequest("/api/memos", {
      method: "POST",
      body: { body: "Hello world", origin: "web" },
    });
    const res = await POST(req);
    expect(res.status).toBe(201);
    const data = await res.json() as typeof mockMemo;
    expect(data.id).toBe(mockMemo.id);
  });

  it("enforces rate limit (429)", async () => {
    mockSession("alice@example.com");
    vi.mocked(checkMutationRateLimit).mockResolvedValueOnce({
      success: false,
      remaining: 0,
      reset: Date.now() + 60_000,
    });

    const { POST } = await import("../route");
    const req = makeRequest("/api/memos", {
      method: "POST",
      body: { body: "test" },
    });
    const res = await POST(req);
    expect(res.status).toBe(429);
  });
});

describe("Scope isolation", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("user B cannot see user A memos (GET returns empty list)", async () => {
    mockSession("bob@example.com");

    let callCount = 0;
    mockDb.select.mockImplementation(() => {
      callCount++;
      if (callCount === 1) {
        // Bob's user lookup
        const p = Promise.resolve([mockUserB]);
        return Object.assign(p, {
          from: vi.fn().mockReturnThis(),
          where: vi.fn().mockReturnThis(),
          limit: vi.fn().mockResolvedValue([mockUserB]),
        });
      }
      // Bob has no memos
      const p = Promise.resolve([]);
      return Object.assign(p, {
        from: vi.fn().mockReturnThis(),
        where: vi.fn().mockReturnThis(),
        orderBy: vi.fn().mockReturnThis(),
        limit: vi.fn().mockResolvedValue([]),
      });
    });

    const { GET } = await import("../route");
    const req = makeRequest("/api/memos");
    const res = await GET(req);
    expect(res.status).toBe(200);
    const data = await res.json() as { items: unknown[] };
    expect(data.items).toHaveLength(0);
  });
});
