import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { pages, users, page_sources, page_links, memos, domains } from "@/lib/db/schema";
import { eq, and } from "drizzle-orm";
import { notFound } from "next/navigation";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import rehypeSanitize from "rehype-sanitize";
import Link from "next/link";
import { WikiNav, type WikiPage } from "../WikiNav";
import { asc } from "drizzle-orm";

// ─── Types ────────────────────────────────────────────────────────────────────

type PageRow = {
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

type SourceRow = {
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

type BacklinkRow = {
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

// ─── Helpers ─────────────────────────────────────────────────────────────────

async function resolveUserId(email: string): Promise<string | null> {
  const rows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, email))
    .limit(1);
  return rows[0]?.id ?? null;
}

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

// ─── Data fetching ────────────────────────────────────────────────────────────

async function fetchPage(userId: string, slug: string): Promise<PageRow | null> {
  const rows = await db
    .select({
      id: pages.id,
      slug: pages.slug,
      type: pages.type,
      title: pages.title,
      status: pages.status,
      body_md: pages.body_md,
      source_count: pages.source_count,
      backlink_count: pages.backlink_count,
      last_compiled_at: pages.last_compiled_at,
      updated_at: pages.updated_at,
      domain_id: pages.domain_id,
      domain_label: domains.label,
    })
    .from(pages)
    .leftJoin(domains, eq(pages.domain_id, domains.id))
    .where(and(eq(pages.slug, slug), eq(pages.user_id, userId)))
    .limit(1);

  return rows[0] ?? null;
}

async function fetchSources(userId: string, pageId: string): Promise<SourceRow[]> {
  try {
    const rows = await db
      .select({
        memo_id: page_sources.memo_id,
        contribution: page_sources.contribution,
        weight: page_sources.weight,
        memo: {
          id: memos.id,
          type: memos.type,
          body: memos.body,
          created_at: memos.created_at,
          ingest_mode: memos.ingest_mode,
          compile_status: memos.compile_status,
          origin: memos.origin,
        },
      })
      .from(page_sources)
      .innerJoin(memos, eq(page_sources.memo_id, memos.id))
      .where(
        and(
          eq(page_sources.page_id, pageId),
          eq(memos.user_id, userId)
        )
      );
    return rows;
  } catch {
    return [];
  }
}

async function fetchBacklinks(userId: string, pageId: string): Promise<BacklinkRow[]> {
  try {
    const fromPage = {
      id: pages.id,
      slug: pages.slug,
      type: pages.type,
      title: pages.title,
      status: pages.status,
      source_count: pages.source_count,
      backlink_count: pages.backlink_count,
      updated_at: pages.updated_at,
    };

    const rows = await db
      .select({
        link_id: page_links.id,
        weight: page_links.weight,
        rationale: page_links.rationale,
        created_at: page_links.created_at,
        from_page: fromPage,
      })
      .from(page_links)
      .innerJoin(pages, eq(page_links.from_page_id, pages.id))
      .where(
        and(
          eq(page_links.to_page_id, pageId),
          eq(page_links.user_id, userId)
        )
      );
    return rows;
  } catch {
    return [];
  }
}

async function fetchNavPages(userId: string): Promise<WikiPage[]> {
  try {
    const rows = await db
      .select({
        id: pages.id,
        slug: pages.slug,
        type: pages.type,
        title: pages.title,
        status: pages.status,
        domain_id: pages.domain_id,
        source_count: pages.source_count,
        backlink_count: pages.backlink_count,
        last_compiled_at: pages.last_compiled_at,
        updated_at: pages.updated_at,
      })
      .from(pages)
      .where(eq(pages.user_id, userId))
      .orderBy(asc(pages.type), asc(pages.title));

    return rows.map((r) => ({
      ...r,
      last_compiled_at: r.last_compiled_at?.toISOString() ?? null,
      updated_at: r.updated_at.toISOString(),
    }));
  } catch {
    return [];
  }
}

// ─── Page ─────────────────────────────────────────────────────────────────────

type Props = { params: Promise<{ slug: string }> };

export default async function WikiSlugPage({ params }: Props) {
  const { slug } = await params;
  const session = await auth();

  if (!session?.user?.email) {
    notFound();
  }

  const userId = await resolveUserId(session.user.email);
  if (!userId) notFound();

  const [page, navPages] = await Promise.all([
    fetchPage(userId, slug),
    fetchNavPages(userId),
  ]);

  if (!page) {
    return (
      <div
        style={{
          display: "flex",
          height: "100%",
          minHeight: "calc(100vh - 52px)",
        }}
      >
        <WikiNav initialPages={navPages} />
        <main
          style={{
            flex: 1,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            padding: "3rem 2rem",
          }}
        >
          <div style={{ textAlign: "center", maxWidth: "400px" }}>
            <h2 className="ds-h2" style={{ marginBottom: "0.5rem" }}>
              This page does not exist
            </h2>
            <p className="ds-body-md" style={{ color: "var(--fg-muted)", marginBottom: "1.5rem" }}>
              It may have been archived or the link is incorrect.
            </p>
            <Link href="/wiki" className="btn btn--secondary btn--sm">
              Back to Wiki
            </Link>
          </div>
        </main>
        <aside
          style={{
            width: "280px",
            flexShrink: 0,
            borderLeft: "1px solid var(--accent-border)",
            background: "var(--surface-white)",
          }}
        />
      </div>
    );
  }

  const [sources, backlinks] = await Promise.all([
    fetchSources(userId, page.id),
    fetchBacklinks(userId, page.id),
  ]);

  const typeStyle = TYPE_COLORS[page.type] ?? TYPE_COLORS.concept;

  return (
    <div
      style={{
        display: "flex",
        height: "100%",
        minHeight: "calc(100vh - 52px)",
      }}
    >
      {/* Left nav: 240px */}
      <WikiNav initialPages={navPages} />

      {/* Main content */}
      <main
        style={{
          flex: 1,
          overflowY: "auto",
          display: "flex",
          flexDirection: "column",
        }}
      >
        {/* Header */}
        <div
          style={{
            padding: "1.75rem 2rem 1.25rem",
            borderBottom: "1px solid var(--accent-border)",
          }}
        >
          {/* Chips row */}
          <div
            style={{
              display: "flex",
              alignItems: "center",
              gap: "0.375rem",
              marginBottom: "0.875rem",
              flexWrap: "wrap",
            }}
          >
            {/* Type chip */}
            <span
              style={{
                fontSize: "0.6875rem",
                fontWeight: 600,
                letterSpacing: "0.04em",
                textTransform: "uppercase",
                padding: "0.1875rem 0.5rem",
                borderRadius: "999px",
                background: typeStyle.bg,
                color: typeStyle.color,
              }}
            >
              {page.type}
            </span>

            {/* Domain chip */}
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

            {/* Status chip (draft) */}
            {page.status === "draft" && (
              <span
                style={{
                  fontSize: "0.6875rem",
                  fontWeight: 600,
                  letterSpacing: "0.04em",
                  textTransform: "uppercase",
                  padding: "0.1875rem 0.5rem",
                  borderRadius: "999px",
                  background: "var(--warning-soft)",
                  color: "var(--warning)",
                }}
              >
                draft
              </span>
            )}

            {/* Updated chip */}
            <span
              style={{
                fontSize: "0.6875rem",
                fontWeight: 400,
                padding: "0.1875rem 0.5rem",
                borderRadius: "999px",
                background: "var(--surface-sunken)",
                color: "var(--fg-subtle)",
              }}
            >
              updated {relativeTime(page.updated_at)}
            </span>

            {/* Actions pushed right */}
            <div style={{ marginLeft: "auto", display: "flex", gap: "0.5rem" }}>
              <button
                className="btn btn--ghost btn--sm"
                title="Annotate (coming soon)"
                disabled
              >
                Annotate
              </button>
              <button
                className="btn btn--soft btn--sm"
                title="Ask about this page (coming soon)"
                disabled
              >
                Ask
              </button>
            </div>
          </div>

          {/* Title */}
          <h1
            className="ds-h1"
            style={{ margin: "0 0 0.5rem", lineHeight: 1.2 }}
          >
            {page.title}
          </h1>

          {/* Byline */}
          <p
            className="ds-body-md"
            style={{
              color: "var(--fg-subtle)",
              margin: 0,
              fontSize: "0.8125rem",
            }}
          >
            compiled from {page.source_count} source
            {page.source_count !== 1 ? "s" : ""} · {page.backlink_count}{" "}
            backlink{page.backlink_count !== 1 ? "s" : ""} ·{" "}
            <span style={{ fontFamily: "var(--font-mono)", fontSize: "0.75rem" }}>
              {page.slug}
            </span>
          </p>
        </div>

        {/* Body */}
        <div
          style={{
            flex: 1,
            padding: "1.75rem 2rem 3rem",
            maxWidth: "740px",
          }}
        >
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
      </main>

      {/* Right aside: 280px */}
      <aside
        style={{
          width: "280px",
          flexShrink: 0,
          borderLeft: "1px solid var(--accent-border)",
          background: "var(--surface-white)",
          overflowY: "auto",
          display: "flex",
          flexDirection: "column",
          gap: 0,
        }}
      >
        {/* Sources block */}
        <AsideBlock label={`Sources · ${sources.length}`}>
          {sources.length === 0 ? (
            <p style={{ color: "var(--fg-subtle)", fontSize: "0.8125rem" }}>
              No sources linked.
            </p>
          ) : (
            <div style={{ display: "flex", flexDirection: "column", gap: "0.5rem" }}>
              {sources.map((s) => (
                <div
                  key={s.memo_id}
                  style={{
                    padding: "0.5rem 0.625rem",
                    borderRadius: "var(--radius-sm)",
                    background: "var(--surface-sunken)",
                    display: "flex",
                    flexDirection: "column",
                    gap: "0.1875rem",
                  }}
                >
                  {/* Memo type + time */}
                  <div
                    style={{
                      display: "flex",
                      alignItems: "center",
                      gap: "0.375rem",
                    }}
                  >
                    <span
                      style={{
                        fontSize: "0.625rem",
                        fontWeight: 600,
                        textTransform: "uppercase",
                        letterSpacing: "0.04em",
                        color: "var(--fg-subtle)",
                        background: "var(--surface-white)",
                        padding: "0.0625rem 0.3125rem",
                        borderRadius: "999px",
                      }}
                    >
                      {s.memo.type}
                    </span>
                    <span
                      style={{ fontSize: "0.6875rem", color: "var(--fg-subtle)" }}
                    >
                      {relativeTime(s.memo.created_at)}
                    </span>
                  </div>
                  {/* Memo excerpt */}
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
                  {/* Contribution note */}
                  {s.contribution && (
                    <p
                      style={{
                        fontSize: "0.75rem",
                        color: "var(--fg-subtle)",
                        fontStyle: "italic",
                        margin: 0,
                      }}
                    >
                      {s.contribution}
                    </p>
                  )}
                </div>
              ))}
            </div>
          )}
        </AsideBlock>

        {/* Backlinks block */}
        <AsideBlock label={`Backlinks · ${backlinks.length}`}>
          {backlinks.length === 0 ? (
            <p style={{ color: "var(--fg-subtle)", fontSize: "0.8125rem" }}>
              No pages link here yet.
            </p>
          ) : (
            <div style={{ display: "flex", flexDirection: "column", gap: "0.375rem" }}>
              {backlinks.map((b) => (
                <Link
                  key={b.link_id}
                  href={`/wiki/${b.from_page.slug}`}
                  style={{
                    display: "flex",
                    alignItems: "center",
                    gap: "0.5rem",
                    padding: "0.375rem 0.5rem",
                    borderRadius: "var(--radius-sm)",
                    textDecoration: "none",
                    background: "var(--surface-sunken)",
                    transition: "background 100ms ease-out",
                  }}
                >
                  <span
                    style={{
                      flex: 1,
                      fontSize: "0.8125rem",
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
              ))}
            </div>
          )}
        </AsideBlock>

        {/* Provenance block */}
        <AsideBlock label="Provenance">
          <p style={{ color: "var(--fg-muted)", fontSize: "0.8125rem", margin: 0 }}>
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
        </AsideBlock>
      </aside>
    </div>
  );
}

// ─── AsideBlock ───────────────────────────────────────────────────────────────

function AsideBlock({
  label,
  children,
}: {
  label: string;
  children: React.ReactNode;
}) {
  return (
    <div
      style={{
        padding: "1.25rem 1rem",
        borderBottom: "1px solid var(--accent-border)",
      }}
    >
      <p
        className="ds-section-label"
        style={{ color: "var(--fg-subtle)", marginBottom: "0.625rem" }}
      >
        {label}
      </p>
      {children}
    </div>
  );
}
