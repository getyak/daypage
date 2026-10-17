// Tag chips and the tag selector (issue #884).
//
// Chips carry the FULL exact label URL-encoded into `?tag=`; long labels wrap
// without overflowing; the selector lists the complete exact catalogue
// (including unused labels) with no fake counts and preserves the selection.

import { describe, it, expect } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import { createElement } from "react";
import { MemoTags } from "../../../app/(app)/memos/_components/MemoTags";
import { TagFilter } from "../../../app/(app)/memos/_components/TagFilter";

function renderTags(tags: string[]): string {
  return renderToStaticMarkup(createElement(MemoTags, { tags }));
}

function renderFilter(catalogue: string[], value: string | null): string {
  return renderToStaticMarkup(createElement(TagFilter, { catalogue, value }));
}

describe("MemoTags chips", () => {
  it("carries the full exact label URL-encoded into ?tag=", () => {
    const html = renderTags(["#a,b", "#父/子", "#Case", "#case", "#100%", "#a_b"]);
    expect(html).toContain('href="/memos?tag=%23a%2Cb"');
    expect(html).toContain('href="/memos?tag=%23%E7%88%B6%2F%E5%AD%90"');
    expect(html).toContain('href="/memos?tag=%23Case"');
    expect(html).toContain('href="/memos?tag=%23case"');
    expect(html).toContain('href="/memos?tag=%23100%25"');
    expect(html).toContain('href="/memos?tag=%23a_b"');
    // Original labels are the chip TEXT — never normalized or re-encoded.
    expect(html).toContain("#a,b");
    expect(html).toContain("#父/子");
    expect(html).toContain("#Case");
    expect(html).toContain("#case");
  });

  it("keeps long labels wrapping instead of overflowing", () => {
    const longLabel = `#${"w".repeat(240)}/with,commas,and spaces`;
    const html = renderTags([longLabel]);
    // Flex wrapping container + breakable chip, both bounded to the container.
    expect(html).toContain("flex-wrap:wrap");
    expect(html).toContain("overflow-wrap:anywhere");
    expect(html).toContain("word-break:break-word");
    expect(html).toContain("max-width:100%");
    // The full original label is rendered as text and linked exactly once.
    expect(html).toContain(longLabel);
    expect(html).toContain(`href="/memos?tag=${encodeURIComponent(longLabel)}"`);
  });

  it("renders nothing when a memo has no metadata tags", () => {
    expect(renderTags([])).toBe("");
  });
});

describe("TagFilter selector", () => {
  it("lists the complete exact catalogue — including unused labels — with no fake counts", () => {
    const catalogue = ["#a,b", "#父/子", "#Case", "#case", "#unused-parent/子"];
    const html = renderFilter(catalogue, null);
    expect(html).toContain('name="tag"');
    expect(html).toContain(">All tags</option>");
    for (const label of catalogue) {
      expect(html).toContain(`value="${label}"`);
    }
    // Labels are option text too (original bytes), and no counts are invented.
    expect(html).toContain("#unused-parent/子");
    expect(html).not.toMatch(/\(\d+\)/);
  });

  it("preserves the exact selection and an exact selection outside the catalogue", () => {
    const selected = renderFilter(["#a,b", "#Case"], "#a,b");
    expect(selected).toMatch(/<option value="#a,b"[^>]*>/);

    const missing = renderFilter(["#a,b"], "#not,fetched");
    expect(missing).toContain('value="#not,fetched"');
  });

  it("keeps case and comma variants as distinct exact options", () => {
    const html = renderFilter(["#Case", "#case", "#x,y", "#x", "#y"], "#case");
    for (const label of ["#Case", "#case", "#x,y", "#x", "#y"]) {
      expect(html).toContain(`value="${label}"`);
    }
  });
});
