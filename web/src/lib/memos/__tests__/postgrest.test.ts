import { describe, it, expect } from "vitest";
import { createClient } from "@supabase/supabase-js";
import { buildKeysetOr, quoteFilterLiteral } from "../postgrest";
import { supabaseMemoStore, type QueryBuilderLike } from "../store";
import { FakePostgrest } from "./fake-postgrest";

describe("literal search through the installed Supabase SDK", () => {
  it("preserves special characters in the actual repository wire request", async () => {
    const userId = "11111111-1111-4111-8111-111111111111";
    const literals = ["*", "%", "_", "\\", '"', "a,b(c)", "(?i).*", "e\u0301", "topic/sub"];
    for (const q of literals) {
      let calls = 0;
      const client = createClient("https://example.invalid", "synthetic-public-key", {
        auth: { persistSession: false, autoRefreshToken: false },
        global: { fetch: async (input) => {
          calls++;
          const url = new URL(String(input));
          expect(url.searchParams.get("body")).toBe(`imatch.***=${q}`);
          expect(url.searchParams.get("user_id")).toBe(`eq.${userId}`);
          expect(url.searchParams.get("deleted_at")).toBe("is.null");
          expect(url.searchParams.has("or")).toBe(false);
          return new Response("[]", { headers: { "Content-Type": "application/json" } });
        } },
      });
      const store = supabaseMemoStore({ from: table => client.from(table) as unknown as QueryBuilderLike });
      const result = await store.listMemos({ userId, q, tag: null, type: null, fromIso: null, toIso: null, cursor: null, limit: 20 });
      expect(result.error).toBeNull();
      expect(calls).toBe(1);
    }
  });

  it("quotes only values embedded inside an or-group", () => {
    expect(quoteFilterLiteral('a"b\\c')).toBe('"a\\"b\\\\c"');
  });
});

describe("keyset or-filter", () => {
  const cursor = {
    createdAt: "2026-01-01T00:00:00.123456+00:00",
    id: "11111111-2222-4333-8444-555555555555",
  };

  it("is a parseable or-group the repository can send to PostgREST", async () => {
    const db = new FakePostgrest({ memos: [] });
    const { error } = await db.from("memos").select("*").or(buildKeysetOr(cursor));
    expect(error).toBeNull();
  });

  it("keeps the exact microsecond timestamp string in the filter", () => {
    expect(buildKeysetOr(cursor)).toContain("2026-01-01T00:00:00.123456+00:00");
    expect(buildKeysetOr(cursor)).not.toContain("2026-01-01T00:00:00.123Z");
  });

  it("selects only strictly older (created_at, id) pairs", async () => {
    const rows = [
      // Same timestamp, higher id — must be EXCLUDED (it sorts before the cursor row).
      { id: "99999999-2222-4333-8444-555555555555", created_at: cursor.createdAt, body: "same-ts-higher-id" },
      // Same timestamp, the cursor row itself — EXCLUDED (strict less-than).
      { id: cursor.id, created_at: cursor.createdAt, body: "cursor-row" },
      // Same timestamp, lower id — INCLUDED.
      { id: "00000000-2222-4333-8444-555555555555", created_at: cursor.createdAt, body: "same-ts-lower-id" },
      // One microsecond later — EXCLUDED.
      { id: "00000000-2222-4333-8444-555555555556", created_at: "2026-01-01T00:00:00.123457+00:00", body: "one-micro-newer" },
      // One microsecond earlier — INCLUDED even with a higher id.
      { id: "ffffffff-2222-4333-8444-555555555555", created_at: "2026-01-01T00:00:00.123455+00:00", body: "one-micro-older" },
    ];
    const db = new FakePostgrest({ memos: rows });
    const { data } = await db.from("memos").select("*").or(buildKeysetOr(cursor));
    const bodies = (data as Array<{ body: string }>).map((r) => r.body).sort();
    expect(bodies).toEqual(["one-micro-older", "same-ts-lower-id"]);
  });
});
