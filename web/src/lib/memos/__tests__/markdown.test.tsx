import { describe, it, expect } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import { createElement } from "react";
import { MemoMarkdown } from "../markdown";

function render(body: string): string {
  return renderToStaticMarkup(createElement(MemoMarkdown, { body }));
}

describe("MemoMarkdown — safe rendering of original Markdown", () => {
  it("renders headings, lists, code, strong and links", () => {
    const html = render(
      "# Title\n\n- one\n- two\n\n**bold** and `inline code`\n\n[site](https://example.com/x)\n",
    );
    expect(html).toContain("<h1>");
    expect(html).toContain("<li>");
    expect(html).toContain("<strong>bold</strong>");
    expect(html).toContain("<code>inline code</code>");
    expect(html).toContain('href="https://example.com/x"');
  });

  it("never executes raw HTML", () => {
    const html = render(
      '<script>alert(1)</script>\n\n<img src=x onerror="alert(2)">\n\n<iframe src="https://evil"></iframe>\n',
    );
    expect(html).not.toContain("<script");
    expect(html).not.toContain("<img");
    expect(html).not.toContain("<iframe");
    expect(html).not.toContain("onerror");
  });

  it("strips dangerous URL protocols from links and images", () => {
    const html = render(
      "[x](javascript:alert(1)) and [y](JaVaScRiPt:alert(2)) and [z](data:text/html,<script>) and [w](vbscript:x)",
    );
    expect(html).not.toMatch(/javascript:/i);
    expect(html).not.toMatch(/data:/i);
    expect(html).not.toMatch(/vbscript:/i);
  });

  it("keeps external links safe and internal links internal", () => {
    const external = render("[a](https://example.com)");
    expect(external).toContain('rel="noopener noreferrer"');
    expect(external).toContain('target="_blank"');
    const internal = render("[a](/memos?q=%23x)");
    expect(internal).toContain('href="/memos?q=%23x"');
    expect(internal).not.toContain('target="_blank"');
  });

  it("does not render remote image embeds (media belongs to attachments)", () => {
    const html = render("![alt](https://tracker.example/pixel.png)");
    expect(html).not.toContain("<img");
    expect(html).not.toContain("tracker.example");
  });
});

describe("MemoMarkdown — hashtag and mention linking", () => {
  it("links conventional hashtags to history text search", () => {
    const html = render("hello #会议 tag");
    expect(html).toContain('href="/memos?q=%23%E4%BC%9A%E8%AE%AE"');
    expect(html).toContain("#会议");
  });

  it("links multi-level hashtag paths", () => {
    const html = render("#工作/项目/汇报 done");
    expect(html).toContain(`href="/memos?q=${encodeURIComponent("#工作/项目/汇报")}"`);
  });

  it("does not treat trailing Chinese punctuation as part of the tag", () => {
    const html = render("#标签，今天 #另一个。");
    expect(html).toContain(`href="/memos?q=${encodeURIComponent("#标签")}"`);
    expect(html).toContain(`href="/memos?q=${encodeURIComponent("#另一个")}"`);
    expect(html).toContain("，今天");
    expect(html).toContain("。");
  });

  it("does not rewrite code spans, code blocks or link destinations", () => {
    const codeSpan = render("use `#tag` here");
    expect(codeSpan).toContain("use <code>#tag</code> here");
    expect(codeSpan).not.toContain('href="/memos');

    const codeBlock = render("```\n#tag\n```");
    expect(codeBlock).not.toContain('href="/memos');

    // Link destinations keep their literal hash.
    const link = render("[a](https://example.com/page#section)");
    expect(link).toContain('href="https://example.com/page#section"');
  });

  it("never nests links when link text contains a hashtag", () => {
    const html = render("[see #tag](https://example.com/x#y)");
    expect(html).not.toMatch(/<a[^>]*>[^<]*<a/);
    // exactly one anchor element
    const anchors = html.match(/<a /g) ?? [];
    expect(anchors).toHaveLength(1);
    expect(html).toContain('href="https://example.com/x#y"');
    expect(html).toContain("#tag");
  });

  it("keeps safe mention links working", () => {
    const html = render("hi @alice");
    expect(html).toContain('href="/wiki/alice"');
  });

  it("does not rewrite hashtags under formatting inside links or references", () => {
    for (const body of ["[**#tag** and *#other*](https://example.com)", "[**#tag**][ref]\n\n[ref]: https://example.com"]) {
      const html = render(body);
      expect(html.match(/<a /g)).toHaveLength(1);
      expect(html).not.toContain('href="/memos');
      expect(html).toContain("<strong>#tag</strong>");
    }
  });

  it("does not link lone # or mid-word hashes", () => {
    const html = render("a#b and # and C#");
    expect(html).not.toContain('href="/memos');
  });
});
