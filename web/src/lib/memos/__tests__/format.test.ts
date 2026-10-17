import { describe, it, expect } from "vitest";
import {
  formatDayKey,
  formatMemoAnchor,
  formatTimeOfDay,
  formatWeekday,
} from "../format";
import { loginRedirectTarget } from "../redirects";

describe("Asia/Shanghai display formatting", () => {
  it("converts stored instants to Asia/Shanghai wall time without mutating them", () => {
    const stored = "2026-01-01T16:30:00.123456Z";
    expect(formatDayKey(stored)).toBe("2026-01-02"); // rolls to the next day at +08:00
    expect(formatTimeOfDay(stored)).toBe("00:30");
    expect(formatWeekday(stored)).toBe("FRI");
    // the source value is untouched
    expect(stored).toBe("2026-01-01T16:30:00.123456Z");
  });

  it("formats the detail anchor consistently", () => {
    expect(formatMemoAnchor("2026-05-28T08:05:00+08:00")).toBe("THU · 2026-05-28 · 08:05");
  });

  it("is honest for unparseable timestamps", () => {
    expect(formatDayKey("not-a-date")).toBeNull();
    expect(formatTimeOfDay("not-a-date")).toBeNull();
    expect(formatMemoAnchor("not-a-date")).toBe("not-a-date");
  });
});

describe("login redirect target", () => {
  it("preserves the intended destination including query state", () => {
    expect(loginRedirectTarget("/memos?q=%23tag&cursor=abc")).toBe(
      `/login?callbackUrl=${encodeURIComponent("/memos?q=%23tag&cursor=abc")}`,
    );
  });

  it("rejects open-redirect shapes", () => {
    expect(loginRedirectTarget("//evil.example")).toBe("/login");
    expect(loginRedirectTarget("https://evil.example")).toBe("/login");
    expect(loginRedirectTarget("/\\evil")).toBe("/login");
    expect(loginRedirectTarget("/path\u0000evil")).toBe("/login");
    expect(loginRedirectTarget(null)).toBe("/login");
    expect(loginRedirectTarget(undefined)).toBe("/login");
    expect(loginRedirectTarget("")).toBe("/login");
  });
});
