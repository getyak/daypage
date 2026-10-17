// Exact imported tag surface (issue #884, canonical 0036).
//
// Covers: byte-exact label validation/parsing, metadata-only membership
// filtering (never body search), owner-scoped relation filtering BEFORE
// keyset/limit with a 1205-memo traversal on one label, complete catalogue and
// batched label reads past 1000 rows, and honest failure on tag-read errors.

import { describe, it, expect } from "vitest";
import { supabaseMemoStore } from "../store";
import { fetchMemoHistory } from "../history";
import { fetchMemoDetail } from "../detail";
import {
  fetchTagCatalogue,
  fetchTagsByMemoId,
  fetchTagsForMemo,
  validateTagLabel,
  compareUtf8Bytes,
  TAG_PAGE_SIZE,
  MAX_TAG_BYTES,
} from "../tags";
import { parseHistoryQuery, encodeCursor, type HistoryQuery } from "../query";
import type { MemoReadStore, MemoRow } from "../types";
import { FakePostgrest, type FakeRelation, type FakeRow } from "./fake-postgrest";

const USER_A = "11111111-2222-4333-8444-555555555555";
const USER_B = "22222222-2222-4333-8444-555555555555";

const TAG_RELATION: FakeRelation = {
  parentTable: "memos",
  childTable: "memo_tag_links",
  columns: [
    ["id", "memo_id"],
    ["user_id", "user_id"],
  ],
};

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

function link(memoId: string, label: string, overrides: FakeRow = {}): FakeRow {
  return { user_id: USER_A, memo_id: memoId, label, ...overrides };
}

function catalogue(label: string, overrides: FakeRow = {}): FakeRow {
  return { user_id: USER_A, label, in_import_catalog: true, ...overrides };
}

function queryOf(params: Record<string, string | string[] | undefined>): HistoryQuery {
  const parsed = parseHistoryQuery(params);
  if (!parsed.ok) throw new Error(`unexpected parse failure: ${parsed.errors.join(", ")}`);
  return parsed.query;
}

function seededDb(tables: Record<string, FakeRow[]>): FakePostgrest {
  return new FakePostgrest({ memo_tag_links: [], user_tags: [], ...tables }, [TAG_RELATION]);
}

describe("tag query validation — exact canonical labels", () => {
  it("preserves leading #, case, commas, slashes, UTF-8, spaces and punctuation exactly", () => {
    const labels = [
      "#a,b",
      "#父/子",
      "#父",
      "#Case",
      "#case",
      "#100%",
      "#a_b",
      "#hello, world/子",
      "#tag.with:punctuation!",
      "# leading space",
    ];
    for (const label of labels) {
      expect(validateTagLabel(label)).toBe(label);
      const parsed = parseHistoryQuery({ tag: label });
      expect(parsed.ok).toBe(true);
      if (parsed.ok) expect(parsed.query.tag).toBe(label);
    }
    // No normalization or comma splitting: distinct cases stay distinct.
    expect(validateTagLabel("#Case")).not.toBe(validateTagLabel("#case"));
    // % and _ survive as literal bytes (never LIKE wildcards).
    expect(validateTagLabel("#100%")).toBe("#100%");
    expect(validateTagLabel("#a_b")).toBe("#a_b");
  });

  it("rejects malformed labels: no #, empty suffix, controls, oversized", () => {
    const invalid = [
      "#",
      "abc",
      "#a\u0001b",
      "#a\u007fb",
      "#a\nb",
      "#a\u0000b",
      "#\u001f",
      `#${"a".repeat(MAX_TAG_BYTES)}`, // 1025 bytes — over the canonical cap
    ];
    for (const raw of invalid) {
      expect(validateTagLabel(raw), raw).toBeNull();
      const parsed = parseHistoryQuery({ tag: raw });
      expect(parsed.ok, raw).toBe(false);
    }
    // Exact canonical bounds: 1024 UTF-8 bytes accepted, one more rejected.
    expect(validateTagLabel(`#${"a".repeat(MAX_TAG_BYTES - 1)}`)).not.toBeNull();
    expect(validateTagLabel(`#${"中".repeat(341)}`)).not.toBeNull(); // 1 + 341*3 = 1024
    expect(validateTagLabel(`#${"中".repeat(342)}`)).toBeNull();
  });

  it("rejects repeated tag parameters and treats empty tag as cleared", () => {
    expect(parseHistoryQuery({ tag: ["#a", "#b"] }).ok).toBe(false);
    const cleared = parseHistoryQuery({ tag: "" });
    expect(cleared.ok).toBe(true);
    if (cleared.ok) expect(cleared.query.tag).toBeNull();
  });

  it("keeps q and tag independent — q is literal body text, tag is metadata", () => {
    const parsed = parseHistoryQuery({ q: "#a,b", tag: "#x,y" });
    expect(parsed.ok).toBe(true);
    if (parsed.ok) {
      expect(parsed.query.q).toBe("#a,b");
      expect(parsed.query.tag).toBe("#x,y");
    }
  });
});

