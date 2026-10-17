import { describe, it, expect } from "vitest";
import { supabaseMemoStore } from "../store";
import { fetchMemoDetail } from "../detail";
import { FakePostgrest, type FakeRow } from "./fake-postgrest";

const USER_A = "11111111-2222-4333-8444-555555555555";
const USER_B = "22222222-2222-4333-8444-555555555555";
const MEMO_ID = "a1111111-0000-4000-8000-000000000001";

function memoRow(overrides: FakeRow = {}): FakeRow {
  return {
    id: MEMO_ID,
    user_id: USER_A,
    type: "text",
    body: "#会议 notes",
    created_at: "2026-01-01T00:00:00.000000+00:00",
    location: null,
    weather: null,
    device: null,
    source_url: null,
    ingest_mode: "light",
    compile_status: "pending",
    origin: "web",
    vault_path: "vault/raw/2026-01-01.md",
    deleted_at: null,
    ...overrides,
  };
}

function attachment(id: string, overrides: FakeRow = {}): FakeRow {
  return {
    id,
    memo_id: MEMO_ID,
    kind: "photo",
    storage_key: `${USER_A}/${MEMO_ID}/x.jpg`,
    filename: `${id}.jpg`,
    mime_type: "image/jpeg",
    size_bytes: 10,
    duration_sec: null,
    duration_ms: null,
    position: 0,
    ocr_text: null,
    transcript: null,
    ...overrides,
  };
}

describe("fetchMemoDetail", () => {
  it("returns the owned memo with ALL attachments in position order", async () => {
    const db = new FakePostgrest({
      memos: [memoRow()],
      memo_attachments: [
        attachment("aaaa2222-0000-4000-8000-000000000002", {
          kind: "audio",
          mime_type: "audio/m4a",
          position: 1,
          duration_ms: 1500,
        }),
        attachment("aaaa1111-0000-4000-8000-000000000001", { position: 0 }),
        attachment("aaaa3333-0000-4000-8000-000000000003", {
          kind: "file",
          mime_type: "application/pdf",
          position: 2,
        }),
        attachment("aaaa4444-0000-4000-8000-000000000004", {
          kind: "file",
          mime_type: "application/zip",
          position: 3,
        }),
      ],
    });
    const result = await fetchMemoDetail(supabaseMemoStore(db), USER_A, MEMO_ID);
    if (!result.ok) throw new Error("detail failed");
    expect(result.detail.memo.body).toBe("#会议 notes");
    expect(result.detail.attachments.map((a) => a.id)).toEqual([
      "aaaa1111-0000-4000-8000-000000000001",
      "aaaa2222-0000-4000-8000-000000000002",
      "aaaa3333-0000-4000-8000-000000000003",
      "aaaa4444-0000-4000-8000-000000000004",
    ]);
    expect(result.detail.attachments.map((a) => a.preview)).toEqual([
      "image",
      "audio",
      "file",
      "unknown", // legacy/unsupported MIME stays visible but unpreviewed
    ]);
    expect(result.detail.attachments[3].available).toBe(true);
  });

  it("distinguishes not-found (wrong user/tombstone) from unavailability", async () => {
    const db = new FakePostgrest({
      memos: [memoRow(), memoRow({ id: "c3333333-0000-4000-8000-000000000003", deleted_at: "2026-01-02T00:00:00+00:00" })],
      memo_attachments: [],
    });
    const store = supabaseMemoStore(db);

    expect((await fetchMemoDetail(store, USER_B, MEMO_ID)).ok).toBe(false);
    const wrongUser = await fetchMemoDetail(store, USER_B, MEMO_ID);
    expect(wrongUser.ok === false && wrongUser.reason).toBe("not-found");
    const tombstone = await fetchMemoDetail(store, USER_A, "c3333333-0000-4000-8000-000000000003");
    expect(tombstone.ok === false && tombstone.reason).toBe("not-found");

    const failing = {
      listMemos: () => Promise.resolve({ rows: [], error: null }),
      listAttachmentsByMemoIds: () => Promise.resolve({ rows: [], error: null }),
      getMemo: () => Promise.resolve({ rows: null, error: "boom" }),
      listAttachmentsForMemo: () => Promise.resolve({ rows: [], error: null }),
      getAttachmentForMemo: () => Promise.resolve({ rows: null, error: null }),
      listTagCataloguePage: () => Promise.resolve({ rows: [], error: null }),
      listMemoTagLinksPage: () => Promise.resolve({ rows: [], error: null }),
    };
    const unavailable = await fetchMemoDetail(failing, USER_A, MEMO_ID);
    expect(unavailable.ok === false && unavailable.reason).toBe("unavailable");
  });
});

