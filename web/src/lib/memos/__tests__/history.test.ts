import { describe, it, expect } from "vitest";
import { supabaseMemoStore } from "../store";
import { fetchMemoHistory } from "../history";
import { decodeCursor, parseHistoryQuery, type HistoryQuery } from "../query";
import { handleHistoryRequest } from "../history-route";
import { FakePostgrest, type FakeRow } from "./fake-postgrest";

const USER_A = "11111111-2222-4333-8444-555555555555";
const USER_B = "22222222-2222-4333-8444-555555555555";

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

function baseQuery(overrides: Partial<HistoryQuery> = {}): HistoryQuery {
  return {
    q: null,
    type: null,
    tag: null,
    fromIso: null,
    toIso: null,
    cursor: null,
    limit: 20,
    ...overrides,
  };
}

const emptyQuery = parseHistoryQuery({});
function queryOf(params: Record<string, string | string[] | undefined>): HistoryQuery {
  const parsed = parseHistoryQuery(params);
  if (!parsed.ok) throw new Error(`unexpected parse failure: ${parsed.errors.join(", ")}`);
  return parsed.query;
}

describe("fetchMemoHistory", () => {
  it("pages with exact microsecond cursors and stable (created_at, id) order", async () => {
    const rows = [
      memo("99999999-0000-4000-8000-000000000009", "2026-01-01T00:00:00.123456+00:00"),
      memo("11111111-0000-4000-8000-000000000001", "2026-01-01T00:00:00.123456+00:00"),
      memo("22222222-0000-4000-8000-000000000002", "2026-01-01T00:00:00.123455+00:00"),
      memo("33333333-0000-4000-8000-000000000003", "2026-01-01T00:00:00.123457+00:00"),
    ];
    const db = new FakePostgrest({ memos: rows, memo_attachments: [] });
    const store = supabaseMemoStore(db);

    const page1 = await fetchMemoHistory(store, USER_A, baseQuery({ limit: 2 }));
    if (!page1.ok) throw new Error("page1 failed");
    expect(page1.items.map((i) => i.id)).toEqual([
      "33333333-0000-4000-8000-000000000003",
      "99999999-0000-4000-8000-000000000009",
    ]);
    expect(page1.hasMore).toBe(true);
    expect(page1.nextCursor).not.toBeNull();

    // The cursor carries the ORIGINAL timestamp string — microseconds intact.
    const decoded = decodeCursor(page1.nextCursor as string);
    expect(decoded?.createdAt).toBe("2026-01-01T00:00:00.123456+00:00");
    expect(decoded?.id).toBe("99999999-0000-4000-8000-000000000009");

    const page2 = await fetchMemoHistory(
      store,
      USER_A,
      baseQuery({ limit: 2, cursor: decoded as HistoryQuery["cursor"] }),
    );
    if (!page2.ok) throw new Error("page2 failed");
    // Equal-timestamp row with lower id arrives on page 2; the cursor row
    // itself and newer rows never repeat.
    expect(page2.items.map((i) => i.id)).toEqual([
      "11111111-0000-4000-8000-000000000001",
      "22222222-0000-4000-8000-000000000002",
    ]);
    expect(page2.hasMore).toBe(false);
    expect(page2.nextCursor).toBeNull();
  });

  it("walks a full page of identical timestamps without loss or repeats", async () => {
    const ts = "2026-02-02T02:02:02.222222+00:00";
    const rows = ["4", "3", "2", "1"].map((n) =>
      memo(`${n.repeat(8)}-0000-4000-8000-00000000000${n}`, ts),
    );
    const db = new FakePostgrest({ memos: rows, memo_attachments: [] });
    const store = supabaseMemoStore(db);

    const seen: string[] = [];
    let cursor: HistoryQuery["cursor"] = null;
    for (let guard = 0; guard < 5; guard += 1) {
      const page = await fetchMemoHistory(store, USER_A, baseQuery({ limit: 2, cursor }));
      if (!page.ok) throw new Error("page failed");
      seen.push(...page.items.map((i) => i.id));
      if (!page.hasMore) break;
      cursor = decodeCursor(page.nextCursor as string);
    }
    expect(new Set(seen).size).toBe(4);
    expect(seen).toHaveLength(4);
  });

  it("excludes other users and tombstones and groups ALL attachment kinds in order", async () => {
    const rows = [
      memo("a1111111-0000-4000-8000-000000000001", "2026-01-01T00:00:00.000001+00:00"),
      memo("b2222222-0000-4000-8000-000000000002", "2026-01-01T00:00:00.000002+00:00", {
        user_id: USER_B,
      }),
      memo("c3333333-0000-4000-8000-000000000003", "2026-01-01T00:00:00.000003+00:00", {
        deleted_at: "2026-01-02T00:00:00+00:00",
      }),
    ];
    const key = `${USER_A}/a1111111-0000-4000-8000-000000000001/abc`;
    const attachments = [
      // legacy row without position — stays visible, sorts first
      {
        id: "at444444-0000-4000-8000-000000000004",
        memo_id: "a1111111-0000-4000-8000-000000000001",
        kind: "file",
        storage_key: `${key}.pdf`,
        filename: "legacy.pdf",
        mime_type: "application/pdf",
        size_bytes: 100,
        duration_sec: null,
        duration_ms: null,
        position: null,
        ocr_text: null,
        transcript: null,
      },
      {
        id: "at222222-0000-4000-8000-000000000002",
        memo_id: "a1111111-0000-4000-8000-000000000001",
        kind: "audio",
        storage_key: `${key}.m4a`,
        filename: "voice.m4a",
        mime_type: "audio/m4a",
        size_bytes: 200,
        duration_sec: 3,
        duration_ms: null,
        position: 1,
        ocr_text: null,
        transcript: "hello",
      },
      {
        id: "at111111-0000-4000-8000-000000000001",
        memo_id: "a1111111-0000-4000-8000-000000000001",
        kind: "photo",
        storage_key: `${key}.jpg`,
        filename: "photo.jpg",
        mime_type: "image/jpeg",
        size_bytes: 300,
        duration_sec: null,
        duration_ms: null,
        position: 2,
        ocr_text: "alt text",
        transcript: null,
      },
      {
        id: "at333333-0000-4000-8000-000000000003",
        memo_id: "a1111111-0000-4000-8000-000000000001",
        kind: "file",
        storage_key: `${key}.mov`,
        filename: "clip.mov",
        mime_type: "video/quicktime",
        size_bytes: 400,
        duration_sec: null,
        duration_ms: null,
        position: 3,
        ocr_text: null,
        transcript: null,
      },
    ];
    const db = new FakePostgrest({ memos: rows, memo_attachments: attachments as FakeRow[] });
    const store = supabaseMemoStore(db);

    const result = await fetchMemoHistory(store, USER_A, baseQuery({ limit: 10 }));
    if (!result.ok) throw new Error("fetch failed");
    expect(result.items).toHaveLength(1);
    const item = result.items[0];
    expect(item.id).toBe("a1111111-0000-4000-8000-000000000001");
    expect(item.attachments.map((a) => a.id)).toEqual([
      "at444444-0000-4000-8000-000000000004",
      "at222222-0000-4000-8000-000000000002",
      "at111111-0000-4000-8000-000000000001",
      "at333333-0000-4000-8000-000000000003",
    ]);
    expect(item.attachments.map((a) => a.preview)).toEqual(["file", "audio", "image", "video"]);
    expect(item.attachments.every((a) => a.available)).toBe(true);
    expect(item.attachments[1].url).toBe(
      "/api/memos/a1111111-0000-4000-8000-000000000001/attachments/at222222-0000-4000-8000-000000000002",
    );
    // one batched attachments query for the page
    expect(db.countCalls("memo_attachments", "from")).toBe(1);
  });

  it("marks legacy/unsafe keys unavailable without dropping the reference", async () => {
    const rows = [memo("a1111111-0000-4000-8000-000000000001", "2026-01-01T00:00:00.000001+00:00")];
    const attachments = [
      {
        id: "at111111-0000-4000-8000-000000000001",
        memo_id: "a1111111-0000-4000-8000-000000000001",
        kind: "photo",
        storage_key: "legacy-bucket-key.png",
        filename: "old.png",
        mime_type: "image/png",
        size_bytes: 10,
        duration_sec: null,
        duration_ms: null,
        position: 0,
        ocr_text: null,
        transcript: null,
      },
    ];
    const db = new FakePostgrest({ memos: rows, memo_attachments: attachments as FakeRow[] });
    const store = supabaseMemoStore(db);
    const result = await fetchMemoHistory(store, USER_A, baseQuery());
    if (!result.ok) throw new Error("fetch failed");
    expect(result.items[0].attachments).toHaveLength(1);
    expect(result.items[0].attachments[0].available).toBe(false);
    expect(result.items[0].attachments[0].filename).toBe("old.png");
  });

  it("searches q as literal text (wildcards do not leak)", async () => {
    const rows = [
      memo("a1111111-0000-4000-8000-000000000001", "2026-01-01T00:00:00.000001+00:00", {
        body: "progress 100% done",
      }),
      memo("b2222222-0000-4000-8000-000000000002", "2026-01-01T00:00:00.000002+00:00", {
        body: "progress 100 points",
      }),
      memo("c3333333-0000-4000-8000-000000000003", "2026-01-01T00:00:00.000003+00:00", {
        body: "progress 100X done",
      }),
    ];
    const db = new FakePostgrest({ memos: rows, memo_attachments: [] });
    const store = supabaseMemoStore(db);

    const result = await fetchMemoHistory(store, USER_A, baseQuery({ q: "100%" }));
    if (!result.ok) throw new Error("fetch failed");
    expect(result.items.map((i) => i.id)).toEqual(["a1111111-0000-4000-8000-000000000001"]);

    const underscore = await fetchMemoHistory(store, USER_A, baseQuery({ q: "100_" }));
    if (!underscore.ok) throw new Error("fetch failed");
    expect(underscore.items).toHaveLength(0);
  });

  it("applies type and created-time filters", async () => {
    const rows = [
      memo("a1111111-0000-4000-8000-000000000001", "2026-01-01T16:00:00.000000+00:00", {
        type: "voice",
      }), // 2026-01-02 00:00 in Shanghai
      memo("b2222222-0000-4000-8000-000000000002", "2026-01-02T16:00:00.000000+00:00", {
        type: "text",
      }), // 2026-01-03 00:00 in Shanghai
    ];
    const db = new FakePostgrest({ memos: rows, memo_attachments: [] });
    const store = supabaseMemoStore(db);

    const byType = await fetchMemoHistory(store, USER_A, queryOf({ type: "voice" }));
    if (!byType.ok) throw new Error("fetch failed");
    expect(byType.items.map((i) => i.id)).toEqual(["a1111111-0000-4000-8000-000000000001"]);

    // Day window in Asia/Shanghai: 2026-01-02 covers the first row only.
    const byDay = await fetchMemoHistory(store, USER_A, queryOf({ from: "2026-01-02", to: "2026-01-02" }));
    if (!byDay.ok) throw new Error("fetch failed");
    expect(byDay.items.map((i) => i.id)).toEqual(["a1111111-0000-4000-8000-000000000001"]);
  });

  it("reports unavailable (never fake success) on backend errors", async () => {
    const failing = {
      listMemos: () => Promise.resolve({ rows: null, error: "connection lost" }),
      listAttachmentsByMemoIds: () => Promise.resolve({ rows: [], error: null }),
      getMemo: () => Promise.resolve({ rows: null, error: null }),
      listAttachmentsForMemo: () => Promise.resolve({ rows: [], error: null }),
      getAttachmentForMemo: () => Promise.resolve({ rows: null, error: null }),
      listTagCataloguePage: () => Promise.resolve({ rows: [], error: null }),
      listMemoTagLinksPage: () => Promise.resolve({ rows: [], error: null }),
    };
    const result = await fetchMemoHistory(failing, USER_A, baseQuery());
    expect(result).toEqual({ ok: false, reason: "unavailable" });
  });

  it("keeps empty pages honest", async () => {
    const db = new FakePostgrest({ memos: [], memo_attachments: [] });
    const store = supabaseMemoStore(db);
    const result = await fetchMemoHistory(store, USER_A, baseQuery());
    if (!result.ok) throw new Error("fetch failed");
    expect(result.items).toEqual([]);
    expect(result.hasMore).toBe(false);
    expect(result.nextCursor).toBeNull();
    expect(emptyQuery.ok).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// Imported-media presentation regressions (ADR-0026). All data is SYNTHETIC.
// The display body may be hidden ONLY when the whole body is exactly the
// importer's generated placeholder set for ALL attachments in order. The raw
// body stays byte-identical everywhere; `presentationBody` appears only when
// the server-side presentation actually changed.
// ---------------------------------------------------------------------------

const GEN_MEMO = "a1111111-0000-4000-8000-000000000001";
const SHA_PHOTO = "ab".repeat(32);
const SHA_AUDIO = "cd".repeat(32);
const SHA_FILE = "ef".repeat(32);

function genLine(kind: "photo" | "audio" | "file", name: string, sha: string, ext: string): string {
  const label = kind === "photo" ? "Photo" : kind === "audio" ? "Audio" : "File";
  return `[${label} attachment: ${name}](raw/assets/flomo/${sha}.${ext})`;
}

function genAttachment(args: {
  id: string;
  kind: string;
  name: string | null;
  sha: string;
  storageExt: string;
  position: number | null;
  overrides?: FakeRow;
}): FakeRow {
  return {
    id: args.id,
    memo_id: GEN_MEMO,
    kind: args.kind,
    storage_key: `${USER_A}/${GEN_MEMO}/${args.sha}.${args.storageExt}`,
    filename: args.name,
    mime_type: null,
    size_bytes: 12,
    duration_sec: null,
    duration_ms: null,
    position: args.position,
    ocr_text: null,
    transcript: null,
    ...args.overrides,
  };
}

function genMemo(body: string): FakeRow {
  return memo(GEN_MEMO, "2026-01-01T00:00:00.000001+00:00", { body });
}

async function fetchGenItems(
  rows: FakeRow[],
  attachments: FakeRow[],
  queryOverrides: Partial<HistoryQuery> = {},
) {
  const db = new FakePostgrest({ memos: rows, memo_attachments: attachments });
  const result = await fetchMemoHistory(supabaseMemoStore(db), USER_A, baseQuery(queryOverrides));
  if (!result.ok) throw new Error("fetch failed");
  return result.items;
}

describe("imported media presentation (fetchMemoHistory)", () => {
  it("hides the body only for the exact generated photo/audio/MOV ordered set", async () => {
    const body = [
      genLine("photo", "héllo 😀.png", SHA_PHOTO, "png"),
      genLine("audio", "voice note.m4a", SHA_AUDIO, "m4a"),
      genLine("file", "clip (final).mov", SHA_FILE, "mov"),
    ].join("\n");
    const items = await fetchGenItems(
      [genMemo(body)],
      [
        genAttachment({
          id: "at111111-0000-4000-8000-000000000001",
          kind: "photo",
          name: "héllo 😀.png",
          sha: SHA_PHOTO,
          storageExt: "png",
          position: 0,
        }),
        genAttachment({
          id: "at222222-0000-4000-8000-000000000002",
          kind: "audio",
          name: "voice note.m4a",
          sha: SHA_AUDIO,
          storageExt: "m4a",
          position: 1,
        }),
        genAttachment({
          id: "at333333-0000-4000-8000-000000000003",
          kind: "file",
          name: "clip (final).mov",
          sha: SHA_FILE,
          storageExt: "mov",
          position: 2,
        }),
      ],
    );
    expect(items).toHaveLength(1);
    const item = items[0];
    expect(item.body).toBe(body); // raw body is always byte-identical
    expect(item.presentationBody).toBe("");
    expect(item.attachments.map((a) => a.id)).toEqual([
      "at111111-0000-4000-8000-000000000001",
      "at222222-0000-4000-8000-000000000002",
      "at333333-0000-4000-8000-000000000003",
    ]);
  });

  it("maps a .jpeg original to the canonical .jpg cloud key and nothing else", async () => {
    const body = genLine("photo", "scan.jpeg", SHA_PHOTO, "jpeg");
    const canonical = await fetchGenItems(
      [genMemo(body)],
      [
        genAttachment({
          id: "at111111-0000-4000-8000-000000000001",
          kind: "photo",
          name: "scan.jpeg",
          sha: SHA_PHOTO,
          storageExt: "jpg",
          position: 0,
        }),
      ],
    );
    expect(canonical[0].presentationBody).toBe("");
    expect(canonical[0].body).toBe(body);

    const nonCanonical = await fetchGenItems(
      [genMemo(body)],
      [
        genAttachment({
          id: "at111111-0000-4000-8000-000000000001",
          kind: "photo",
          name: "scan.jpeg",
          sha: SHA_PHOTO,
          storageExt: "jpeg",
          position: 0,
        }),
      ],
    );
    expect(nonCanonical[0].presentationBody).toBeUndefined();
    expect(nonCanonical[0].body).toBe(body);
  });

  it("preserves the raw body for EVERY uncertain variant (no presentationBody)", async () => {
    const line = genLine("photo", "photo.png", SHA_PHOTO, "png");
    const photo = (name: string | null, sha: string, position: number | null, overrides: FakeRow = {}) =>
      genAttachment({
        id: "at111111-0000-4000-8000-000000000001",
        kind: "photo",
        name,
        sha,
        storageExt: "png",
        position,
        overrides,
      });
    const nfdName = "cafe\u0301.png"; // byte-distinct from NFC "café.png"
    const cases: Array<{ label: string; body: string; attachments: FakeRow[] }> = [
      { label: "prose before", body: `preface\n${line}`, attachments: [photo("photo.png", SHA_PHOTO, 0)] },
      { label: "prose after", body: `${line}\npostscript`, attachments: [photo("photo.png", SHA_PHOTO, 0)] },
      {
        label: "code fence content",
        body: "```\n" + line + "\n```",
        attachments: [photo("photo.png", SHA_PHOTO, 0)],
      },
      {
        label: "link body not generated",
        body: `[Photo attachment: photo.png](https://example.com/${SHA_PHOTO}.png)`,
        attachments: [photo("photo.png", SHA_PHOTO, 0)],
      },
      { label: "missing line", body: line, attachments: [photo("photo.png", SHA_PHOTO, 0), photo("b.png", SHA_AUDIO, 1)] },
      {
        label: "extra line",
        body: `${line}\n${genLine("photo", "b.png", SHA_AUDIO, "png")}`,
        attachments: [photo("photo.png", SHA_PHOTO, 0)],
      },
      {
        label: "duplicate line",
        body: `${line}\n${line}`,
        attachments: [photo("photo.png", SHA_PHOTO, 0), photo("other.png", SHA_PHOTO, 1)],
      },
      {
        label: "wrong order",
        body: [genLine("photo", "a.png", SHA_PHOTO, "png"), genLine("photo", "b.png", SHA_AUDIO, "png")].join("\n"),
        attachments: [photo("b.png", SHA_AUDIO, 0), photo("a.png", SHA_PHOTO, 1)],
      },
      {
        label: "wrong kind label",
        body: genLine("file", "photo.png", SHA_PHOTO, "png"),
        attachments: [photo("photo.png", SHA_PHOTO, 0)],
      },
      {
        label: "wrong filename",
        body: genLine("photo", "Photo.png", SHA_PHOTO, "png"),
        attachments: [photo("photo.png", SHA_PHOTO, 0)],
      },
      {
        label: "canonical-equivalent byte-distinct filename",
        body: genLine("photo", "café.png", SHA_PHOTO, "png"),
        attachments: [photo(nfdName, SHA_PHOTO, 0)],
      },
      {
        label: "64 variation-selector glyph hash",
        body: genLine("photo", "photo.png", `a\uFE0F${"b".repeat(62)}c`, "png"),
        attachments: [photo("photo.png", SHA_PHOTO, 0)],
      },
      {
        label: "unicode control in name",
        body: genLine("photo", "pho\u200Bto.png", SHA_PHOTO, "png"),
        attachments: [photo("pho\u200Bto.png", SHA_PHOTO, 0)],
      },
      {
        label: "oversized basename preserved even when matching",
        body: genLine("photo", "p".repeat(256) + ".png", SHA_PHOTO, "png"),
        attachments: [photo("p".repeat(256) + ".png", SHA_PHOTO, 0)],
      },
      {
        label: "alias path target",
        body: `[Photo attachment: photo.png](raw/assets/flomo/./${SHA_PHOTO}.png)`,
        attachments: [photo("photo.png", SHA_PHOTO, 0)],
      },
      {
        label: "query-string target",
        body: `[Photo attachment: photo.png](raw/assets/flomo/${SHA_PHOTO}.png?raw=1)`,
        attachments: [photo("photo.png", SHA_PHOTO, 0)],
      },
      {
        label: "wrong owner in storage key",
        body: line,
        attachments: [photo("photo.png", SHA_PHOTO, 0, { storage_key: `${USER_B}/${GEN_MEMO}/${SHA_PHOTO}.png` })],
      },
      {
        label: "wrong memo in storage key",
        body: line,
        attachments: [photo("photo.png", SHA_PHOTO, 0, { storage_key: `${USER_A}/b2222222-0000-4000-8000-000000000002/${SHA_PHOTO}.png` })],
      },
      {
        label: "wrong memo_id on row",
        body: line,
        attachments: [photo("photo.png", SHA_PHOTO, 0, { memo_id: "b2222222-0000-4000-8000-000000000002" })],
      },
      {
        label: "wrong SHA in storage key",
        body: line,
        attachments: [photo("photo.png", SHA_AUDIO, 0)],
      },
      { label: "null position (legacy)", body: line, attachments: [photo("photo.png", SHA_PHOTO, null)] },
      { label: "off-by-one positions", body: line, attachments: [photo("photo.png", SHA_PHOTO, 1)] },
      {
        label: "null filename (legacy)",
        body: genLine("photo", "photo.png", SHA_PHOTO, "png"),
        attachments: [photo(null, SHA_PHOTO, 0)],
      },
      {
        label: "legacy storage key",
        body: line,
        attachments: [photo("photo.png", SHA_PHOTO, 0, { storage_key: "legacy-bucket-key.png" })],
      },
    ];
    for (const testCase of cases) {
      const items = await fetchGenItems([genMemo(testCase.body)], testCase.attachments);
      expect(items[0].presentationBody, testCase.label).toBeUndefined();
      expect(items[0].body, testCase.label).toBe(testCase.body);
    }
  });

  it("keeps raw search, order, attachment and tag fidelity for hidden-body memos", async () => {
    const body = genLine("photo", "photo.png", SHA_PHOTO, "png");
    const other = memo("b2222222-0000-4000-8000-000000000002", "2026-01-01T00:00:00.000000+00:00", {
      body: "ordinary prose about photo.png",
    });
    const attachments = [
      genAttachment({
        id: "at111111-0000-4000-8000-000000000001",
        kind: "photo",
        name: "photo.png",
        sha: SHA_PHOTO,
        storageExt: "png",
        position: 0,
      }),
    ];
    const db = new FakePostgrest({ memos: [genMemo(body), other], memo_attachments: attachments });
    const store = supabaseMemoStore(db);

    // Raw body search still matches the hidden-body memo's original text.
    const searched = await fetchMemoHistory(store, USER_A, baseQuery({ q: "Photo attachment" }));
    if (!searched.ok) throw new Error("fetch failed");
    expect(searched.items.map((i) => i.id)).toEqual([GEN_MEMO]);
    expect(searched.items[0].body).toBe(body);
    expect(searched.items[0].presentationBody).toBe("");

    // Order, attachments and tags are untouched by presentation.
    const all = await fetchMemoHistory(store, USER_A, baseQuery({ limit: 10 }));
    if (!all.ok) throw new Error("fetch failed");
    expect(all.items.map((i) => i.id)).toEqual([GEN_MEMO, "b2222222-0000-4000-8000-000000000002"]);
    expect(all.items[0].attachments).toHaveLength(1);
    expect(all.items[0].tags).toEqual([]);
    expect(all.items[1].presentationBody).toBeUndefined();
  });

  it("serves the presentationBody over the SSR history route while keeping raw body", async () => {
    const body = genLine("photo", "photo.png", SHA_PHOTO, "png");
    const db = new FakePostgrest({
      memos: [genMemo(body)],
      memo_attachments: [
        genAttachment({
          id: "at111111-0000-4000-8000-000000000001",
          kind: "photo",
          name: "photo.png",
          sha: SHA_PHOTO,
          storageExt: "png",
          position: 0,
        }),
      ],
    });
    const res = await handleHistoryRequest(
      new Request("http://localhost/api/memos/history"),
      { userId: USER_A, store: supabaseMemoStore(db) },
    );
    expect(res.status).toBe(200);
    const payload = await res.json();
    expect(payload.items).toHaveLength(1);
    expect(payload.items[0].body).toBe(body);
    expect(payload.items[0].presentationBody).toBe("");
    // storage_key is trusted server metadata and never leaks into the wire DTO.
    expect(JSON.stringify(payload)).not.toContain(`${USER_A}/${GEN_MEMO}/${SHA_PHOTO}.png`);
  });
});
