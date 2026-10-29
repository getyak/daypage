import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import rehypeSanitize from "rehype-sanitize";
import Link from "next/link";
import { AskAboutPage } from "./[...slug]/AskAboutPage";
import { RecompilePerspective } from "./[...slug]/RecompilePerspective";

export type PageRow = {
  id: string;
  slug: string;
  type: "concept" | "source" | "entity" | "synthesis" | "daily";
  title: string;
  status: "draft" | "live" | "archived";
  body_md: string | null;
  source_count: number;
  backlink_count: number;
  last_compiled_at: Date | null;
  updated_at: Date;
  domain_id: string | null;
  domain_label: string | null;
};

export type SourceRow = {
  memo_id: string;
  contribution: string | null;
  weight: number;
  memo: {
    id: string;
    type: string;
    body: string;
    created_at: Date;
    ingest_mode: string;
    compile_status: string;
    origin: string;
  };
};

export type BacklinkRow = {
  link_id: string;
  weight: number;
  rationale: string | null;
  created_at: Date;
  from_page: {
    id: string;
    slug: string;
    type: string;
    title: string;
    status: string;
    source_count: number;
    backlink_count: number;
    updated_at: Date;
  };
};

function relativeTime(date: Date): string {
  const diffMs = Date.now() - date.getTime();
  const diffSec = Math.floor(diffMs / 1000);
  if (diffSec < 60) return "just now";
  const diffMin = Math.floor(diffSec / 60);
  if (diffMin < 60) return `${diffMin}m ago`;
  const diffHr = Math.floor(diffMin / 60);
  if (diffHr < 24) return `${diffHr}h ago`;
  const diffDay = Math.floor(diffHr / 24);
  if (diffDay < 30) return `${diffDay}d ago`;
  const diffMo = Math.floor(diffDay / 30);
  if (diffMo < 12) return `${diffMo}mo ago`;
  return `${Math.floor(diffMo / 12)}y ago`;
}

function truncate(text: string, len: number): string {
  return text.length <= len ? text : text.slice(0, len) + "…";
}

const TYPE_COLORS: Record<string, { bg: string; color: string }> = {
  concept:   { bg: "var(--accent-soft)",   color: "var(--accent)" },
  source:    { bg: "var(--surface-sunken)", color: "var(--fg-muted)" },
  entity:    { bg: "var(--accent-soft)",   color: "var(--accent-hover)" },
  synthesis: { bg: "var(--success-soft)",  color: "var(--success)" },
  daily:     { bg: "var(--surface-sunken)", color: "var(--fg-muted)" },
};