describe("exact tag membership filtering — metadata only", () => {
  it("finds metadata-only memberships and never body-matches", async () => {
    const db = seededDb({
      memos: [
        memo("11111111-0000-4000-8000-000000000001", "2026-01-01T00:00:00.000001+00:00", {
          body: "plain body, no hashtag",
        }),
        memo("22222222-0000-4000-8000-000000000002", "2026-01-01T00:00:00.000002+00:00", {
          body: "#a,b is only body text here",
        }),
      ],
      memo_tag_links: [link("11111111-0000-4000-8000-000000000001", "#a,b")],
    });
    const store = supabaseMemoStore(db);

    const byTag = await fetchMemoHistory(store, USER_A, queryOf({ tag: "#a,b" }));
    if (!byTag.ok) throw new Error("tag fetch failed");
    expect(byTag.items.map((i) => i.id)).toEqual(["11111111-0000-4000-8000-000000000001"]);
    expect(byTag.items[0].tags).toEqual(["#a,b"]);

    // q stays a separate literal body search.
    const byBody = await fetchMemoHistory(store, USER_A, queryOf({ q: "#a,b" }));
    if (!byBody.ok) throw new Error("q fetch failed");
    expect(byBody.items.map((i) => i.id)).toEqual(["22222222-0000-4000-8000-000000000002"]);
    expect(byBody.items[0].tags).toEqual([]);
  });

  it("is exact for #Case/#case, % and _ literals, and never splits commas", async () => {
    const rows = [
      ["11111111-0000-4000-8000-000000000001", "#Case"],
      ["22222222-0000-4000-8000-000000000002", "#case"],
      ["33333333-0000-4000-8000-000000000003", "#100%"],
      ["44444444-0000-4000-8000-000000000004", "#1005"],
      ["55555555-0000-4000-8000-000000000005", "#a_b"],
      ["66666666-0000-4000-8000-000000000006", "#axb"],
      ["77777777-0000-4000-8000-000000000007", "#x,y"],
      ["88888888-0000-4000-8000-000000000008", "#x"],
      ["99999999-0000-4000-8000-000000000009", "#y"],
    ] as const;
    const db = seededDb({
      memos: rows.map(([id], i) => memo(id, `2026-01-01T00:00:00.${String(i).padStart(6, "0")}+00:00`)),
      memo_tag_links: rows.map(([id, label]) => link(id, label)),
    });
    const store = supabaseMemoStore(db);

    async function idsFor(tag: string): Promise<string[]> {
      const result = await fetchMemoHistory(store, USER_A, queryOf({ tag }));
      if (!result.ok) throw new Error("fetch failed");
      return result.items.map((i) => i.id);
    }

    expect(await idsFor("#Case")).toEqual(["11111111-0000-4000-8000-000000000001"]);
    expect(await idsFor("#case")).toEqual(["22222222-0000-4000-8000-000000000002"]);
    // % and _ are literal bytes, never LIKE wildcards.
    expect(await idsFor("#100%")).toEqual(["33333333-0000-4000-8000-000000000003"]);
    expect(await idsFor("#a_b")).toEqual(["55555555-0000-4000-8000-000000000005"]);
    // "#x,y" is ONE exact label — not "#x" plus "#y".
    expect(await idsFor("#x,y")).toEqual(["77777777-0000-4000-8000-000000000007"]);
    expect(await idsFor("#x")).toEqual(["88888888-0000-4000-8000-000000000008"]);
  });

  it("never invents parent membership for '/' hierarchies", async () => {
    const db = seededDb({
      memos: [
        memo("11111111-0000-4000-8000-000000000001", "2026-01-01T00:00:00.000001+00:00"),
        memo("22222222-0000-4000-8000-000000000002", "2026-01-01T00:00:00.000002+00:00"),
        memo("33333333-0000-4000-8000-000000000003", "2026-01-01T00:00:00.000003+00:00"),
      ],
      memo_tag_links: [
        link("11111111-0000-4000-8000-000000000001", "#父/子"),
        link("22222222-0000-4000-8000-000000000002", "#父"),
        link("33333333-0000-4000-8000-000000000003", "#子"),
      ],
    });
    const store = supabaseMemoStore(db);

    const child = await fetchMemoHistory(store, USER_A, queryOf({ tag: "#父/子" }));
    if (!child.ok) throw new Error("fetch failed");
    expect(child.items.map((i) => i.id)).toEqual(["11111111-0000-4000-8000-000000000001"]);

    const parent = await fetchMemoHistory(store, USER_A, queryOf({ tag: "#父" }));
    if (!parent.ok) throw new Error("fetch failed");
    expect(parent.items.map((i) => i.id)).toEqual(["22222222-0000-4000-8000-000000000002"]);
  });

  it("excludes other users' memberships and tombstoned memos", async () => {
    const db = seededDb({
      memos: [
        memo("11111111-0000-4000-8000-000000000001", "2026-01-01T00:00:00.000001+00:00"),
        memo("22222222-0000-4000-8000-000000000002", "2026-01-01T00:00:00.000002+00:00", {
          deleted_at: "2026-01-02T00:00:00+00:00",
        }),
      ],
      memo_tag_links: [
        link("11111111-0000-4000-8000-000000000001", "#mine"),
        // Same label under another owner — never visible to USER_A.
        link("11111111-0000-4000-8000-000000000001", "#theirs", { user_id: USER_B }),
        link("22222222-0000-4000-8000-000000000002", "#tombstoned"),
      ],
    });
    const store = supabaseMemoStore(db);

    const mine = await fetchMemoHistory(store, USER_A, queryOf({ tag: "#mine" }));
    if (!mine.ok) throw new Error("fetch failed");
    expect(mine.items).toHaveLength(1);

    const theirs = await fetchMemoHistory(store, USER_A, queryOf({ tag: "#theirs" }));
    if (!theirs.ok) throw new Error("fetch failed");
    expect(theirs.items).toEqual([]);

    const tombstoned = await fetchMemoHistory(store, USER_A, queryOf({ tag: "#tombstoned" }));
    if (!tombstoned.ok) throw new Error("fetch failed");
    expect(tombstoned.items).toEqual([]);
  });

  it("keeps owner/tombstone/q/type/date/cursor combinations exact", async () => {
    // Day 1 rows with increasing seconds; row 6 lives outside the day window.
    const ts = (i: number) =>
      i === 6
        ? "2026-01-05T01:02:06.000006+00:00"
        : `2026-01-01T01:02:0${i}.00000${i}+00:00`;
    const db = seededDb({
      memos: [
        memo("11111111-0000-4000-8000-000000000001", ts(1), { body: "alpha one", type: "text" }),
        memo("22222222-0000-4000-8000-000000000002", ts(2), { body: "alpha two", type: "text" }),
        memo("33333333-0000-4000-8000-000000000003", ts(3), { body: "alpha three", type: "voice" }),
        memo("44444444-0000-4000-8000-000000000004", ts(4), { body: "alpha four", type: "text" }),
        memo("55555555-0000-4000-8000-000000000005", ts(5), {
          body: "alpha five",
          type: "text",
          deleted_at: "2026-02-01T00:00:00+00:00",
        }),
        memo("66666666-0000-4000-8000-000000000006", ts(6), { body: "alpha six", type: "text" }),
        memo("77777777-0000-4000-8000-000000000007", ts(7), { body: "alpha seven", type: "text" }),
      ],
      memo_tag_links: [
        link("11111111-0000-4000-8000-000000000001", "#a,b"),
        link("22222222-0000-4000-8000-000000000002", "#a,b"),
        link("33333333-0000-4000-8000-000000000003", "#a,b"),
        link("44444444-0000-4000-8000-000000000004", "#a,b"),
        link("55555555-0000-4000-8000-000000000005", "#a,b"),
        link("66666666-0000-4000-8000-000000000006", "#a,b"),
        link("77777777-0000-4000-8000-000000000007", "#other"),
      ],
    });
    const store = supabaseMemoStore(db);

    const combined = queryOf({
      tag: "#a,b",
      q: "alpha",
      type: "text",
      from: "2026-01-01",
      to: "2026-01-01",
    });
    // Survivors of tag+q+type+day: rows 4, 2, 1 (newest first).
    // Excluded: row 3 (voice), row 5 (tombstone), row 6 (outside the day),
    // row 7 (different exact label).
    const page1 = await fetchMemoHistory(store, USER_A, { ...combined, limit: 1 });
    if (!page1.ok) throw new Error("fetch failed");
    expect(page1.items.map((i) => i.id)).toEqual(["44444444-0000-4000-8000-000000000004"]);
    expect(page1.hasMore).toBe(true);

    const page2 = await fetchMemoHistory(store, USER_A, {
      ...combined,
      limit: 1,
      cursor: page1.nextCursor ? decodeCursorOrThrow(page1.nextCursor) : null,
    });
    if (!page2.ok) throw new Error("fetch failed");
    expect(page2.items.map((i) => i.id)).toEqual(["22222222-0000-4000-8000-000000000002"]);

    const page3 = await fetchMemoHistory(store, USER_A, {
      ...combined,
      limit: 1,
      cursor: page2.nextCursor ? decodeCursorOrThrow(page2.nextCursor) : null,
    });
    if (!page3.ok) throw new Error("fetch failed");
    expect(page3.items.map((i) => i.id)).toEqual(["11111111-0000-4000-8000-000000000001"]);
    expect(page3.hasMore).toBe(false);
    expect(page3.nextCursor).toBeNull();
  });
});

