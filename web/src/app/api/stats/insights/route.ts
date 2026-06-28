import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/lib/auth/session";
import { db } from "@/lib/db/client";
import { users, memos, prompt_log } from "@/lib/db/schema";
import { eq, and, gte, sql } from "drizzle-orm";

function unauthorized() {
  return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
}

function badRequest(msg: string) {
  return NextResponse.json({ error: msg }, { status: 400 });
}

async function resolveUserId(email: string): Promise<string | null> {
  const rows = await db.select({ id: users.id }).from(users).where(eq(users.email, email)).limit(1);
  return rows[0]?.id ?? null;
}

function rangeToMs(range: string): number {
  switch (range) {
    case "7d":  return 7 * 24 * 60 * 60 * 1000;
    case "30d": return 30 * 24 * 60 * 60 * 1000;
    case "90d": return 90 * 24 * 60 * 60 * 1000;
    case "1y":  return 365 * 24 * 60 * 60 * 1000;
    default:    return 30 * 24 * 60 * 60 * 1000;
  }
}

// GET /api/stats/insights?type=knowledge|system&range=7d|30d|90d|1y
export async function GET(req: NextRequest) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const sp = req.nextUrl.searchParams;
  const type = sp.get("type") ?? "knowledge";
  const range = sp.get("range") ?? "30d";

  if (!["knowledge", "system"].includes(type)) {
    return badRequest("type must be 'knowledge' or 'system'");
  }

  const since = new Date(Date.now() - rangeToMs(range));

  if (type === "knowledge") {
    // memos created per day, grouped by date
    const rows = await db
      .select({
        date: sql<string>`date_trunc('day', ${memos.created_at} AT TIME ZONE 'UTC')::date::text`,
        count: sql<number>`count(*)::int`,
      })
      .from(memos)
      .where(and(eq(memos.user_id, userId), gte(memos.created_at, since)))
      .groupBy(sql`date_trunc('day', ${memos.created_at} AT TIME ZONE 'UTC')::date`)
      .orderBy(sql`date_trunc('day', ${memos.created_at} AT TIME ZONE 'UTC')::date`);

    const total = rows.reduce((s, r) => s + r.count, 0);
    const days = rows.length || 1;
    const avg = Math.round((total / days) * 10) / 10;
    const busiest = rows.reduce(
      (best, r) => (r.count > best.count ? r : best),
      { date: "", count: 0 }
    );

    return NextResponse.json({ daily: rows, total, avg, busiest });
  }

  // type === "system"
  const rows = await db
    .select({
      date: sql<string>`date_trunc('day', ${prompt_log.created_at} AT TIME ZONE 'UTC')::date::text`,
      calls: sql<number>`count(*)::int`,
      tokens_in: sql<number>`sum(${prompt_log.tokens_in})::int`,
      tokens_out: sql<number>`sum(${prompt_log.tokens_out})::int`,
    })
    .from(prompt_log)
    .where(and(eq(prompt_log.user_id, userId), gte(prompt_log.created_at, since)))
    .groupBy(sql`date_trunc('day', ${prompt_log.created_at} AT TIME ZONE 'UTC')::date`)
    .orderBy(sql`date_trunc('day', ${prompt_log.created_at} AT TIME ZONE 'UTC')::date`);

  const totalCalls = rows.reduce((s, r) => s + r.calls, 0);
  const totalTokensIn = rows.reduce((s, r) => s + (r.tokens_in ?? 0), 0);
  const totalTokensOut = rows.reduce((s, r) => s + (r.tokens_out ?? 0), 0);
  // Rough cost estimate: input ~$3/M tokens, output ~$15/M tokens (qwen-equivalent)
  const estimatedCost = (totalTokensIn * 3 + totalTokensOut * 15) / 1_000_000;

  return NextResponse.json({ daily: rows, totalCalls, totalTokensIn, totalTokensOut, estimatedCost });
}
