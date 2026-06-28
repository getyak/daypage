import { describe, it, expect, vi, beforeEach } from "vitest";
import { NextRequest } from "next/server";

// ── Mocks ─────────────────────────────────────────────────────────────────────

const mockUser = { id: "user-uuid-1" };

const mockActivity = {
  id: "activity-uuid-1",
  user_id: "user-uuid-1",
  verb: "created",
  subject: "memo",
  target_type: "memo",
  target_id: "memo-uuid-1",
  created_at: new Date("2026-01-01T00:00:00Z"),
};

vi.mock("@/auth", () => ({ auth: vi.fn() }));

const mockDb = { select: vi.fn() };
vi.mock("@/lib/db/client", () => ({ db: mockDb }));

vi.mock("@/lib/db/schema", async (importOriginal) => {
  const real = await importOriginal<typeof import("@/lib/db/schema")>();
  return { ...real };
});

import { auth } from "@/lib/auth/session";

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
  } as unknown as Awaited<ReturnType<typeof auth>>);
}

function mockNoSession() {
  vi.mocked(auth).mockResolvedValue(null as unknown as Awaited<ReturnType<typeof auth>>);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("GET /api/activities", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("returns 401 when not authenticated", async () => {
    mockNoSession();
    const { GET } = await import("../route");
    const req = makeRequest("/api/activities");
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
        orderBy: vi.fn().mockReturnThis(),
      });
    });

    const { GET } = await import("../route");
    const req = makeRequest("/api/activities");
    const res = await GET(req);
    expect(res.status).toBe(200);
    const data = await res.json() as { items: unknown[]; has_more: boolean; next_cursor: string | null };
    expect(Array.isArray(data.items)).toBe(true);
    expect(data.has_more).toBe(false);
    expect(data.next_cursor).toBeNull();
  });

  it("returns activities for authenticated user", async () => {
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
      const p = Promise.resolve([mockActivity]);
      return Object.assign(p, {
        from: vi.fn().mockReturnThis(),
        where: vi.fn().mockReturnThis(),
        orderBy: vi.fn().mockReturnThis(),
        limit: vi.fn().mockResolvedValue([mockActivity]),
      });
    });

    const { GET } = await import("../route");
    const req = makeRequest("/api/activities");
    const res = await GET(req);
    expect(res.status).toBe(200);
  });

  it("paginates with limit parameter", async () => {
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
      // Return limit+1 items to simulate has_more=true
      const items = Array.from({ length: 6 }, (_, i) => ({
        ...mockActivity,
        id: `activity-uuid-${i}`,
      }));
      const p = Promise.resolve(items);
      return Object.assign(p, {
        from: vi.fn().mockReturnThis(),
        where: vi.fn().mockReturnThis(),
        orderBy: vi.fn().mockReturnThis(),
        limit: vi.fn().mockResolvedValue(items),
      });
    });

    const { GET } = await import("../route");
    const req = makeRequest("/api/activities", { limit: "5" });
    const res = await GET(req);
    expect(res.status).toBe(200);
    const data = await res.json() as { items: unknown[]; has_more: boolean };
    expect(data.items).toHaveLength(5);
    expect(data.has_more).toBe(true);
  });

  it("scope isolation: user B gets empty list when no activities", async () => {
    mockSession("bob@example.com");
    const mockUserB = { id: "user-uuid-2" };

    let callCount = 0;
    mockDb.select.mockImplementation(() => {
      callCount++;
      if (callCount === 1) {
        const p = Promise.resolve([mockUserB]);
        return Object.assign(p, {
          from: vi.fn().mockReturnThis(),
          where: vi.fn().mockReturnThis(),
          limit: vi.fn().mockResolvedValue([mockUserB]),
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
    const req = makeRequest("/api/activities");
    const res = await GET(req);
    expect(res.status).toBe(200);
    const data = await res.json() as { items: unknown[] };
    expect(data.items).toHaveLength(0);
  });
});
