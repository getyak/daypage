import { describe, it, expect, vi, beforeEach } from "vitest";
import { NextRequest } from "next/server";
import { PgDialect } from "drizzle-orm/pg-core";

// ── Mocks ─────────────────────────────────────────────────────────────────────

const mockUser = { id: "user-uuid-1" };

vi.mock("@/auth", () => ({ auth: vi.fn() }));

const mockDb = { select: vi.fn() };
vi.mock("@/lib/db/client", () => ({ db: mockDb }));

vi.mock("@/lib/db/schema", async (importOriginal) => {
  const real = await importOriginal<typeof import("@/lib/db/schema")>();
  return { ...real };
});

import { auth } from "@/auth";

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeRequest(searchParams?: Record<string, string>): NextRequest {
  const url = new URL("http://localhost/api/pages");
  for (const [k, v] of Object.entries(searchParams ?? {})) {
    url.searchParams.set(k, v);
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
  vi.mocked(auth).mockResolvedValue(
    null as unknown as Awaited<ReturnType<typeof auth>>
  );
}

// Captures the condition passed to the pages query's `.where()` so we can assert
// which status filter (if any) was applied. First select() resolves the user id;
// second select() is the pages list query.
function mockDbCapturingWhere(): { capturedWhere: () => unknown } {
  let captured: unknown;
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
    return {
      from: vi.fn().mockReturnThis(),
      where: vi.fn((cond: unknown) => {
        captured = cond;
        return {
          orderBy: vi.fn().mockReturnThis(),
          limit: vi.fn().mockResolvedValue([]),
        };
      }),
    };
  });

  return { capturedWhere: () => captured };
}

// Render a drizzle condition to SQL + bound params so we can scan for the status
// literal the route injected. Enum equality lands in params (e.g. `status = $2`
// with params `["userId","live"]`), so we must inspect both halves.
const dialect = new PgDialect();
function sqlText(cond: unknown): string {
  if (cond == null) return "";
  try {
    const sql = (cond as { getSQL: () => Parameters<PgDialect["sqlToQuery"]>[0] }).getSQL();
    const q = dialect.sqlToQuery(sql);
    return q.sql + " " + JSON.stringify(q.params);
  } catch {
    return "";
  }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("GET /api/pages — US-004 status filter", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("returns 401 when not authenticated", async () => {
    mockNoSession();
    const { GET } = await import("../route");
    const res = await GET(makeRequest());
    expect(res.status).toBe(401);
  });

  it("defaults to live pages only", async () => {
    mockSession("alice@example.com");
    const { capturedWhere } = mockDbCapturingWhere();

    const { GET } = await import("../route");
    const res = await GET(makeRequest());
    expect(res.status).toBe(200);
    expect(sqlText(capturedWhere())).toContain("live");
  });

  it("surfaces draft sources with ?status=draft", async () => {
    mockSession("alice@example.com");
    const { capturedWhere } = mockDbCapturingWhere();

    const { GET } = await import("../route");
    await GET(makeRequest({ status: "draft" }));
    const text = sqlText(capturedWhere());
    expect(text).toContain("draft");
    expect(text).not.toContain("live");
  });

  it("lists every page with ?status=all (no status condition)", async () => {
    mockSession("alice@example.com");
    const { capturedWhere } = mockDbCapturingWhere();

    const { GET } = await import("../route");
    await GET(makeRequest({ status: "all" }));
    const text = sqlText(capturedWhere());
    expect(text).not.toContain("live");
    expect(text).not.toContain("draft");
  });

  it("ignores an invalid status and falls back to live", async () => {
    mockSession("alice@example.com");
    const { capturedWhere } = mockDbCapturingWhere();

    const { GET } = await import("../route");
    await GET(makeRequest({ status: "bogus" }));
    expect(sqlText(capturedWhere())).toContain("live");
  });
});
