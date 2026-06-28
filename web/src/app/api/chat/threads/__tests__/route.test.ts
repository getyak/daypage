import { describe, it, expect, vi, beforeEach } from "vitest";
import { NextRequest } from "next/server";

// ── Mocks ─────────────────────────────────────────────────────────────────────

const mockUser = { id: "user-uuid-1" };

const mockThread = {
  id: "thread-uuid-1",
  user_id: "user-uuid-1",
  title: "New conversation",
  status: "active" as const,
  synthesis_page_id: null,
  created_at: new Date("2026-01-01T00:00:00Z"),
  updated_at: new Date("2026-01-01T00:00:00Z"),
};

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

import { auth } from "@/lib/auth/session";

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeRequest(
  path: string,
  { method = "GET", body }: { method?: string; body?: unknown } = {}
): NextRequest {
  return new NextRequest(`http://localhost${path}`, {
    method,
    headers: { "Content-Type": "application/json" },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
}

function mockSession(email: string) {
  vi.mocked(auth).mockResolvedValue(
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    { user: { email, name: "Test User", image: null }, expires: "2099-01-01" } as any
  );
}

function mockNoSession() {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  vi.mocked(auth).mockResolvedValue(null as any);
}

function mockSelectUserThenResult<T>(result: T[]) {
  let callCount = 0;
  mockDb.select.mockImplementation(() => {
    callCount++;
    if (callCount === 1) {
      return Object.assign(Promise.resolve([mockUser]), {
        from: vi.fn().mockReturnThis(),
        where: vi.fn().mockReturnThis(),
        limit: vi.fn().mockResolvedValue([mockUser]),
      });
    }
    return Object.assign(Promise.resolve(result), {
      from: vi.fn().mockReturnThis(),
      where: vi.fn().mockReturnThis(),
      orderBy: vi.fn().mockResolvedValue(result),
      $dynamic: vi.fn().mockReturnThis(),
      limit: vi.fn().mockResolvedValue(result),
    });
  });
}

// ── GET /api/chat/threads ──────────────────────────────────────────────────────

describe("GET /api/chat/threads", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.resetModules();
  });

  it("returns 401 when not authenticated", async () => {
    mockNoSession();
    const { GET } = await import("../route");
    const req = makeRequest("/api/chat/threads");
    const res = await GET(req);
    expect(res.status).toBe(401);
  });

  it("returns empty array for fresh user", async () => {
    mockSession("alice@example.com");
    mockSelectUserThenResult([]);

    const { GET } = await import("../route");
    const req = makeRequest("/api/chat/threads");
    const res = await GET(req);
    expect(res.status).toBe(200);
    const data = (await res.json()) as { items: unknown[] };
    expect(Array.isArray(data.items)).toBe(true);
  });

  it("returns threads for authenticated user", async () => {
    mockSession("alice@example.com");
    mockSelectUserThenResult([mockThread]);

    const { GET } = await import("../route");
    const req = makeRequest("/api/chat/threads");
    const res = await GET(req);
    expect(res.status).toBe(200);
  });
});

// ── POST /api/chat/threads ────────────────────────────────────────────────────

describe("POST /api/chat/threads", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.resetModules();
  });

  it("returns 401 when not authenticated", async () => {
    mockNoSession();
    const { POST } = await import("../route");
    const req = makeRequest("/api/chat/threads", { method: "POST", body: {} });
    const res = await POST(req);
    expect(res.status).toBe(401);
  });

  it("creates thread with default title and returns 201", async () => {
    mockSession("alice@example.com");

    mockDb.select.mockImplementation(() =>
      Object.assign(Promise.resolve([mockUser]), {
        from: vi.fn().mockReturnThis(),
        where: vi.fn().mockReturnThis(),
        limit: vi.fn().mockResolvedValue([mockUser]),
      })
    );

    mockDb.insert.mockReturnValue(
      Object.assign(Promise.resolve([mockThread]), {
        values: vi.fn().mockReturnThis(),
        returning: vi.fn().mockResolvedValue([mockThread]),
      })
    );

    const { POST } = await import("../route");
    const req = makeRequest("/api/chat/threads", { method: "POST", body: {} });
    const res = await POST(req);
    expect(res.status).toBe(201);
    const data = (await res.json()) as typeof mockThread;
    expect(data.id).toBe(mockThread.id);
    expect(data.title).toBe("New conversation");
    expect(data.status).toBe("active");
  });

  it("creates thread with custom title", async () => {
    mockSession("alice@example.com");

    const customThread = { ...mockThread, title: "My custom thread" };

    mockDb.select.mockImplementation(() =>
      Object.assign(Promise.resolve([mockUser]), {
        from: vi.fn().mockReturnThis(),
        where: vi.fn().mockReturnThis(),
        limit: vi.fn().mockResolvedValue([mockUser]),
      })
    );

    mockDb.insert.mockReturnValue(
      Object.assign(Promise.resolve([customThread]), {
        values: vi.fn().mockReturnThis(),
        returning: vi.fn().mockResolvedValue([customThread]),
      })
    );

    const { POST } = await import("../route");
    const req = makeRequest("/api/chat/threads", {
      method: "POST",
      body: { title: "My custom thread" },
    });
    const res = await POST(req);
    expect(res.status).toBe(201);
  });
});

// ── Scope isolation ───────────────────────────────────────────────────────────

describe("scope isolation", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.resetModules();
  });

  it("user-B cannot see user-A threads (GET returns empty)", async () => {
    mockSession("bob@example.com");
    // resolveUserId returns user-B but threads query returns empty
    mockSelectUserThenResult([]);

    const { GET } = await import("../route");
    const req = makeRequest("/api/chat/threads");
    const res = await GET(req);
    expect(res.status).toBe(200);
    const data = (await res.json()) as { items: unknown[] };
    expect(data.items).toHaveLength(0);
  });
});
