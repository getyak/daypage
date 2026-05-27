import { inngest } from "@/lib/inngest/client";
import { db } from "@/lib/db/client";
import { users, memos, pages, inbox_items } from "@/lib/db/schema";
import { eq, and, gte, lt, count, sql } from "drizzle-orm";

// ─── Weekly Report Inngest function ──────────────────────────────────────────
// Runs every Monday 09:00 UTC. Computes last-7-day stats per user and creates
// an "compiled" inbox_item so the notification lands in the user's Inbox.

export const weeklyReport = inngest.createFunction(
  { id: "weekly-report", name: "Weekly Report Generator" },
  { cron: "0 9 * * 1" }, // Every Monday 09:00 UTC
  async ({ step }) => {
    const allUsers = await step.run("fetch-users", () =>
      db.select({ id: users.id }).from(users)
    );

    const results: { user_id: string; status: string }[] = [];

    for (const user of allUsers) {
      const result = await step.run(`weekly-report-${user.id}`, () =>
        processUser(user.id)
      );
      results.push(result);
    }

    return { processed: results.length, results };
  }
);

async function processUser(userId: string): Promise<{ user_id: string; status: string }> {
  const now = new Date();
  const weekStart = new Date(now);
  weekStart.setUTCDate(weekStart.getUTCDate() - 7);
  weekStart.setUTCHours(0, 0, 0, 0);

  // Total memos created in the last 7 days
  const [memoResult] = await db
    .select({ total: count() })
    .from(memos)
    .where(and(eq(memos.user_id, userId), gte(memos.created_at, weekStart)));

  const totalMemos = memoResult?.total ?? 0;

  if (totalMemos === 0) {
    return { user_id: userId, status: "skipped" };
  }

  // Pages compiled in the last 7 days
  const [pagesResult] = await db
    .select({ total: count() })
    .from(pages)
    .where(
      and(
        eq(pages.user_id, userId),
        gte(pages.last_compiled_at, weekStart)
      )
    );

  const pagesCompiled = pagesResult?.total ?? 0;

  // Active topics: distinct domains touched via recently-compiled pages
  const topicRows = await db
    .select({ domain_id: pages.domain_id })
    .from(pages)
    .where(
      and(
        eq(pages.user_id, userId),
        gte(pages.updated_at, weekStart)
      )
    )
    .groupBy(pages.domain_id);

  const activeTopics = topicRows.filter((r) => r.domain_id !== null).length;

  // Top domains by page count updated this week
  const domainRows = await db
    .select({
      domain_id: pages.domain_id,
      page_count: sql<number>`count(*)::int`,
    })
    .from(pages)
    .where(
      and(
        eq(pages.user_id, userId),
        gte(pages.updated_at, weekStart),
        sql`${pages.domain_id} is not null`
      )
    )
    .groupBy(pages.domain_id)
    .orderBy(sql`count(*) desc`)
    .limit(3);

  const weekLabel = weekStart.toISOString().slice(0, 10);

  await db
    .insert(inbox_items)
    .values({
      user_id: userId,
      kind: "compiled",
      title: `Weekly report — ${weekLabel}`,
      body: [
        `Memos captured: ${totalMemos}`,
        `Pages compiled: ${pagesCompiled}`,
        `Active topics: ${activeTopics}`,
        domainRows.length > 0
          ? `Top domains: ${domainRows.map((d) => d.domain_id ?? "—").join(", ")}`
          : null,
      ]
        .filter(Boolean)
        .join("\n"),
      payload: {
        week_start: weekStart.toISOString(),
        total_memos: totalMemos,
        pages_compiled: pagesCompiled,
        active_topics: activeTopics,
        top_domains: domainRows.map((d) => ({
          domain_id: d.domain_id,
          page_count: d.page_count,
        })),
      },
    })
    .onConflictDoNothing();

  return { user_id: userId, status: "ok" };
}
