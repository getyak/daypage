import { NextResponse } from "next/server";
import { auth } from "@/lib/auth/session";
import { db } from "@/lib/db/client";
import { users, memos, pages } from "@/lib/db/schema";
import { eq, and, gte, sql } from "drizzle-orm";

export const revalidate = 0;

async function resolveUserId(email: string): Promise<string | null> {
  const rows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, email))
    .limit(1);
  return rows[0]?.id ?? null;
}

/** UTC-date key (YYYY-MM-DD) — matches the `AT TIME ZONE 'UTC'` aggregation. */
function isoDate(d: Date): string {
  return d.toISOString().slice(0, 10);
}

function computeStreak(countsByDate: Map<string, number>, today: Date): number {
  let streak = 0;
  const cursor = new Date(
    Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate())
  );
  if ((countsByDate.get(isoDate(cursor)) ?? 0) === 0) {
    cursor.setUTCDate(cursor.getUTCDate() - 1);
  }
  while ((countsByDate.get(isoDate(cursor)) ?? 0) > 0) {
    streak += 1;
    cursor.setUTCDate(cursor.getUTCDate() - 1);
  }
  return streak;
}

/** Compact display: 142350 → "142.4K", 1_200_000 → "1.2M". */
function formatLargeNumber(n: number): string {
  // 950_000+ rounds up into the millions band; guarding here avoids "1000K".
  if (n >= 950_000) return `${Math.round(n / 100_000) / 10}M`;
  if (n >= 1_000) return `${Math.round(n / 100) / 10}K`;
  return String(n);
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

  const today = new Date();
  const yearStart = new Date(today.getFullYear(), 0, 1);
  // Streak only needs recent history; 366 days back is plenty.
  const streakWindowStart = new Date(
    today.getFullYear(),
    today.getMonth(),
    today.getDate() - 366
  );

  const [dayRows, pagesRow, wordsRow] = await Promise.all([
    db
      .select({
        day: sql<string>`date_trunc('day', ${memos.created_at} AT TIME ZONE 'UTC')::date::text`,
        count: sql<number>`count(*)::int`,
      })
      .from(memos)
      .where(
        and(eq(memos.user_id, userId), gte(memos.created_at, streakWindowStart))
      )
      .groupBy(sql`date_trunc('day', ${memos.created_at} AT TIME ZONE 'UTC')::date`),
    db
      .select({ count: sql<number>`count(*)::int` })
      .from(pages)
      .where(eq(pages.user_id, userId)),
    db
      .select({ total: sql<number>`coalesce(sum(${memos.word_count}), 0)::int` })
      .from(memos)
      .where(and(eq(memos.user_id, userId), gte(memos.created_at, yearStart))),
  ]);

  const countsByDate = new Map<string, number>();
  for (const r of dayRows) countsByDate.set(r.day, r.count);

  const streakDays = computeStreak(countsByDate, today);
  const pagesTotal = pagesRow[0]?.count ?? 0;
  const wordsThisYear = wordsRow[0]?.total ?? 0;

  return NextResponse.json({
    streak_days: streakDays,
    pages_total: pagesTotal,
    words_this_year: wordsThisYear,
    words_this_year_display: formatLargeNumber(wordsThisYear),
  });
}