function decodeCursorOrThrow(raw: string): HistoryQuery["cursor"] {
  const parsed = parseHistoryQuery({ cursor: raw });
  if (!parsed.ok) throw new Error("cursor did not round-trip");
  return parsed.query.cursor;
}

describe("relation filtering before keyset/limit — 1205 memos on one label", () => {
  it("traverses all 1205 members of #big via the microsecond (created_at,id) keyset with no duplicates or gaps", async () => {
    const TAGGED = 1205;
    const memos: FakeRow[] = [];
    const links: FakeRow[] = [];
    const expected: string[] = [];
    for (let i = 0; i < TAGGED + 20; i += 1) {
      const id = `${String(i).padStart(8, "0")}-0000-4000-8000-${String(i).padStart(12, "0")}`;
      // Ties everywhere on created_at so the id tiebreaker is exercised.
      const createdAt = `2026-03-01T00:00:00.${String(i % 7).padStart(6, "0")}+00:00`;
      const tagged = i < TAGGED;
      memos.push(memo(id, createdAt, { body: tagged ? "tagged body" : "untagged body" }));
      if (tagged) {
        links.push(link(id, "#big"));
        expected.push(id);
      } else {
        links.push(link(id, "#distractor"));
      }
    }
    const db = seededDb({ memos, memo_tag_links: links });
    const store = supabaseMemoStore(db);

    const seen: string[] = [];
    let cursor: HistoryQuery["cursor"] = null;
    let pages = 0;
    for (let guard = 0; guard < 40; guard += 1) {
      const page = await fetchMemoHistory(
        store,
        USER_A,
        queryOf({
          tag: "#big",
          limit: "50",
          cursor: cursor ? encodeCursor(cursor) : undefined,
        }),
      );
      if (!page.ok) throw new Error("page failed");
      pages += 1;
      seen.push(...page.items.map((i) => i.id));
      if (!page.hasMore) break;
      cursor = decodeCursorOrThrow(page.nextCursor as string);
      // Full pages are exactly the page size — filtering is NOT page-local.
      expect(page.items).toHaveLength(50);
    }

    expect(pages).toBe(Math.ceil(TAGGED / 50));
    expect(seen).toHaveLength(TAGGED);
    expect(new Set(seen).size).toBe(TAGGED);
    expect(new Set(seen)).toEqual(new Set(expected));

    // The membership filter lives on the memos query as an inner relation —
    // never a prefetch of link ids followed by .in().
    const projections = db.calls
      .filter((c) => c.table === "memos" && c.op === "projection")
      .map((c) => String(c.detail));
    expect(projections.length).toBeGreaterThan(0);
    expect(projections.every((p) => p.includes("memo_tag_links!inner(label)"))).toBe(true);

    // ONE batched label query per page — no per-memo N+1.
    expect(db.countCalls("memo_tag_links", "from")).toBe(pages);
    expect(db.countCalls("memos", "from")).toBe(pages);
  }, 30000);
});

