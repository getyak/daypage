// Exact metadata tag chips for memo cards and the detail view (issue #884).
//
// Chips render the ORIGINAL label bytes as text and link to the exact label
// URL-encoded into `?tag=` — no normalization, no splitting, no invented
// parent links for '/' hierarchies. Long labels wrap instead of overflowing.

interface MemoTagsProps {
  tags: readonly string[];
  /** History surface that understands `?tag=` (kept as a prop for detail links). */
  basePath?: string;
}

export function MemoTags({ tags, basePath = "/memos" }: MemoTagsProps) {
  if (tags.length === 0) return null;
  return (
    <ul
      className="memo-tags"
      aria-label="Tags"
      style={{
        display: "flex",
        flexWrap: "wrap",
        gap: 6,
        margin: "8px 0 0",
        padding: 0,
        listStyle: "none",
        maxWidth: "100%",
      }}
    >
      {tags.map((label) => (
        <li key={label} style={{ maxWidth: "100%" }}>
          <a
            className="memo-tag-chip"
            href={`${basePath}?tag=${encodeURIComponent(label)}`}
            style={{
              display: "inline-block",
              maxWidth: "100%",
              overflowWrap: "anywhere",
              wordBreak: "break-word",
              whiteSpace: "normal",
              fontSize: "0.72rem",
              color: "var(--fg-muted)",
              background: "var(--surface-sunken)",
              border: "0.5px solid var(--border-default)",
              borderRadius: 999,
              padding: "3px 10px",
              textDecoration: "none",
            }}
          >
            {label}
          </a>
        </li>
      ))}
    </ul>
  );
}
