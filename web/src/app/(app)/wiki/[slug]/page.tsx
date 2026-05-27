import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { pages, users, page_sources, page_links, memos, domains, annotations } from "@/lib/db/schema";
import { eq, and } from "drizzle-orm";
import { notFound } from "next/navigation";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import rehypeSanitize from "rehype-sanitize";
import Link from "next/link";
import { WikiNav, type WikiPage } from "../WikiNav";
import { asc } from "drizzle-orm";
import AnnotationLayer, { type Annotation } from "./AnnotationLayer";
import { AskAboutPage } from "./AskAboutPage";

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

async function fetchAnnotations(userId: string, pageId: string): Promise<Annotation[]> {
  try {
    const rows = await db
      .select()
      .from(annotations)
      .where(and(eq(annotations.page_id, pageId), eq(annotations.user_id, userId)))
      .orderBy(asc(annotations.created_at));
    return rows.map((r) => ({
      ...r,
      anchor: r.anchor as Annotation["anchor"],
      created_at: r.created_at.toISOString(),
    }));
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
      <div className="wiki">
        <aside className="wiki__nav">
          <WikiNav initialPages={navPages} />
        </aside>
        <main
          className="wiki__page"
          style={{
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            padding: "3rem 2rem",
          }}
        >
          <div style={{ textAlign: "center", maxWidth: "420px" }}>
            <h2 className="ds-h2" style={{ marginBottom: "0.5rem" }}>
              This page does not exist
            </h2>
            <p className="ds-body-md" style={{ color: "var(--fg-muted)", marginBottom: "1.5rem" }}>
              It may have been archived or the link is incorrect. You can still ask a question about
              this topic and DayPage will search your knowledge base.
            </p>
            <div style={{ display: "flex", gap: "0.75rem", justifyContent: "center", flexWrap: "wrap" }}>
              <Link href="/wiki" className="btn btn--secondary btn--sm">
                Back to Wiki
              </Link>
              <AskAboutPage
                pageSlug={slug}
                pageTitle={slug}
                pageBodyMd={null}
              />
            </div>
          </div>
        </main>
      </div>
    );
  }

  const [sources, backlinks, pageAnnotations] = await Promise.all([
    fetchSources(userId, page.id),
    fetchBacklinks(userId, page.id),
    fetchAnnotations(userId, page.id),
  ]);

  const typeStyle = TYPE_COLORS[page.type] ?? TYPE_COLORS.concept;

  return (
    <div className="wiki">
      <aside className="wiki__nav">
        <WikiNav initialPages={navPages} />
      </aside>

      <main className="wiki__page">
        {/* Header */}
        <header className="wiki-page-header">
          <div className="wiki-page-meta">
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

            <div style={{ marginLeft: "auto", display: "flex", gap: "0.5rem" }}>
              <span
                className="btn btn--ghost btn--sm"
                title="Select text in the body to annotate"
                style={{ cursor: "default", opacity: 0.6, fontSize: "0.75rem" }}
              >
                Select text to annotate
              </span>
              <AskAboutPage
                pageSlug={page.slug}
                pageTitle={page.title}
                pageBodyMd={page.body_md}
              />
            </div>
          </div>

          <h1 className="wiki-page-title">{page.title}</h1>

          <div className="wiki-page-byline">
            <span>
              compiled from {page.source_count} source
              {page.source_count !== 1 ? "s" : ""}
            </span>
            <span>
              {page.backlink_count} backlink
              {page.backlink_count !== 1 ? "s" : ""}
            </span>
            <span>id {page.type}/{page.slug}</span>
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
        </div>
      </main>
    </div>
  );
}