/** Presentation only; the server route owns authentication and account-scoped reads. */
export function WikiArticle({ page, sources, backlinks }: {
  page: PageRow;
  sources: SourceRow[];
  backlinks: BacklinkRow[];
}) {
  const typeStyle = TYPE_COLORS[page.type] ?? TYPE_COLORS.concept;
  return (
    <article className="wiki-article" data-page-kind={page.type}>
        {/* Header */}
        <header className="wiki-page-header">
          <h1 className="wiki-page-title">{page.title}</h1>
          <div className="wiki-page-meta">
            <span
              style={{
                fontSize: "0.875rem",
                fontWeight: 600,
                padding: "0.1875rem 0.5rem",
                borderRadius: "999px",
                background: typeStyle.bg,
                color: typeStyle.color,
              }}
            >
              {page.type}
            </span>

            {page.domain_label && (
              <span
                style={{
                  fontSize: "0.6875rem",
                  fontWeight: 500,
                  padding: "0.1875rem 0.5rem",
                  borderRadius: "999px",
                  background: "var(--surface-sunken)",
                  color: "var(--fg-muted)",
                }}
              >
                {page.domain_label}
              </span>
            )}

            {page.status === "draft" && (
              <span className="chip chip--warning">draft</span>
            )}

            <span
              style={{
                fontSize: "0.6875rem",
                padding: "0.1875rem 0.5rem",
                borderRadius: "999px",
                background: "var(--surface-sunken)",
                color: "var(--fg-subtle)",
              }}
            >
              updated {relativeTime(page.updated_at)}
            </span>

            <details className="wiki-page-actions">
              <summary>Page options</summary>
              <div>
              <span
                className="btn btn--ghost btn--sm"
                title="Select text in the body to annotate"
                style={{ cursor: "default", opacity: 0.6, fontSize: "0.75rem" }}
              >
                Select text to annotate
              </span>
              <RecompilePerspective pageSlug={page.slug} />
              <AskAboutPage
                pageSlug={page.slug}
                pageTitle={page.title}
                pageBodyMd={page.body_md}
              />
              </div>
            </details>
          </div>

          <div className="wiki-page-byline">
            <span>
              compiled from {page.source_count} source
              {page.source_count !== 1 ? "s" : ""}
            </span>
            <span>
              {page.backlink_count} backlink
              {page.backlink_count !== 1 ? "s" : ""}
            </span>
          </div>
        </header>

        {/* Two-column body */}
        <div className="wiki-body__layout">
          <div className="wiki-body__main">
            {page.body_md ? (
              <div className="wiki-body">
                <ReactMarkdown
                  remarkPlugins={[remarkGfm]}
                  rehypePlugins={[rehypeSanitize]}
                >
                  {page.body_md}
                </ReactMarkdown>
              </div>
            ) : (
              <p
                className="ds-body-md"
                style={{ color: "var(--fg-subtle)", fontStyle: "italic" }}
              >
                No content yet.
              </p>
            )}
          </div>

          <details className="wiki-references">
          <summary>Sources and backlinks</summary>
          <aside className="wiki-aside">
            {/* Sources */}
            <div className="aside-block">
              <div className="aside-block__head">
                <p
                  className="ds-section-label"
                  style={{ color: "var(--fg-subtle)" }}
                >
                  Sources
                </p>
                <span className="meta" style={{ fontFamily: "var(--font-mono)", fontSize: "10px", color: "var(--fg-subtle)" }}>
                  {sources.length}
                </span>
              </div>
              {sources.length === 0 ? (
                <p style={{ color: "var(--fg-subtle)", fontSize: "0.8125rem" }}>
                  No sources linked.
                </p>
              ) : (
                sources.map((s) => (
                  <div key={s.memo_id} className="aside-row">
                    <div style={{ flex: 1, minWidth: 0 }}>
                      <div
                        style={{
                          display: "flex",
                          alignItems: "center",
                          gap: "0.375rem",
                          marginBottom: "0.1875rem",
                        }}
                      >
                        <span
                          style={{
                            fontSize: "0.625rem",
                            fontWeight: 600,
                            textTransform: "uppercase",
                            letterSpacing: "0.04em",
                            color: "var(--fg-subtle)",
                            background: "var(--surface-sunken)",
                            padding: "0.0625rem 0.3125rem",
                            borderRadius: "999px",
                          }}
                        >
                          {s.memo.type}
                        </span>
                        <span
                          style={{
                            fontSize: "0.6875rem",
                            color: "var(--fg-subtle)",
                          }}
                        >
                          {relativeTime(s.memo.created_at)}
                        </span>
                      </div>
                      <p
                        style={{
                          fontSize: "0.8125rem",
                          color: "var(--fg-muted)",
                          margin: 0,
                          lineHeight: 1.4,
                        }}
                      >
                        {truncate(s.memo.body, 100)}
                      </p>
                      {s.contribution && (
                        <p
                          style={{
                            fontSize: "0.75rem",
                            color: "var(--fg-subtle)",
                            fontStyle: "italic",
                            margin: "0.1875rem 0 0",
                          }}
                        >
                          {s.contribution}
                        </p>
                      )}
                    </div>
                  </div>
                ))
              )}
            </div>

            {/* Backlinks */}
            <div className="aside-block">
              <div className="aside-block__head">
                <p
                  className="ds-section-label"
                  style={{ color: "var(--fg-subtle)" }}
                >
                  Backlinks
                </p>
                <span className="meta" style={{ fontFamily: "var(--font-mono)", fontSize: "10px", color: "var(--fg-subtle)" }}>
                  {backlinks.length}
                </span>
              </div>
              {backlinks.length === 0 ? (
                <p style={{ color: "var(--fg-subtle)", fontSize: "0.8125rem" }}>
                  No pages link here yet.
                </p>
              ) : (
                backlinks.map((b) => (
                  <Link
                    key={b.link_id}
                    href={`/wiki/${b.from_page.slug}`}
                    className="aside-row"
                    style={{ textDecoration: "none" }}
                  >
                    <span
                      style={{
                        flex: 1,
                        color: "var(--accent)",
                        overflow: "hidden",
                        textOverflow: "ellipsis",
                        whiteSpace: "nowrap",
                      }}
                    >
                      {b.from_page.title}
                    </span>
                    <span
                      style={{
                        fontSize: "0.6875rem",
                        color: "var(--fg-subtle)",
                        flexShrink: 0,
                      }}
                    >
                      {b.from_page.type}
                    </span>
                  </Link>
                ))
              )}
            </div>

            {/* Provenance */}
            <div className="aside-block">
              <div className="aside-block__head">
                <p
                  className="ds-section-label"
                  style={{ color: "var(--fg-subtle)" }}
                >
                  Provenance
                </p>
              </div>
              <p
                style={{
                  color: "var(--fg-muted)",
                  fontSize: "0.8125rem",
                  margin: 0,
                }}
              >
                {page.last_compiled_at
                  ? `Last compiled ${relativeTime(page.last_compiled_at)}`
                  : "Not yet compiled"}
              </p>
              <p
                style={{
                  color: "var(--fg-subtle)",
                  fontSize: "0.75rem",
                  marginTop: "0.375rem",
                  marginBottom: 0,
                }}
              >
                Created {relativeTime(page.updated_at)}
              </p>
            </div>
          </aside>
          </details>
        </div>
      </article>
  );
}
