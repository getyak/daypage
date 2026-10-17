import { describe, it, expect } from "vitest";
import {
  decodeCursor,
  encodeCursor,
  isDbTimestamp,
  isUuid,
  parseHistoryQuery,
  shanghaiDayStartIso,
} from "../query";

describe("cursor codec", () => {
  it("preserves the original database timestamp string including microseconds", () => {
    const raw = "2026-03-04T05:06:07.123456+08:00";
    const cursor = decodeCursor(encodeCursor({ createdAt: raw, id: "11111111-2222-4333-8444-555555555555" }));
    expect(cursor).toEqual({ createdAt: raw, id: "11111111-2222-4333-8444-555555555555" });
  });

  it("keeps 6-digit microsecond strings un-truncated", () => {
    const raw = "2026-03-04T05:06:07.999999+00:00";
    const decoded = decodeCursor(encodeCursor({ createdAt: raw, id: "11111111-2222-4333-8444-555555555555" }));
    expect(decoded?.createdAt).toBe(raw);
  });

  it("rejects malformed cursors", () => {
    const id = "11111111-2222-4333-8444-555555555555";
    expect(decodeCursor("not-base64!!")).toBeNull();
    expect(decodeCursor(Buffer.from("{}", "utf8").toString("base64url"))).toBeNull();
    expect(decodeCursor(Buffer.from(JSON.stringify({ c: "x", i: id }), "utf8").toString("base64url"))).toBeNull();
    expect(
      decodeCursor(
        Buffer.from(
          JSON.stringify({ c: "2026-03-04T05:06:07.1+00:00", i: "not-a-uuid" }),
          "utf8",
        ).toString("base64url"),
      ),
    ).toBeNull();
    expect(
      decodeCursor(
        Buffer.from(
          JSON.stringify({ c: "2026-03-04T05:06:07.1+00:00", i: id, extra: 1 }),
          "utf8",
        ).toString("base64url"),
      ),
    ).toBeNull();
    // Non-canonical base64url payload is rejected rather than silently accepted.
    const canonical = encodeCursor({ createdAt: "2026-03-04T05:06:07.1+00:00", id });
    expect(decodeCursor(`${canonical}=`)).toBeNull();
  });

  it("validates timestamp and uuid shapes", () => {
    expect(isDbTimestamp("2026-03-04T05:06:07.123456+00:00")).toBe(true);
    expect(isDbTimestamp("2026-03-04T05:06:07Z")).toBe(true);
    expect(isDbTimestamp("2026-03-04 05:06:07")).toBe(false);
    expect(isDbTimestamp("2026-03-04T05:06:07.1234567+00:00")).toBe(false);
    for (const invalid of ["2026-02-30T05:06:07Z", "2026-03-04T99:99:99.123456+99:99", "2026-03-04T24:00:00Z", "2026-03-04T05:06:07+08:60", "0000-01-01T00:00:00Z"]) {
      expect(isDbTimestamp(invalid), invalid).toBe(false);
    }
    expect(isDbTimestamp("2024-02-29T23:59:59.000001+08:00")).toBe(true);
    expect(isUuid("11111111-2222-4333-8444-555555555555")).toBe(true);
    expect(isUuid("11111111-2222-4333-8444")).toBe(false);
  });
});

describe("parseHistoryQuery", () => {
  it("applies bounded defaults", () => {
    const parsed = parseHistoryQuery({});
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    expect(parsed.query).toEqual({
      q: null,
      type: null,
      tag: null,
      fromIso: null,
      toIso: null,
      cursor: null,
      limit: 20,
    });
  });

  it("accepts a strict combination and maps dates to Asia/Shanghai day bounds", () => {
    const parsed = parseHistoryQuery({
      q: "  weekly  ",
      type: "voice",
      from: "2026-01-01",
      to: "2026-01-31",
      limit: "5",
    });
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    expect(parsed.query.q).toBe("weekly");
    expect(parsed.query.type).toBe("voice");
    expect(parsed.query.fromIso).toBe("2026-01-01T00:00:00+08:00");
    // `to` is inclusive as a calendar day: the bound is the NEXT day's start.
    expect(parsed.query.toIso).toBe("2026-02-01T00:00:00+08:00");
    expect(parsed.query.limit).toBe(5);
  });

  it("rolls `to` across month and year boundaries", () => {
    expect(shanghaiDayStartIso("2026-12-31")).toBe("2026-12-31T00:00:00+08:00");
    const parsed = parseHistoryQuery({ to: "2026-12-31" });
    expect(parsed.ok && parsed.query.toIso).toBe("2027-01-01T00:00:00+08:00");
    const early = parseHistoryQuery({ to: "0999-12-30" });
    expect(early.ok && early.query.toIso).toBe("0999-12-31T00:00:00+08:00");
    expect(parseHistoryQuery({ from: "0999-12-31", to: "0999-12-30" }).ok).toBe(false);
    const latest = parseHistoryQuery({ from: "2026-01-01", to: "9999-12-31" });
    expect(latest.ok && latest.query.toIso).toBe("10000-01-01T00:00:00+08:00");
  });

  it("rejects malformed search literals", () => {
    const long = parseHistoryQuery({ q: "x".repeat(201) });
    expect(long.ok).toBe(false);
    const control = parseHistoryQuery({ q: "ok\u0000bad" });
    expect(control.ok).toBe(false);
    const quote = parseHistoryQuery({ q: 'a",user_id.eq."b' });
    expect(quote.ok).toBe(true);
  });

  it("still allows literal SQL/PostgREST metacharacters in q (they are escaped later)", () => {
    const parsed = parseHistoryQuery({ q: "50%_\\ (a,b) * c" });
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    expect(parsed.query.q).toBe("50%_\\ (a,b) * c");
  });

  it("rejects invalid type, dates, order and limits", () => {
    expect(parseHistoryQuery({ type: "memo" }).ok).toBe(false);
    expect(parseHistoryQuery({ from: "2026-02-30" }).ok).toBe(false);
    expect(parseHistoryQuery({ to: "01/02/2026" }).ok).toBe(false);
    expect(parseHistoryQuery({ from: "2026-02-01", to: "2026-01-01" }).ok).toBe(false);
    expect(parseHistoryQuery({ limit: "0" }).ok).toBe(false);
    expect(parseHistoryQuery({ limit: "51" }).ok).toBe(false);
    expect(parseHistoryQuery({ limit: "3.5" }).ok).toBe(false);
  });

  it("rejects repeated (array) parameters and malformed cursors", () => {
    expect(parseHistoryQuery({ q: ["a", "b"] }).ok).toBe(false);
    expect(parseHistoryQuery({ cursor: "%%%" }).ok).toBe(false);
    const cursor = encodeCursor({ createdAt: "2026-01-01T00:00:00.5+00:00", id: "11111111-2222-4333-8444-555555555555" });
    expect(parseHistoryQuery({ cursor }).ok).toBe(true);
  });
});