describe("complete catalogue and batched labels beyond 1000 rows", () => {
  it("traverses a 2400-label catalogue completely, including unused labels", async () => {
    const COUNT = 2400;
    const rows: FakeRow[] = [];
    for (let i = 0; i < COUNT; i += 1) {
      rows.push(catalogue(`#c${String(i).padStart(4, "0")}`, { in_import_catalog: i % 2 === 0 }));
    }
    // Deliberately give one label zero memberships — the catalogue still lists it.
    const db = seededDb({
      user_tags: rows,
      memos: [],
      memo_tag_links: [],
    });
    const store = supabaseMemoStore(db);

    const result = await fetchTagCatalogue(store, USER_A);
    expect(result.error).toBeNull();
    expect(result.rows).toHaveLength(COUNT);
    expect(result.rows).toContain("#c0000");
    expect(result.rows).toContain(`#c${String(COUNT - 1).padStart(4, "0")}`);
    expect(result.rows).toEqual([...(result.rows as string[])].sort());
    // Bounded pages of 1000, traversed explicitly — never one capped response.
    expect(db.countCalls("user_tags", "from")).toBe(Math.ceil(COUNT / TAG_PAGE_SIZE));
  });

  it("completes batched labels past 1000 rows for displayed memos", async () => {
    const memo1 = "11111111-0000-4000-8000-000000000001";
    const memo2 = "22222222-0000-4000-8000-000000000002";
    const links: FakeRow[] = [];
    for (let i = 0; i < 700; i += 1) {
      links.push(link(memo1, `#a${String(i).padStart(4, "0")}`));
      links.push(link(memo2, `#b${String(i).padStart(4, "0")}`));
    }
    const db = seededDb({ memos: [], memo_tag_links: links });
    const store = supabaseMemoStore(db);

    const result = await fetchTagsByMemoId(store, USER_A, [memo1, memo2]);
    expect(result.error).toBeNull();
    expect(result.rows?.get(memo1)).toHaveLength(700);
    expect(result.rows?.get(memo2)).toHaveLength(700);
    // 1400 rows in bounded 1000-row pages: two batched queries, no N+1.
    expect(db.countCalls("memo_tag_links", "from")).toBe(2);
  });

  it("completes one memo with 1205 exact labels", async () => {
    const memo1 = "11111111-0000-4000-8000-000000000001";
    const links: FakeRow[] = [];
    for (let i = 0; i < 1205; i += 1) {
      links.push(link(memo1, `#solo${String(i).padStart(4, "0")}`));
    }
    const db = seededDb({ memos: [], memo_tag_links: links });
    const store = supabaseMemoStore(db);

    const result = await fetchTagsForMemo(store, USER_A, memo1);
    expect(result.error).toBeNull();
    expect(result.rows).toHaveLength(1205);
    expect(new Set(result.rows).size).toBe(1205);
    expect(db.countCalls("memo_tag_links", "from")).toBe(2);
  });
});

