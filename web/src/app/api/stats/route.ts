import { NextResponse } from "next/server";
import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { users, memos, pages, domains, page_links } from "@/lib/db/schema";
import { eq, and, gte, sql } from "drizzle-orm";

function unauthorized() {
  return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
}

async function resolveUserId(email: string): Promise<string | null> {
  const rows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, email))
    .limit(1);
  return rows[0]?.id ?? null;
}

// GET /api/stats — counts + weekly deltas for current user
export async function GET() {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const oneWeekAgo = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000);

  const [sourcesResult, pagesResult, domainsResult, backlinksResult] =
    await Promise.all([
      db
        .select({ count: sql<number>`count(*)::int` })
        .from(memos)
        .where(eq(memos.user_id, userId)),
      db
        .select({ count: sql<number>`count(*)::int` })
        .from(pages)
        .where(eq(pages.user_id, userId)),
      db
        .select({ count: sql<number>`count(*)::int` })
        .from(domains)
        .where(eq(domains.user_id, userId)),
      db
        .select({ count: sql<number>`count(*)::int` })
        .from(page_links)
        .where(eq(page_links.user_id, userId)),
    ]);

  const [sourcesWeekResult, pagesWeekResult, backlinksWeekResult] =
    await Promise.all([
      db
        .select({ count: sql<number>`count(*)::int` })
        .from(memos)
        .where(
          and(eq(memos.user_id, userId), gte(memos.created_at, oneWeekAgo))
        ),
      db
        .select({ count: sql<number>`count(*)::int` })
        .from(pages)
        .where(
          and(eq(pages.user_id, userId), gte(pages.created_at, oneWeekAgo))
        ),
      db
        .select({ count: sql<number>`count(*)::int` })
        .from(page_links)
        .where(
          and(
            eq(page_links.user_id, userId),
            gte(page_links.created_at, oneWeekAgo)
          )
        ),
    ]);

  return NextResponse.json({
    sources: sourcesResult[0]?.count ?? 0,
    pages: pagesResult[0]?.count ?? 0,
    domains: domainsResult[0]?.count ?? 0,
    backlinks: backlinksResult[0]?.count ?? 0,
    deltas: {
      sources_week: sourcesWeekResult[0]?.count ?? 0,
      pages_week: pagesWeekResult[0]?.count ?? 0,
      backlinks_week: backlinksWeekResult[0]?.count ?? 0,
    },
  });
}
