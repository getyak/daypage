import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/lib/auth/session";
import { db } from "@/lib/db/client";
import { pages, users, page_sources, memos } from "@/lib/db/schema";
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

// GET /api/pages/:slug/sources — memos that contributed to this page via page_sources
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
    .where(eq(page_sources.page_id, pageId));

  return NextResponse.json({ sources: rows });
}