// ---------------------------------------------------------------------------
// Imported-media presentation regressions (ADR-0026). All data is SYNTHETIC.
// The detail display body may be hidden ONLY when the whole body is exactly
// the importer's generated placeholder set for ALL attachments in order; the
// raw memo body stays byte-identical everywhere.
// ---------------------------------------------------------------------------

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
    memo_id: MEMO_ID,
    kind: args.kind,
    storage_key: `${USER_A}/${MEMO_ID}/${args.sha}.${args.storageExt}`,
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

async function fetchGenDetail(attachments: FakeRow[], body: string) {
  const db = new FakePostgrest({
    memos: [memoRow({ body })],
    memo_attachments: attachments,
  });
  const result = await fetchMemoDetail(supabaseMemoStore(db), USER_A, MEMO_ID);
  if (!result.ok) throw new Error("detail failed");
  return result.detail;
}

describe("imported media presentation (fetchMemoDetail)", () => {
  it("hides MemoBody's case only for the exact generated photo/audio/MOV ordered set", async () => {
    const body = [
      genLine("photo", "café 😀.png", SHA_PHOTO, "png"),
      genLine("audio", "note.m4a", SHA_AUDIO, "m4a"),
      genLine("file", "clip.mov", SHA_FILE, "mov"),
    ].join("\n");
    const detail = await fetchGenDetail(
      [
        genAttachment({
          id: "aaaa1111-0000-4000-8000-000000000001",
          kind: "photo",
          name: "café 😀.png",
          sha: SHA_PHOTO,
          storageExt: "png",
          position: 0,
        }),
        genAttachment({
          id: "aaaa2222-0000-4000-8000-000000000002",
          kind: "audio",
          name: "note.m4a",
          sha: SHA_AUDIO,
          storageExt: "m4a",
          position: 1,
        }),
        genAttachment({
          id: "aaaa3333-0000-4000-8000-000000000003",
          kind: "file",
          name: "clip.mov",
          sha: SHA_FILE,
          storageExt: "mov",
          position: 2,
        }),
      ],
      body,
    );
    expect(detail.memo.body).toBe(body); // raw body byte-identical
    expect(detail.presentationBody).toBe("");
    expect(detail.attachments.map((a) => a.id)).toEqual([
      "aaaa1111-0000-4000-8000-000000000001",
      "aaaa2222-0000-4000-8000-000000000002",
      "aaaa3333-0000-4000-8000-000000000003",
    ]);
  });

  it("accepts a .jpeg original only with the canonical .jpg cloud key", async () => {
    const body = genLine("photo", "scan.jpeg", SHA_PHOTO, "jpeg");
    const canonical = await fetchGenDetail(
      [
        genAttachment({
          id: "aaaa1111-0000-4000-8000-000000000001",
          kind: "photo",
          name: "scan.jpeg",
          sha: SHA_PHOTO,
          storageExt: "jpg",
          position: 0,
        }),
      ],
      body,
    );
    expect(canonical.presentationBody).toBe("");

    const nonCanonical = await fetchGenDetail(
      [
        genAttachment({
          id: "aaaa1111-0000-4000-8000-000000000001",
          kind: "photo",
          name: "scan.jpeg",
          sha: SHA_PHOTO,
          storageExt: "jpeg",
          position: 0,
        }),
      ],
      body,
    );
    expect(nonCanonical.presentationBody).toBeUndefined();
    expect(nonCanonical.memo.body).toBe(body);
  });

  it("preserves the raw body for every uncertain variant (no presentationBody)", async () => {
    const line = genLine("audio", "note.m4a", SHA_AUDIO, "m4a");
    const audio = (name: string | null, sha: string, position: number | null, overrides: FakeRow = {}) =>
      genAttachment({
        id: "aaaa2222-0000-4000-8000-000000000002",
        kind: "audio",
        name,
        sha,
        storageExt: "m4a",
        position,
        overrides,
      });
    const cases: Array<{ label: string; body: string; attachments: FakeRow[] }> = [
      { label: "prose around", body: `see\n${line}\n!`, attachments: [audio("note.m4a", SHA_AUDIO, 0)] },
      { label: "code fence", body: "```md\n" + line + "\n```", attachments: [audio("note.m4a", SHA_AUDIO, 0)] },
      {
        label: "markdown link body",
        body: `[Audio attachment: note.m4a](raw/assets/flomo/${SHA_AUDIO}.m4a "title")`,
        attachments: [audio("note.m4a", SHA_AUDIO, 0)],
      },
      {
        label: "wrong order",
        body: [genLine("photo", "a.png", SHA_PHOTO, "png"), genLine("audio", "note.m4a", SHA_AUDIO, "m4a")].join("\n"),
        attachments: [audio("note.m4a", SHA_AUDIO, 0), genAttachment({
          id: "aaaa1111-0000-4000-8000-000000000001",
          kind: "photo",
          name: "a.png",
          sha: SHA_PHOTO,
          storageExt: "png",
          position: 1,
        })],
      },
      { label: "wrong kind", body: genLine("file", "note.m4a", SHA_AUDIO, "m4a"), attachments: [audio("note.m4a", SHA_AUDIO, 0)] },
      { label: "wrong filename", body: genLine("audio", "Note.m4a", SHA_AUDIO, "m4a"), attachments: [audio("note.m4a", SHA_AUDIO, 0)] },
      {
        label: "canonical-equivalent byte-distinct name",
        body: genLine("audio", "café.m4a", SHA_AUDIO, "m4a"),
        attachments: [audio("cafe\u0301.m4a", SHA_AUDIO, 0)],
      },
      {
        label: "variation-selector glyph hash",
        body: genLine("audio", "note.m4a", `${"a".repeat(63)}\uFE0F`, "m4a"),
        attachments: [audio("note.m4a", SHA_AUDIO, 0)],
      },
      {
        label: "unicode control in name",
        body: genLine("audio", "no\u00ADte.m4a", SHA_AUDIO, "m4a"),
        attachments: [audio("no\u00ADte.m4a", SHA_AUDIO, 0)],
      },
      {
        label: "oversized basename",
        body: genLine("audio", "n".repeat(254) + ".m4a", SHA_AUDIO, "m4a"),
        attachments: [audio("n".repeat(254) + ".m4a", SHA_AUDIO, 0)],
      },
      {
        label: "traversal target",
        body: `[Audio attachment: note.m4a](raw/assets/flomo/../../${SHA_AUDIO}.m4a)`,
        attachments: [audio("note.m4a", SHA_AUDIO, 0)],
      },
      {
        label: "remote target",
        body: `[Audio attachment: note.m4a](https://example.com/${SHA_AUDIO}.m4a)`,
        attachments: [audio("note.m4a", SHA_AUDIO, 0)],
      },
      {
        label: "wrong owner",
        body: line,
        attachments: [audio("note.m4a", SHA_AUDIO, 0, { storage_key: `${USER_B}/${MEMO_ID}/${SHA_AUDIO}.m4a` })],
      },
      {
        label: "wrong memo",
        body: line,
        attachments: [audio("note.m4a", SHA_AUDIO, 0, { memo_id: "b2222222-0000-4000-8000-000000000002" })],
      },
      { label: "wrong SHA", body: line, attachments: [audio("note.m4a", SHA_FILE, 0)] },
      { label: "null position", body: line, attachments: [audio("note.m4a", SHA_AUDIO, null)] },
      {
        label: "duplicate positions",
        body: `${line}\n${genLine("audio", "second.m4a", SHA_FILE, "m4a")}`,
        attachments: [audio("note.m4a", SHA_AUDIO, 0), audio("second.m4a", SHA_FILE, 0)],
      },
      {
        label: "unsupported extension for kind",
        body: genLine("audio", "clip.mov", SHA_AUDIO, "mov"),
        attachments: [genAttachment({
          id: "aaaa2222-0000-4000-8000-000000000002",
          kind: "audio",
          name: "clip.mov",
          sha: SHA_AUDIO,
          storageExt: "mov",
          position: 0,
        })],
      },
      {
        label: "null filename legacy row",
        body: line,
        attachments: [audio(null, SHA_AUDIO, 0)],
      },
      {
        label: "legacy storage key",
        body: line,
        attachments: [audio("note.m4a", SHA_AUDIO, 0, { storage_key: "legacy-key.m4a" })],
      },
    ];
    for (const testCase of cases) {
      const detail = await fetchGenDetail(testCase.attachments, testCase.body);
      expect(detail.presentationBody, testCase.label).toBeUndefined();
      expect(detail.memo.body, testCase.label).toBe(testCase.body);
      expect(detail.attachments, testCase.label).toHaveLength(
        testCase.attachments.filter((a) => a.memo_id === MEMO_ID).length,
      );
    }
  });
});
