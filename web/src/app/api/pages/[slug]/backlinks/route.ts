import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/lib/auth/session";
import { db } from "@/lib/db/client";
import { pages, users, page_links } from "@/lib/db/schema";
import { eq, and } from "drizzle-orm";

function unauthorized() {
  return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
}

function notFound() {
  return NextResponse.json({ error: "Not found" }, { status: 404 });
}

async function resolveUserId(email: string): Promise<string | null> {
  const rows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, email))
    .limit(1);
  return rows[0]?.id ?? null;
}

type RouteContext = { params: Promise<{ slug: string }> };

// Alias for joined page columns to avoid collision with the main pages table
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

// GET /api/pages/:slug/backlinks — pages that link TO this page via page_links
export async function GET(_req: NextRequest, ctx: RouteContext) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const { slug } = await ctx.params;

  // Resolve page id from slug (scoped to user)
  const pageRows = await db
    .select({ id: pages.id })
    .from(pages)
    .where(and(eq(pages.slug, slug), eq(pages.user_id, userId)))
    .limit(1);

  if (!pageRows.length) return notFound();

  const pageId = pageRows[0].id;

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
    .where(and(eq(page_links.to_page_id, pageId), eq(page_links.user_id, userId)));

  return NextResponse.json({ backlinks: rows });
}