describe("honest failures and detail tags", () => {
  const failingTags: MemoReadStore = {
    listMemos: () =>
      Promise.resolve({
        rows: [
          memo("11111111-0000-4000-8000-000000000001", "2026-01-01T00:00:00.000000+00:00") as unknown as MemoRow,
        ],
        error: null,
      }),
    listAttachmentsByMemoIds: () => Promise.resolve({ rows: [], error: null }),
    getMemo: () =>
      Promise.resolve({
        rows: memo("11111111-0000-4000-8000-000000000001", "2026-01-01T00:00:00.000000+00:00") as unknown as MemoRow,
        error: null,
      }),
    listAttachmentsForMemo: () => Promise.resolve({ rows: [], error: null }),
    getAttachmentForMemo: () => Promise.resolve({ rows: null, error: null }),
    listTagCataloguePage: () =>
      Promise.resolve({ rows: null, error: 'relation "user_tags" does not exist' }),
    listMemoTagLinksPage: () =>
      Promise.resolve({ rows: null, error: 'relation "memo_tag_links" does not exist' }),
  };

  it("returns unavailable on tag-read errors — never a fake empty successful list", async () => {
    const catalogue = await fetchTagCatalogue(failingTags, USER_A);
    expect(catalogue.rows).toBeNull();
    expect(catalogue.error).toBeTruthy();

    const history = await fetchMemoHistory(failingTags, USER_A, queryOf({}));
    expect(history).toEqual({ ok: false, reason: "unavailable" });

    const detail = await fetchMemoDetail(failingTags, USER_A, "11111111-0000-4000-8000-000000000001");
    expect(detail.ok === false && detail.reason).toBe("unavailable");
  });

  it("shows exact metadata tags on memo detail", async () => {
    const memoId = "11111111-0000-4000-8000-000000000001";
    const db = seededDb({
      memos: [memo(memoId, "2026-01-01T00:00:00.000000+00:00", { body: "#会议" })],
      memo_tag_links: [link(memoId, "#a,b"), link(memoId, "#父/子"), link(memoId, "#Case")],
    });
    const store = supabaseMemoStore(db);
    const result = await fetchMemoDetail(store, USER_A, memoId);
    if (!result.ok) throw new Error("detail failed");
    expect(result.detail.tags.sort()).toEqual(["#Case", "#a,b", "#父/子"].sort());
    // Body hashtag text stays untouched — tags come only from metadata.
    expect(result.detail.memo.body).toBe("#会议");
  });
});

