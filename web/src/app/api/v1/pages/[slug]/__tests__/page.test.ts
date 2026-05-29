import { describe, it, expect, vi, beforeEach } from "vitest";
import { NextRequest } from "next/server";

// ── Mocks ─────────────────────────────────────────────────────────────────────

vi.mock("@/lib/api-auth", () => ({
  authenticateApiKey: vi.fn(),
  hasScope: (auth: { scopes: string[] }, scope: string) =>
    auth.scopes.includes("admin") || auth.scopes.includes(scope),
}));

const { mockDb } = vi.hoisted(() => ({
  mockDb: { select: vi.fn() },
}));
vi.mock("@/lib/db/client", () => ({ db: mockDb }));

import { authenticateApiKey } from "@/lib/api-auth";
import { GET } from "../route";

// ── Helpers ───────────────────────────────────────────────────────────────────

const USER_ID = "user-uuid-1";

function makeRequest(key?: string): NextRequest {
  return new NextRequest("http://localhost/api/v1/pages/kyoto-trip", {
    method: "GET",
    headers: key ? { Authorization: `Bearer ${key}` } : {},
  });
}

function ctx(slug = "kyoto-trip") {
  return { params: Promise.resolve({ slug }) };
}

function mockKey(scopes: string[]) {
  vi.mocked(authenticateApiKey).mockResolvedValue({ userId: USER_ID, scopes });
}

function mockSelectResult(rows: unknown[]) {
  mockDb.select.mockReturnValue({
    from: vi.fn().mockReturnThis(),
    where: vi.fn().mockReturnThis(),
    limit: vi.fn().mockResolvedValue(rows),
  });
}

beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(authenticateApiKey).mockResolvedValue(null);
});

// ── Auth ────────────────────────────────────────────────────────────────────

describe("GET /api/v1/pages/:slug auth", () => {
  it("rejects an invalid / missing key with 401", async () => {
    const res = await GET(makeRequest(), ctx());
    expect(res.status).toBe(401);
  });

  it("rejects a valid key lacking the 'read' scope with 403", async () => {
    mockKey(["write"]);
    const res = await GET(makeRequest("k"), ctx());
    expect(res.status).toBe(403);
    expect(mockDb.select).not.toHaveBeenCalled();
  });
});

// ── Behaviour ──────────────────────────────────────────────────────────────────

describe("GET /api/v1/pages/:slug", () => {
  it("returns the page when found for this user", async () => {
    mockKey(["read"]);
    mockSelectResult([
      {
        slug: "kyoto-trip",
        title: "Kyoto Trip",
        type: "entity",
        status: "live",
        domain_id: null,
        body_md: "Visited the temples.",
        updated_at: new Date("2026-05-01T00:00:00.000Z"),
      },
    ]);

    const res = await GET(makeRequest("k"), ctx());
    expect(res.status).toBe(200);
    const json = await res.json();
    expect(json.page.slug).toBe("kyoto-trip");
    expect(json.page.body_md).toBe("Visited the temples.");
    expect(json.page.url).toContain("/wiki/kyoto-trip");
    expect(json.page.updated_at).toBe("2026-05-01T00:00:00.000Z");
  });

  it("returns 404 when no page matches for this user", async () => {
    mockKey(["read"]);
    mockSelectResult([]);
    const res = await GET(makeRequest("k"), ctx("missing"));
    expect(res.status).toBe(404);
  });
});
