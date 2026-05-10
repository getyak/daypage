import { describe, it, expect, vi, beforeEach } from "vitest";
import { NextRequest } from "next/server";

// ── Mocks ─────────────────────────────────────────────────────────────────────

const mockUser = { id: "user-uuid-1" };

const mockInboxItem = {
  id: "inbox-uuid-1",
  user_id: "user-uuid-1",
  kind: "contradiction" as const,
  title: "Two takes on topic X",
  body: "Some body",
  payload: null,
  status: "open" as const,
  resolution: null,
  created_at: new Date("2026-01-01T00:00:00Z"),
  resolved_at: null,
};

vi.mock("@/auth", () => ({ auth: vi.fn() }));

const mockDb = { select: vi.fn() };
vi.mock("@/lib/db/client", () => ({ db: mockDb }));

vi.mock("@/lib/db/schema", async (importOriginal) => {
  const real = await importOriginal<typeof import("@/lib/db/schema")>();
  return { ...real };
});

import { auth } from "@/auth";

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeRequest(path: string, searchParams?: Record<string, string>): NextRequest {
  const url = new URL(`http://localhost${path}`);
  if (searchParams) {
    for (const [k, v] of Object.entries(searchParams)) {
      url.searchParams.set(k, v);
    }
  }
  return new NextRequest(url.toString());
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

describe("GET /api/inbox", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("returns 401 when not authenticated", async () => {
    mockNoSession();
    const { GET } = await import("../route");
    const req = makeRequest("/api/inbox");
    const res = await GET(req);
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
    const req = makeRequest("/api/inbox");
    const res = await GET(req);
    expect(res.status).toBe(200);
    const data = await res.json() as { items: unknown[] };
    expect(Array.isArray(data.items)).toBe(true);
  });

  it("returns inbox items with default status=open", async () => {
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
      const p = Promise.resolve([mockInboxItem]);
      return Object.assign(p, {
        from: vi.fn().mockReturnThis(),
        where: vi.fn().mockReturnThis(),
        orderBy: vi.fn().mockReturnThis(),
        limit: vi.fn().mockResolvedValue([mockInboxItem]),
      });
    });

    const { GET } = await import("../route");
    const req = makeRequest("/api/inbox");
    const res = await GET(req);
    expect(res.status).toBe(200);
  });

  it("filters by kind parameter", async () => {
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
      const p = Promise.resolve([]);
      return Object.assign(p, {
        from: vi.fn().mockReturnThis(),
        where: vi.fn().mockReturnThis(),
        orderBy: vi.fn().mockReturnThis(),
        limit: vi.fn().mockResolvedValue([]),
      });
    });

    const { GET } = await import("../route");
    const req = makeRequest("/api/inbox", { kind: "schema" });
    const res = await GET(req);
    expect(res.status).toBe(200);
    const data = await res.json() as { items: unknown[] };
    expect(data.items).toHaveLength(0);
  });

  it("returns 400 for invalid kind", async () => {
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

    const { GET } = await import("../route");
    const req = makeRequest("/api/inbox", { kind: "invalid" });
    const res = await GET(req);
    expect(res.status).toBe(400);
  });
});
