import { describe, it, expect, vi, beforeEach } from "vitest";
import { NextRequest } from "next/server";

// ── Mocks ─────────────────────────────────────────────────────────────────────

const mockUser = { id: "user-uuid-1" };

const mockDomain = {
  id: "domain-uuid-1",
  user_id: "user-uuid-1",
  slug: "tech",
  label: "Technology",
  color: "#3b82f6",
  position: 0,
  created_at: new Date("2026-01-01T00:00:00Z"),
};

vi.mock("@/auth", () => ({ auth: vi.fn() }));

const mockDb = {
  select: vi.fn(),
  insert: vi.fn(),
};
vi.mock("@/lib/db/client", () => ({ db: mockDb }));

vi.mock("@/lib/db/schema", async (importOriginal) => {
  const real = await importOriginal<typeof import("@/lib/db/schema")>();
  return { ...real };
});

import { auth } from "@/auth";

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
  vi.mocked(auth).mockResolvedValue({
    user: { email, name: "Test User", image: null },
    expires: "2099-01-01",
  } as Awaited<ReturnType<typeof auth>>);
}

function mockNoSession() {
  vi.mocked(auth).mockResolvedValue(null);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("GET /api/domains", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("returns 401 when not authenticated", async () => {
    mockNoSession();
    const { GET } = await import("../route");
    const res = await GET();
    expect(res.status).toBe(401);
  });

  it("returns empty array for fresh user", async () => {
    mockSession("alice@example.com");

    let callCount = 0;
    mockDb.select.mockImplementation(() => {
      callCount++;
      const result = callCount === 1 ? [mockUser] : [];
      const p = Promise.resolve(result);
      return Object.assign(p, {
        from: vi.fn().mockReturnThis(),
        where: vi.fn().mockReturnThis(),
        limit: vi.fn().mockResolvedValue(callCount === 1 ? [mockUser] : []),
        orderBy: vi.fn().mockResolvedValue([]),
      });
    });

    const { GET } = await import("../route");
    const res = await GET();
    expect(res.status).toBe(200);
    const data = await res.json() as { items: unknown[] };
    expect(Array.isArray(data.items)).toBe(true);
  });

  it("returns domains for authenticated user", async () => {
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
      const p = Promise.resolve([mockDomain]);
      return Object.assign(p, {
        from: vi.fn().mockReturnThis(),
        where: vi.fn().mockReturnThis(),
        orderBy: vi.fn().mockResolvedValue([mockDomain]),
      });
    });

    const { GET } = await import("../route");
    const res = await GET();
    expect(res.status).toBe(200);
  });
});

describe("POST /api/domains", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("returns 401 when not authenticated", async () => {
    mockNoSession();
    const { POST } = await import("../route");
    const req = makeRequest("/api/domains", {
      method: "POST",
      body: { slug: "tech", label: "Technology" },
    });
    const res = await POST(req);
    expect(res.status).toBe(401);
  });

  it("returns 400 for missing required fields", async () => {
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

    const { POST } = await import("../route");
    const req = makeRequest("/api/domains", {
      method: "POST",
      body: { slug: "tech" }, // missing label
    });
    const res = await POST(req);
    expect(res.status).toBe(400);
  });

  it("creates domain and returns 201", async () => {
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

    const insertChain = Promise.resolve([mockDomain]);
    mockDb.insert.mockReturnValue(
      Object.assign(insertChain, {
        values: vi.fn().mockReturnThis(),
        returning: vi.fn().mockResolvedValue([mockDomain]),
      })
    );

    const { POST } = await import("../route");
    const req = makeRequest("/api/domains", {
      method: "POST",
      body: { slug: "tech", label: "Technology", color: "#3b82f6" },
    });
    const res = await POST(req);
    expect(res.status).toBe(201);
    const data = await res.json() as typeof mockDomain;
    expect(data.id).toBe(mockDomain.id);
  });
});
