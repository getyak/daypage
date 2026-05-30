import { NextResponse } from "next/server";
import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { users, memos } from "@/lib/db/schema";
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

/**
 * UTC-date key (YYYY-MM-DD). We bucket on UTC days to match the SQL aggregation
 * (`AT TIME ZONE 'UTC'`) and the rest of the codebase's insights queries, so the
 * grid and streak never drift by a day across the local-midnight boundary.
 */
function isoDate(d: Date): string {
  return d.toISOString().slice(0, 10);
}

/**
 * Current streak — consecutive days (ending today, or yesterday if today is
 * still empty) that have at least one memo. Walks backwards from today.
 */
function computeStreak(countsByDate: Map<string, number>, today: Date): number {
  let streak = 0;
  // Walk backwards on UTC days so the cursor keys match the UTC-bucketed counts.
  const cursor = new Date(
    Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate())
  );

  // If today has no memo yet, the streak may still be alive up to yesterday.
  if ((countsByDate.get(isoDate(cursor)) ?? 0) === 0) {
    cursor.setUTCDate(cursor.getUTCDate() - 1);
  }
  while ((countsByDate.get(isoDate(cursor)) ?? 0) > 0) {
    streak += 1;
    cursor.setUTCDate(cursor.getUTCDate() - 1);
  }
  return streak;
}

export async function GET(request: Request) {
  const { searchParams } = new URL(request.url);
  const weeks = Math.min(
    Math.max(parseInt(searchParams.get("weeks") ?? "16", 10) || 16, 1),
    53
  );

  const session = await auth();
  if (!session?.user?.email) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }
  const userId = await resolveUserId(session.user.email);
  if (!userId) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const today = new Date();
  // Window start: weeks*7 days back, floored to that day's midnight.
  const windowStart = new Date(
    today.getFullYear(),
    today.getMonth(),
    today.getDate() - weeks * 7
  );

  // Aggregate memo counts per UTC day in a single grouped scan, matching the
  // `AT TIME ZONE 'UTC'` convention used by the insights queries so buckets
  // align with the UTC grid the client renders.
  const rows = await db
    .select({
      day: sql<string>`date_trunc('day', ${memos.created_at} AT TIME ZONE 'UTC')::date::text`,
      count: sql<number>`count(*)::int`,
    })
    .from(memos)
    .where(and(eq(memos.user_id, userId), gte(memos.created_at, windowStart)))
    .groupBy(sql`date_trunc('day', ${memos.created_at} AT TIME ZONE 'UTC')::date`);

  const countsByDate = new Map<string, number>();
  for (const r of rows) countsByDate.set(r.day, r.count);

  const cells = rows.map((r) => ({ date: r.day, count: r.count }));
  const streak = computeStreak(countsByDate, today);

  return NextResponse.json({
    weeks,
    from: isoDate(windowStart),
    to: isoDate(today),
    cells,
    streak,
  });
}
