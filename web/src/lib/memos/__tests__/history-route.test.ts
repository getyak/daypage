import { describe, it, expect } from "vitest";
import { handleHistoryRequest, type HistoryRouteContext } from "../history-route";
import { supabaseMemoStore } from "../store";
import { decodeCursor, encodeCursor } from "../query";
import { FakePostgrest, type FakeRow } from "./fake-postgrest";

const USER_A = "11111111-2222-4333-8444-555555555555";

function memo(id: string, createdAt: string, overrides: FakeRow = {}): FakeRow {
  return {
    id,
    user_id: USER_A,
    type: "text",
    body: `body-${id}`,
    created_at: createdAt,
    location: null,
    weather: null,
    device: null,
    source_url: null,
    ingest_mode: "light",
    compile_status: "pending",
    origin: "web",
    vault_path: null,
    deleted_at: null,
    ...overrides,
  };
}

function ctxFor(db: FakePostgrest, userId: string | null = USER_A): HistoryRouteContext {
  return { userId, store: supabaseMemoStore(db) };
}

function get(path: string): Request {
  return new Request(`http://localhost${path}`);
}

describe("GET /api/memos/history handler", () => {
  it("returns 401 for anonymous requests before touching data", async () => {
    const db = new FakePostgrest({ memos: [memo("11111111-0000-4000-8000-000000000001", "2026-01-01T00:00:00.000001+00:00")] });
    const res = await handleHistoryRequest(get("/api/memos/history"), ctxFor(db, null));
    expect(res.status).toBe(401);
    expect(db.countCalls("memos")).toBe(0);
  });

  it("serves uid-scoped history even when the account has no email", async () => {
    // No email field exists anywhere in this flow — identity is the uid.
    const db = new FakePostgrest({
      memos: [
        memo("11111111-0000-4000-8000-000000000001", "2026-01-01T00:00:00.000001+00:00"),
        memo("22222222-0000-4000-8000-000000000002", "2026-01-01T00:00:00.000002+00:00", {
          user_id: "99999999-9999-4999-8999-999999999999",
        }),
      ],
      memo_attachments: [],
    });
    const res = await handleHistoryRequest(get("/api/memos/history"), ctxFor(db));
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.items.map((i: { id: string }) => i.id)).toEqual(["11111111-0000-4000-8000-000000000001"]);
    expect(body.has_more).toBe(false);
    expect(body.next_cursor).toBeNull();
    expect(body.page_size).toBe(20);
  });

  it("returns 400 with explicit details for malformed queries", async () => {
    const db = new FakePostgrest({ memos: [] });
    for (const path of [
      "/api/memos/history?cursor=%25%25%25",
      "/api/memos/history?limit=0",
      "/api/memos/history?from=2026-02-30",
      "/api/memos/history?q=a&q=b",
    ]) {
      const res = await handleHistoryRequest(get(path), ctxFor(db));
      expect(res.status, path).toBe(400);
      const body = await res.json();
      expect(body.error).toBe("Invalid query");
      expect(Array.isArray(body.details)).toBe(true);
    }
  });

  it("emits a microsecond-precise next_cursor and bounded page_size", async () => {
    const rows = [
      memo("33333333-0000-4000-8000-000000000003", "2026-01-01T00:00:00.123457+00:00"),
      memo("22222222-0000-4000-8000-000000000002", "2026-01-01T00:00:00.123456+00:00"),
      memo("11111111-0000-4000-8000-000000000001", "2026-01-01T00:00:00.123455+00:00"),
    ];
    const db = new FakePostgrest({ memos: rows, memo_attachments: [] });
    const res = await handleHistoryRequest(get("/api/memos/history?limit=2"), ctxFor(db));
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.items).toHaveLength(2);
    expect(body.has_more).toBe(true);
    const decoded = decodeCursor(body.next_cursor);
    expect(decoded?.createdAt).toBe("2026-01-01T00:00:00.123456+00:00");
    expect(decoded?.id).toBe("22222222-0000-4000-8000-000000000002");
    expect(body.page_size).toBe(2);

    // And the emitted cursor drives the next page.
    const res2 = await handleHistoryRequest(
      get(`/api/memos/history?limit=2&cursor=${encodeURIComponent(body.next_cursor)}`),
      ctxFor(db),
    );
    const body2 = await res2.json();
    expect(body2.items.map((i: { id: string }) => i.id)).toEqual(["11111111-0000-4000-8000-000000000001"]);
    expect(body2.has_more).toBe(false);
  });

  it("returns a generic 503 on backend failure without leaking internals", async () => {
    const failing: HistoryRouteContext = {
      userId: USER_A,
      store: {
        listMemos: () => Promise.resolve({ rows: null, error: 'relation "memos" does not exist' }),
        listAttachmentsByMemoIds: () => Promise.resolve({ rows: [], error: null }),
        getMemo: () => Promise.resolve({ rows: null, error: null }),
        listAttachmentsForMemo: () => Promise.resolve({ rows: [], error: null }),
        getAttachmentForMemo: () => Promise.resolve({ rows: null, error: null }),
        listTagCataloguePage: () => Promise.resolve({ rows: [], error: null }),
        listMemoTagLinksPage: () => Promise.resolve({ rows: [], error: null }),
      },
    };
    const res = await handleHistoryRequest(get("/api/memos/history"), failing);
    expect(res.status).toBe(503);
    const text = await res.text();
    expect(text).toContain("History is unavailable");
    expect(text).not.toContain("relation");
    expect(text).not.toContain("memos");
    expect(res.headers.get("cache-control")).toBe("private, no-store");
  });

  it("round-trips a client-built cursor without precision loss", async () => {
    const raw = "2026-06-30T15:59:59.999999+08:00";
    const cursor = encodeCursor({ createdAt: raw, id: "11111111-0000-4000-8000-000000000001" });
    const db = new FakePostgrest({
      memos: [memo("11111111-0000-4000-8000-000000000001", raw)],
      memo_attachments: [],
    });
    const res = await handleHistoryRequest(
      get(`/api/memos/history?cursor=${encodeURIComponent(cursor)}`),
      ctxFor(db),
    );
    expect(res.status).toBe(200);
  });
});
