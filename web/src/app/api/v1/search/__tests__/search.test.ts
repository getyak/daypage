import { describe, it, expect, vi, beforeEach } from "vitest";
import { NextRequest } from "next/server";

// ── Mocks ─────────────────────────────────────────────────────────────────────

vi.mock("@/lib/api-auth", () => ({
  authenticateApiKey: vi.fn(),
  // Re-implement hasScope faithfully so scope enforcement is exercised for real.
  hasScope: (auth: { scopes: string[] }, scope: string) =>
    auth.scopes.includes("admin") || auth.scopes.includes(scope),
}));

vi.mock("@/lib/ai/rag", () => ({
  retrievePages: vi.fn(),
}));

import { authenticateApiKey } from "@/lib/api-auth";
import { retrievePages } from "@/lib/ai/rag";
import { GET } from "../route";

// ── Helpers ───────────────────────────────────────────────────────────────────

const USER_ID = "user-uuid-1";

function makeRequest(qs: string, key?: string): NextRequest {
  return new NextRequest(`http://localhost/api/v1/search${qs}`, {
    method: "GET",
    headers: key ? { Authorization: `Bearer ${key}` } : {},
  });
}

function mockKey(scopes: string[]) {
  vi.mocked(authenticateApiKey).mockResolvedValue({ userId: USER_ID, scopes });
}

beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(authenticateApiKey).mockResolvedValue(null);
});

// ── Auth ────────────────────────────────────────────────────────────────────

describe("GET /api/v1/search auth", () => {
  it("rejects an invalid / missing key with 401", async () => {
    const res = await GET(makeRequest("?q=kyoto"));
    expect(res.status).toBe(401);
  });

  it("rejects a valid key lacking the 'read' scope with 403", async () => {
    mockKey(["write"]);
    const res = await GET(makeRequest("?q=kyoto", "k"));
    expect(res.status).toBe(403);
  });

  it("allows an 'admin' key (implicit read) through", async () => {
    mockKey(["admin"]);
    vi.mocked(retrievePages).mockResolvedValue([]);
    const res = await GET(makeRequest("?q=kyoto", "k"));
    expect(res.status).toBe(200);
  });
});

// ── Behaviour ──────────────────────────────────────────────────────────────────

describe("GET /api/v1/search", () => {
  it("returns 400 when 'q' is missing", async () => {
    mockKey(["read"]);
    const res = await GET(makeRequest("", "k"));
    expect(res.status).toBe(400);
    expect(retrievePages).not.toHaveBeenCalled();
  });

  it("returns 400 when 'q' is blank", async () => {
    mockKey(["read"]);
    const res = await GET(makeRequest("?q=%20%20", "k"));
    expect(res.status).toBe(400);
    expect(retrievePages).not.toHaveBeenCalled();
  });

  it("returns results with slug and link-back url", async () => {
    mockKey(["read"]);
    vi.mocked(retrievePages).mockResolvedValue([
      {
        page_id: "p1",
        slug: "kyoto-trip",
        title: "Kyoto Trip",
        type: "entity",
        body_md: "Visited the temples and ate ramen.",
        score: 0.9123,
      },
    ]);

    const res = await GET(makeRequest("?q=kyoto", "k"));
    expect(res.status).toBe(200);
    const json = await res.json();
    expect(json.query).toBe("kyoto");
    expect(json.results[0].slug).toBe("kyoto-trip");
    expect(json.results[0].url).toContain("/wiki/kyoto-trip");
    expect(json.results[0].score).toBe(0.9123);
    expect(retrievePages).toHaveBeenCalledWith(USER_ID, "kyoto", { topK: 8 });
  });

  it("honours a valid top_k parameter (clamped to 20)", async () => {
    mockKey(["read"]);
    vi.mocked(retrievePages).mockResolvedValue([]);
    await GET(makeRequest("?q=x&top_k=50", "k"));
    expect(retrievePages).toHaveBeenCalledWith(USER_ID, "x", { topK: 20 });
  });

  it("rejects an invalid top_k with 400", async () => {
    mockKey(["read"]);
    const res = await GET(makeRequest("?q=x&top_k=0", "k"));
    expect(res.status).toBe(400);
    expect(retrievePages).not.toHaveBeenCalled();
  });
});