describe("C-collation (UTF-8 byte) keyset boundaries", () => {
  // Canonical labels are `text COLLATE "C"`: ordered by UTF-8 BYTES. At the
  // BMP/astral boundary that order is the OPPOSITE of JavaScript's UTF-16 one,
  // so keyset page-advance checks using `>` would falsely reject a page the DB
  // legitimately returns after `#\uE000`.
  const BMP_EDGE = "#\uE000"; // UTF-8: EE 80 80
  const ASTRAL = "#😀"; // UTF-8: F0 9F 98 80

  function stub(overrides: Partial<MemoReadStore>): MemoReadStore {
    return {
      listMemos: () => Promise.resolve({ rows: [], error: null }),
      listAttachmentsByMemoIds: () => Promise.resolve({ rows: [], error: null }),
      getMemo: () => Promise.resolve({ rows: null, error: null }),
      listAttachmentsForMemo: () => Promise.resolve({ rows: [], error: null }),
      getAttachmentForMemo: () => Promise.resolve({ rows: null, error: null }),
      listTagCataloguePage: () => Promise.resolve({ rows: [], error: null }),
      listMemoTagLinksPage: () => Promise.resolve({ rows: [], error: null }),
      ...overrides,
    };
  }

  it("compareUtf8Bytes matches COLLATE C where UTF-16 order disagrees", () => {
    expect(compareUtf8Bytes(BMP_EDGE, ASTRAL)).toBeLessThan(0);
    expect(compareUtf8Bytes(ASTRAL, BMP_EDGE)).toBeGreaterThan(0);
    expect(compareUtf8Bytes(ASTRAL, `${ASTRAL}x`)).toBeLessThan(0);
    expect(compareUtf8Bytes("#a", "#a")).toBe(0);
    // Documented trap: JavaScript UTF-16 comparison says the OPPOSITE here.
    expect(BMP_EDGE > ASTRAL).toBe(true);
  });

  it("traverses a catalogue whose 1000-row page boundary crosses the BMP/astral split", async () => {
    const rows: FakeRow[] = [];
    for (let i = 0; i < 999; i += 1) rows.push(catalogue(`#a${String(i).padStart(4, "0")}`));
    rows.push(catalogue(BMP_EDGE));
    rows.push(catalogue(ASTRAL));
    rows.push(catalogue(`${ASTRAL}x`));
    const db = seededDb({ user_tags: rows, memos: [], memo_tag_links: [] });
    const store = supabaseMemoStore(db);

    const result = await fetchTagCatalogue(store, USER_A);
    expect(result.error).toBeNull();
    const labels = result.rows as string[];
    expect(labels).toHaveLength(1002);
    // C order across the page boundary: page 1 ends at #\uE000, page 2 opens
    // with the astral label — no duplicates, no gaps, no false "did not
    // advance" error.
    expect(labels[999]).toBe(BMP_EDGE);
    expect(labels[1000]).toBe(ASTRAL);
    expect(labels[1001]).toBe(`${ASTRAL}x`);
    expect(db.countCalls("user_tags", "from")).toBe(2);
  });

  it("traverses one memo's 1002 memberships across the same boundary", async () => {
    const memo1 = "11111111-0000-4000-8000-000000000001";
    const links: FakeRow[] = [];
    for (let i = 0; i < 999; i += 1) links.push(link(memo1, `#a${String(i).padStart(4, "0")}`));
    links.push(link(memo1, BMP_EDGE));
    links.push(link(memo1, ASTRAL));
    links.push(link(memo1, `${ASTRAL}x`));
    const db = seededDb({ memos: [], memo_tag_links: links });
    const store = supabaseMemoStore(db);

    const result = await fetchTagsForMemo(store, USER_A, memo1);
    expect(result.error).toBeNull();
    const labels = result.rows as string[];
    expect(labels).toHaveLength(1002);
    expect(labels[999]).toBe(BMP_EDGE);
    expect(labels[1000]).toBe(ASTRAL);
    expect(db.countCalls("memo_tag_links", "from")).toBe(2);
  });

  it("still rejects a non-advancing catalogue page", async () => {
    const page = Array.from({ length: TAG_PAGE_SIZE }, (_, i) => ({
      label: `#a${String(i).padStart(4, "0")}`,
      in_import_catalog: true,
    }));
    // Ignores the keyset and resends the same 1000-row page forever.
    const store = stub({
      listTagCataloguePage: () => Promise.resolve({ rows: page, error: null }),
    });
    const result = await fetchTagCatalogue(store, USER_A);
    expect(result.rows).toBeNull();
    expect(result.error).toBeTruthy();
  });

  it("rejects a backward page at the BMP/astral boundary even though UTF-16 would call it advancing", async () => {
    const first = Array.from({ length: TAG_PAGE_SIZE - 1 }, (_, i) => ({
      label: `#a${String(i).padStart(4, "0")}`,
      in_import_catalog: true,
    }));
    const store = stub({
      listTagCataloguePage: ({ afterLabel }) =>
        Promise.resolve({
          rows:
            afterLabel === null
              ? [...first, { label: ASTRAL, in_import_catalog: true }]
              : [{ label: BMP_EDGE, in_import_catalog: true }],
          error: null,
        }),
    });
    // UTF-16 calls BMP_EDGE "greater" than ASTRAL; C order sees a step
    // BACKWARD and must reject instead of looping or returning a wrong set.
    expect(BMP_EDGE > ASTRAL).toBe(true);
    const result = await fetchTagCatalogue(store, USER_A);
    expect(result.rows).toBeNull();
    expect(result.error).toBeTruthy();
  });

  it("rejects non-advancing memo membership pages on the composite keyset", async () => {
    const memo1 = "11111111-0000-4000-8000-000000000001";
    const first = Array.from({ length: TAG_PAGE_SIZE - 1 }, (_, i) => ({
      memo_id: memo1,
      label: `#a${String(i).padStart(4, "0")}`,
    }));
    const store = stub({
      listMemoTagLinksPage: ({ after }) =>
        Promise.resolve({
          rows:
            after === null
              ? [...first, { memo_id: memo1, label: ASTRAL }]
              : [{ memo_id: memo1, label: BMP_EDGE }],
          error: null,
        }),
    });
    const result = await fetchTagsByMemoId(store, USER_A, [memo1]);
    expect(result.rows).toBeNull();
    expect(result.error).toBeTruthy();
  });
});
