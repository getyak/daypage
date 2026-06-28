import { NextResponse } from "next/server";
import { auth } from "@/lib/auth/session";
import { db } from "@/lib/db/client";
import { users, memos } from "@/lib/db/schema";
import { eq, and, gte, lt, count } from "drizzle-orm";

export const revalidate = 0;

const DEFAULT_THRESHOLD = 3;

export async function GET() {
  const session = await auth();
  if (!session?.user?.email) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const userRows = await db
    .select({ id: users.id, settings: users.settings })
    .from(users)
    .where(eq(users.email, session.user.email))
    .limit(1);

  if (!userRows[0]) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const { id: userId, settings } = userRows[0];

  const rawThreshold = (settings as Record<string, unknown> | null)?.unlock_threshold;
  const unlock_threshold =
    typeof rawThreshold === "number" && rawThreshold > 0
      ? rawThreshold
      : DEFAULT_THRESHOLD;

  const now = new Date();
  const todayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const tomorrowStart = new Date(todayStart.getTime() + 86_400_000);

  const rows = await db
    .select({ count: count() })
    .from(memos)
    .where(
      and(
        eq(memos.user_id, userId),
        gte(memos.created_at, todayStart),
        lt(memos.created_at, tomorrowStart)
      )
    );

  const memo_count = rows[0]?.count ?? 0;

  return NextResponse.json({
    memo_count,
    unlock_threshold,
    unlocked: memo_count >= unlock_threshold,
  });
}
