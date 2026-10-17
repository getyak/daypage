import { describe, it, expect } from "vitest";
import { supabaseMemoStore } from "../store";
import { FakePostgrest, type FakeRow } from "./fake-postgrest";

const USER_A = "11111111-2222-4333-8444-555555555555";
const USER_B = "22222222-2222-4333-8444-555555555555";

function memo(id: string, userId: string, overrides: FakeRow = {}): FakeRow {
  return {
    id,
    user_id: userId,
    type: "text",
    body: `body-${id}`,
    created_at: "2026-01-01T00:00:00.000000+00:00",
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

function attachment(id: string, memoId: string, overrides: FakeRow = {}): FakeRow {
  return {
    id,
    memo_id: memoId,
    kind: "photo",
    storage_key: `${USER_A}/${memoId}/abc.png`,
    filename: `${id}.png`,
    mime_type: "image/png",
    size_bytes: 10,
    duration_sec: null,
    duration_ms: null,
    position: 0,
    ocr_text: null,
    transcript: null,
    ...overrides,
  };
}

describe("supabaseMemoStore (owner-scoped reads)", () => {
  it("lists only the verified user's non-tombstoned memos", async () => {
    const db = new FakePostgrest({
      memos: [
        memo("a1111111-0000-4000-8000-000000000001", USER_A, { body: "mine" }),
        memo("b2222222-0000-4000-8000-000000000002", USER_B, { body: "theirs" }),
        memo("c3333333-0000-4000-8000-000000000003", USER_A, {
          body: "deleted",
          deleted_at: "2026-01-02T00:00:00+00:00",
        }),
      ],
    });
    const store = supabaseMemoStore(db);

    const result = await store.listMemos({
      userId: USER_A,
      q: null,
      tag: null,
      type: null,
      fromIso: null,
      toIso: null,
      cursor: null,
      limit: 10,
    });
    expect(result.error).toBeNull();
    expect(result.rows?.map((r) => r.body)).toEqual(["mine"]);
  });

  it("never needs an email — uid predicates drive ownership", async () => {
    const db = new FakePostgrest({
      memos: [memo("a1111111-0000-4000-8000-000000000001", USER_A)],
    });
    const store = supabaseMemoStore(db);
    const result = await store.getMemo(USER_A, "a1111111-0000-4000-8000-000000000001");
    expect(result.rows?.id).toBe("a1111111-0000-4000-8000-000000000001");
    const projection = db.calls.find((c) => c.op === "projection");
    expect(String(projection?.detail)).not.toContain("email");
  });

  it("getMemo returns null for another user's memo and for tombstones", async () => {
    const db = new FakePostgrest({
      memos: [
        memo("a1111111-0000-4000-8000-000000000001", USER_A),
        memo("c3333333-0000-4000-8000-000000000003", USER_A, {
          deleted_at: "2026-01-02T00:00:00+00:00",
        }),
      ],
    });
    const store = supabaseMemoStore(db);
    expect((await store.getMemo(USER_B, "a1111111-0000-4000-8000-000000000001")).rows).toBeNull();
    expect((await store.getMemo(USER_A, "c3333333-0000-4000-8000-000000000003")).rows).toBeNull();
  });

  it("batches attachment lookups into exactly one query", async () => {
    const db = new FakePostgrest({
      memo_attachments: [
        attachment("aa111111-0000-4000-8000-000000000001", "a1111111-0000-4000-8000-000000000001", {
          position: 1,
        }),
        attachment("aa222222-0000-4000-8000-000000000002", "a1111111-0000-4000-8000-000000000001", {
          position: 0,
        }),
        attachment("aa333333-0000-4000-8000-000000000003", "b2222222-0000-4000-8000-000000000002", {
          position: 0,
        }),
        attachment("aa444444-0000-4000-8000-000000000004", "a1111111-0000-4000-8000-000000000001", {
          position: null,
        }),
      ],
    });
    const store = supabaseMemoStore(db);

    const result = await store.listAttachmentsByMemoIds([
      "a1111111-0000-4000-8000-000000000001",
      "b2222222-0000-4000-8000-000000000002",
    ]);
    expect(result.error).toBeNull();
    // ONE query for the whole page — no N+1 per memo.
    expect(db.countCalls("memo_attachments", "from")).toBe(1);

    // Position order, nulls first, then stable id order across memos.
    const rows = result.rows ?? [];
    expect(rows.map((r) => r.id)).toEqual([
      "aa444444-0000-4000-8000-000000000004",
      "aa222222-0000-4000-8000-000000000002",
      "aa333333-0000-4000-8000-000000000003",
      "aa111111-0000-4000-8000-000000000001",
    ]);
  });

  it("scopes attachments to the exact memo id and owner", async () => {
    const db = new FakePostgrest({
      memos: [
        memo("a1111111-0000-4000-8000-000000000001", USER_A),
        memo("b2222222-0000-4000-8000-000000000002", USER_B),
        memo("c3333333-0000-4000-8000-000000000003", USER_A, {
          deleted_at: "2026-01-02T00:00:00+00:00",
        }),
      ],
      memo_attachments: [
        attachment("aa111111-0000-4000-8000-000000000001", "a1111111-0000-4000-8000-000000000001"),
        attachment("aa222222-0000-4000-8000-000000000002", "b2222222-0000-4000-8000-000000000002", {
          storage_key: `${USER_B}/b/abc.png`,
        }),
        attachment("aa333333-0000-4000-8000-000000000003", "c3333333-0000-4000-8000-000000000003"),
      ],
    });
    const store = supabaseMemoStore(db);

    // Right attachment, right memo, right owner.
    const ok = await store.getAttachmentForMemo({
      userId: USER_A,
      memoId: "a1111111-0000-4000-8000-000000000001",
      attachmentId: "aa111111-0000-4000-8000-000000000001",
    });
    expect(ok.rows?.id).toBe("aa111111-0000-4000-8000-000000000001");

    // Wrong owner → null (uniform not-found upstream).
    const wrongOwner = await store.getAttachmentForMemo({
      userId: USER_B,
      memoId: "a1111111-0000-4000-8000-000000000001",
      attachmentId: "aa111111-0000-4000-8000-000000000001",
    });
    expect(wrongOwner.rows).toBeNull();

    // Attachment id that belongs to a DIFFERENT memo → null even for the owner.
    const wrongMemo = await store.getAttachmentForMemo({
      userId: USER_A,
      memoId: "a1111111-0000-4000-8000-000000000001",
      attachmentId: "aa333333-0000-4000-8000-000000000003",
    });
    expect(wrongMemo.rows).toBeNull();

    // Tombstoned memo hides its attachments entirely.
    const tombstone = await store.getAttachmentForMemo({
      userId: USER_A,
      memoId: "c3333333-0000-4000-8000-000000000003",
      attachmentId: "aa333333-0000-4000-8000-000000000003",
    });
    expect(tombstone.rows).toBeNull();
  });
});
