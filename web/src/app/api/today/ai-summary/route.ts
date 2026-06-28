import { NextResponse } from "next/server";
import { auth } from "@/lib/auth/session";
import { db } from "@/lib/db/client";
import { users, pages, memos, page_sources } from "@/lib/db/schema";
import { eq, and, gte, lt, sql } from "drizzle-orm";

export const revalidate = 0;

async function resolveUserId(email: string): Promise<string | null> {
  const rows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, email))
    .limit(1);
  return rows[0]?.id ?? null;
}

export async function GET() {
  const session = await auth();
  if (!session?.user?.email) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const userId = await resolveUserId(session.user.email);
  if (!userId) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const now = new Date();
  const todayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const tomorrowStart = new Date(todayStart.getTime() + 86_400_000);
  const todaySlug = `daily/${todayStart.toISOString().slice(0, 10)}`;

  // Fetch today's daily page
  const pageRows = await db
    .select({
      id: pages.id,
      body_md: pages.body_md,
      last_compiled_at: pages.last_compiled_at,
      source_count: pages.source_count,
    })
    .from(pages)
    .where(
      and(
        eq(pages.user_id, userId),
        eq(pages.slug, todaySlug),
        eq(pages.type, "daily")
      )
    )
    .limit(1);

  if (!pageRows[0]) {
    return NextResponse.json(
      { summary: null, generated_at: null, is_stale: false, memo_count_at_generation: 0 },
      { status: 404 }
    );
  }

  const page = pageRows[0];

  // Count today's memos to determine staleness
  const memoCountResult = await db
    .select({ count: sql<number>`count(*)::int` })
    .from(memos)
    .where(
      and(
        eq(memos.user_id, userId),
        gte(memos.created_at, todayStart),
        lt(memos.created_at, tomorrowStart)
      )
    );

  const currentMemoCount = memoCountResult[0]?.count ?? 0;
  const isStale = currentMemoCount > (page.source_count ?? 0);

  // Extract a one-liner opening sentence from body_md for the summary card
  // body_md may be a full markdown document; we grab the first non-empty line
  let summary: string | null = null;
  if (page.body_md) {
    const firstLine = page.body_md
      .split("\n")
      .map((l) => l.trim())
      .find((l) => l.length > 0 && !l.startsWith("#"));
    summary = firstLine ?? null;
  }

  return NextResponse.json({
    summary,
    generated_at: page.last_compiled_at?.toISOString() ?? null,
    is_stale: isStale,
    memo_count_at_generation: page.source_count ?? 0,
  });
}
