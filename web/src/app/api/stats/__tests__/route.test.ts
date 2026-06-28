import { describe, it, expect, vi, beforeEach } from "vitest";

// ── Mocks ─────────────────────────────────────────────────────────────────────

const mockUser = { id: "user-uuid-1" };

vi.mock("@/auth", () => ({ auth: vi.fn() }));

const mockDb = { select: vi.fn() };
vi.mock("@/lib/db/client", () => ({ db: mockDb }));

vi.mock("@/lib/db/schema", async (importOriginal) => {
  const real = await importOriginal<typeof import("@/lib/db/schema")>();
  return { ...real };
});

import { auth } from "@/lib/auth/session";

// ── Helpers ───────────────────────────────────────────────────────────────────

function mockSession(email: string) {
  vi.mocked(auth).mockResolvedValue({
    user: { email, name: "Test User", image: null },
    expires: "2099-01-01",
  } as unknown as Awaited<ReturnType<typeof auth>>);
}

function mockNoSession() {
  vi.mocked(auth).mockResolvedValue(null as unknown as Awaited<ReturnType<typeof auth>>);
}

// Build a select mock that returns count=0 for all 7 count queries after user lookup
function mockSelectForStats(userResult = [mockUser], countValue = 0) {
  let callCount = 0;
  mockDb.select.mockImplementation(() => {
    callCount++;
    if (callCount === 1) {
      // user lookup
      const p = Promise.resolve(userResult);
      return Object.assign(p, {
        from: vi.fn().mockReturnThis(),
        where: vi.fn().mockReturnThis(),
        limit: vi.fn().mockResolvedValue(userResult),
      });
    }
    // count queries
    const countRow = [{ count: countValue }];
    const p = Promise.resolve(countRow);
    return Object.assign(p, {
      from: vi.fn().mockReturnThis(),
      where: vi.fn().mockResolvedValue(countRow),
    });
  });
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("GET /api/stats", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("returns 401 when not authenticated", async () => {
    mockNoSession();
    const { GET } = await import("../route");
    const res = await GET();
    expect(res.status).toBe(401);
  });

  it("returns zero stats for fresh user", async () => {
    mockSession("alice@example.com");
    mockSelectForStats([mockUser], 0);

    const { GET } = await import("../route");
    const res = await GET();
    expect(res.status).toBe(200);
    const data = await res.json() as {
      sources: number;
      pages: number;
      domains: number;
      backlinks: number;
      deltas: { sources_week: number; pages_week: number; backlinks_week: number };
    };
    expect(data.sources).toBe(0);
    expect(data.pages).toBe(0);
    expect(data.domains).toBe(0);
    expect(data.backlinks).toBe(0);
    expect(data.deltas.sources_week).toBe(0);
    expect(data.deltas.pages_week).toBe(0);
    expect(data.deltas.backlinks_week).toBe(0);
  });

  it("returns correct stat shape with data", async () => {
    mockSession("alice@example.com");
    mockSelectForStats([mockUser], 5);

    const { GET } = await import("../route");
    const res = await GET();
    expect(res.status).toBe(200);
    const data = await res.json() as {
      sources: number;
      pages: number;
      domains: number;
      backlinks: number;
      deltas: { sources_week: number; pages_week: number; backlinks_week: number };
    };
    expect(typeof data.sources).toBe("number");
    expect(typeof data.pages).toBe("number");
    expect(typeof data.domains).toBe("number");
    expect(typeof data.backlinks).toBe("number");
    expect(typeof data.deltas.sources_week).toBe("number");
    expect(typeof data.deltas.pages_week).toBe("number");
    expect(typeof data.deltas.backlinks_week).toBe("number");
  });
});
