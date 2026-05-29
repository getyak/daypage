import { describe, it, expect, vi, beforeEach } from "vitest";
import { NextRequest } from "next/server";

// ── Mocks ─────────────────────────────────────────────────────────────────────

const mockMemo = {
  id: "ingest-memo-uuid-1",
  user_id: "user-uuid-1",
  type: "text",
  body: "Ingest test",
  created_at: new Date(),
  updated_at: new Date(),
  origin: "api",
};

const mockInboxItem = {
  id: "inbox-item-uuid-1",
  user_id: "user-uuid-1",
  kind: "orphan",
  title: "Observation test",
  status: "open",
  created_at: new Date(),
};

const mockActivity = {
  id: "activity-uuid-1",
  user_id: "user-uuid-1",
  verb: "test_action",
  subject: "test_source",
  created_at: new Date(),
};

const mockUser = { id: "user-uuid-1" };

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

vi.mock("@/lib/api-auth", () => ({
  authenticateApiKey: vi.fn().mockResolvedValue(null),
}));

vi.mock("@/lib/inngest/client", () => ({
  sendEvent: vi.fn().mockResolvedValue(undefined),
}));

import { auth } from "@/auth";

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeRequest(body: unknown, origin?: string): NextRequest {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (origin) headers["Origin"] = origin;
  return new NextRequest("http://localhost/api/ingest", {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
}

function mockSession(email: string) {
  vi.mocked(auth).mockResolvedValue({
    user: { email, name: "Test", image: null },
    expires: "2099-01-01",
  } as unknown as Awaited<ReturnType<typeof auth>>);
}

function mockUserLookup() {
  let call = 0;
  mockDb.select.mockImplementation(() => {
    call++;
    const result = call === 1 ? [mockUser] : [];
    const p = Promise.resolve(result);
    return Object.assign(p, {
      from: vi.fn().mockReturnThis(),
      where: vi.fn().mockReturnThis(),
      limit: vi.fn().mockResolvedValue(result),
    });
  });
}

// Captures the row passed to db.insert(...).values(...) so tests can assert on
// the memo body assembled from a clip payload.
function mockInsertMemo(): { values: ReturnType<typeof vi.fn> } {
  const values = vi.fn().mockReturnThis();
  const p = Promise.resolve([mockMemo]);
  mockDb.insert.mockReturnValue(
    Object.assign(p, {
      values,
      returning: vi.fn().mockResolvedValue([mockMemo]),
    })
  );
  return { values };
}

function mockInsertInbox() {
  let call = 0;
  mockDb.insert.mockImplementation(() => {
    call++;
    const result = call === 1 ? [mockInboxItem] : [mockActivity];
    const p = Promise.resolve(result);
    return Object.assign(p, {
      values: vi.fn().mockReturnThis(),
      returning: vi.fn().mockResolvedValue(result),
    });
  });
}

function mockInsertActivity() {
  let call = 0;
  mockDb.insert.mockImplementation(() => {
    call++;
    const result = call === 1 ? [mockActivity] : [mockActivity];
    const p = Promise.resolve(result);
    return Object.assign(p, {
      values: vi.fn().mockReturnThis(),
      returning: vi.fn().mockResolvedValue(result),
    });
  });
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("POST /api/ingest returns 200/201", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("ingest type=memo returns 201", async () => {
    mockSession("alice@example.com");
    mockUserLookup();
    mockInsertMemo();

    const { POST } = await import("../ingest/route");
    const res = await POST(
      makeRequest({
        source: "ios",
        type: "memo",
        payload: { body: "Ingest test" },
      })
    );
    expect(res.status).toBe(201);
    const data = await res.json() as { id: string };
    expect(data.id).toBe(mockMemo.id);
  });

  it("ingest type=observation returns 201", async () => {
    mockSession("alice@example.com");
    mockUserLookup();
    mockInsertInbox();

    const { POST } = await import("../ingest/route");
    const res = await POST(
      makeRequest({
        source: "web",
        type: "observation",
        payload: { title: "Observation test", body: "Some body" },
      })
    );
    expect(res.status).toBe(201);
  });

  it("ingest type=activity returns 201", async () => {
    mockSession("alice@example.com");
    mockUserLookup();
    mockInsertActivity();

    const { POST } = await import("../ingest/route");
    const res = await POST(
      makeRequest({
        source: "cli",
        type: "activity",
        payload: { verb: "test_action", subject: "test_source" },
      })
    );
    expect(res.status).toBe(201);
  });

  it("returns 401 without auth", async () => {
    vi.mocked(auth).mockResolvedValue(null as unknown as Awaited<ReturnType<typeof auth>>);
    const { POST } = await import("../ingest/route");
    const res = await POST(
      makeRequest({ source: "x", type: "memo", payload: { body: "test" } })
    );
    expect(res.status).toBe(401);
  });

  it("returns 400 for invalid type", async () => {
    mockSession("alice@example.com");
    mockUserLookup();

    const { POST } = await import("../ingest/route");
    const res = await POST(
      makeRequest({ source: "x", type: "invalid_type", payload: {} })
    );
    expect(res.status).toBe(400);
  });
});

// ── US-021: browser clipping (bookmarklet) ──────────────────────────────────────

describe("US-021 browser clip ingest", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("OPTIONS preflight returns CORS headers reflecting the origin", async () => {
    const { OPTIONS } = await import("../ingest/route");
    const req = new NextRequest("http://localhost/api/ingest", {
      method: "OPTIONS",
      headers: { Origin: "https://news.example.com" },
    });
    const res = OPTIONS(req);
    expect(res.status).toBe(204);
    expect(res.headers.get("Access-Control-Allow-Origin")).toBe(
      "https://news.example.com"
    );
    expect(res.headers.get("Access-Control-Allow-Methods")).toContain("POST");
    expect(res.headers.get("Access-Control-Allow-Headers")).toContain("Authorization");
  });

  it("clip with selection builds a memo body with title, snippet and source link", async () => {
    mockSession("alice@example.com");
    mockUserLookup();
    const { values } = mockInsertMemo();

    const { POST } = await import("../ingest/route");
    const res = await POST(
      makeRequest(
        {
          source: "web-clipper",
          type: "memo",
          payload: {
            title: "How to nomad",
            source_url: "https://blog.example.com/nomad",
            selection: "Pick a base with good wifi.",
          },
        },
        "https://blog.example.com"
      )
    );

    expect(res.status).toBe(201);
    // CORS header echoes the clipping page's origin.
    expect(res.headers.get("Access-Control-Allow-Origin")).toBe(
      "https://blog.example.com"
    );

    const row = values.mock.calls[0][0] as {
      body: string;
      source_url: string | null;
      origin: string;
      device: string;
    };
    expect(row.body).toContain("# How to nomad");
    expect(row.body).toContain("> Pick a base with good wifi.");
    expect(row.body).toContain("https://blog.example.com/nomad");
    expect(row.source_url).toBe("https://blog.example.com/nomad");
    expect(row.origin).toBe("api");
    expect(row.device).toBe("web-clipper");
  });

  it("whole-page clip (no selection) still records title + source", async () => {
    mockSession("alice@example.com");
    mockUserLookup();
    const { values } = mockInsertMemo();

    const { POST } = await import("../ingest/route");
    const res = await POST(
      makeRequest({
        source: "web-clipper",
        type: "memo",
        payload: {
          title: "Reference page",
          source_url: "https://docs.example.com/page",
          selection: "",
        },
      })
    );

    expect(res.status).toBe(201);
    const row = values.mock.calls[0][0] as { body: string };
    expect(row.body).toContain("# Reference page");
    expect(row.body).toContain("https://docs.example.com/page");
  });

  it("drops javascript: source URLs (no stored XSS)", async () => {
    mockSession("alice@example.com");
    mockUserLookup();
    const { values } = mockInsertMemo();

    const { POST } = await import("../ingest/route");
    const res = await POST(
      makeRequest({
        source: "web-clipper",
        type: "memo",
        payload: { title: "x", source_url: "javascript:alert(1)", selection: "y" },
      })
    );

    expect(res.status).toBe(201);
    const row = values.mock.calls[0][0] as { source_url: string | null };
    expect(row.source_url).toBeNull();
  });
});
