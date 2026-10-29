import { auth } from "@/lib/auth/session";
import { db } from "@/lib/db/client";
import { pages, users, page_sources, page_links, memos, domains, annotations } from "@/lib/db/schema";
import { eq, and } from "drizzle-orm";
import { notFound } from "next/navigation";
import Link from "next/link";
import { WikiNav, type WikiPage } from "../WikiNav";
import { WikiPageShell } from "../WikiPageShell";
import { WikiArticle, type PageRow, type SourceRow, type BacklinkRow } from "../WikiArticle";
import { asc } from "drizzle-orm";
import AnnotationLayer, { type Annotation } from "./AnnotationLayer";
import { AskAboutPage } from "./AskAboutPage";

// ─── Types ────────────────────────────────────────────────────────────────────

// ─── Helpers ─────────────────────────────────────────────────────────────────

async function resolveUserId(email: string): Promise<string | null> {
  const rows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, email))
    .limit(1);
  return rows[0]?.id ?? null;
}

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

// Catch-all route ([...slug]) — page slugs in the DB may legitimately contain
// "/" (e.g. `source/abc-123`). Single-segment [slug] would 404 on those; the
// catch-all matches them and we rejoin the segments before querying.
type Props = { params: Promise<{ slug: string[] }> };

export default async function WikiSlugPage({ params }: Props) {
  const { slug: slugParts } = await params;
  const slug = slugParts.join("/");
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
      <WikiPageShell
        nav={<WikiNav initialPages={navPages} />}
        main={<div
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
        </div>}
      />
    );
  }

  const [sources, backlinks, pageAnnotations] = await Promise.all([
    fetchSources(userId, page.id),
    fetchBacklinks(userId, page.id),
    fetchAnnotations(userId, page.id),
  ]);

  return (
    <WikiPageShell
      nav={<WikiNav initialPages={navPages} />}
      main={<WikiArticle page={page} sources={sources} backlinks={backlinks} />}
    />
  );
}
