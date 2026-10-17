import { MemoMarkdown } from "@/lib/memos/markdown";

interface MemoBodyProps {
  body: string;
}

// Renders the ORIGINAL memo Markdown safely (react-markdown + remark-gfm +
// rehype-sanitize): raw HTML never executes, dangerous URL protocols are
// stripped, and hashtags inside rich text link to /memos text search while
// code spans/blocks and link destinations stay untouched. The stored text is
// never rewritten.
export function MemoBody({ body }: MemoBodyProps) {
  if (!body) {
    return (
      <div style={{ padding: "0 24px 30px" }}>
        <span style={{ color: "var(--fg-subtle)", fontStyle: "italic" }}>No content</span>
      </div>
    );
  }

  return (
    <div
      className="memo-body wiki-body"
      style={{
        padding: "0 24px 30px",
        fontSize: "16.5px",
        lineHeight: 1.72,
        letterSpacing: "0.1px",
        textWrap: "pretty" as React.CSSProperties["textWrap"],
        color: "var(--fg-primary)",
        wordBreak: "break-word",
      }}
    >
      <MemoMarkdown body={body} />
    </div>
  );
}
