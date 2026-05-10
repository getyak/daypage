import { inngest } from "@/lib/inngest/client";
import { db } from "@/lib/db/client";
import { users, pages, inbox_items } from "@/lib/db/schema";
import { eq, and, lt, isNull, or, sql } from "drizzle-orm";

// ─── Constants ────────────────────────────────────────────────────────────────

const IDLE_DAYS = 90;
const RECENTLY_TOUCHED_DAYS = 30;
const MAX_SUGGESTIONS_PER_USER = 5;

// ─── Per-user orphan detection ────────────────────────────────────────────────

export async function detectOrphansForUser(userId: string): Promise<{
  user_id: string;
  orphans_found: number;
  suggestions: number;
}> {
  const now = new Date();
  const idleCutoff = new Date(now.getTime() - IDLE_DAYS * 24 * 60 * 60 * 1000);
  const recentTouchCutoff = new Date(
    now.getTime() - RECENTLY_TOUCHED_DAYS * 24 * 60 * 60 * 1000
  );

  // Find candidate pages: status != archived, backlink_count = 0,
  // last_compiled_at older than 90 days (or null), updated_at older than 30 days
  const candidates = await db
    .select({
      id: pages.id,
      title: pages.title,
      last_compiled_at: pages.last_compiled_at,
      updated_at: pages.updated_at,
    })
    .from(pages)
    .where(
      and(
        eq(pages.user_id, userId),
        sql`${pages.status} != 'archived'`,
        eq(pages.backlink_count, 0),
        or(
          isNull(pages.last_compiled_at),
          lt(pages.last_compiled_at, idleCutoff)
        ),
        lt(pages.updated_at, recentTouchCutoff)
      )
    );

  if (candidates.length === 0) {
    return { user_id: userId, orphans_found: 0, suggestions: 0 };
  }

  // Find page_ids already in open inbox_items with kind='orphan' to avoid duplicates
  const existingOrphans = await db
    .select({ payload: inbox_items.payload })
    .from(inbox_items)
    .where(
      and(
        eq(inbox_items.user_id, userId),
        eq(inbox_items.kind, "orphan"),
        sql`${inbox_items.status} IN ('open', 'snoozed')`
      )
    );

  const alreadySuggestedPageIds = new Set<string>();
  for (const item of existingOrphans) {
    const payload = item.payload as Record<string, unknown> | null;
    if (payload && typeof payload.page_id === "string") {
      alreadySuggestedPageIds.add(payload.page_id);
    }
  }

  const newCandidates = candidates.filter(
    (p) => !alreadySuggestedPageIds.has(p.id)
  );

  const toSuggest = newCandidates.slice(0, MAX_SUGGESTIONS_PER_USER);

  if (toSuggest.length === 0) {
    return {
      user_id: userId,
      orphans_found: candidates.length,
      suggestions: 0,
    };
  }

  for (const page of toSuggest) {
    const daysIdle = Math.floor(
      (now.getTime() -
        (page.last_compiled_at ?? page.updated_at).getTime()) /
        (24 * 60 * 60 * 1000)
    );

    await db.insert(inbox_items).values({
      user_id: userId,
      kind: "orphan",
      title: `Idle page: "${page.title}"`,
      body: `This page has no backlinks and hasn't been updated in ${daysIdle} days. Consider archiving or refreshing it.`,
      payload: {
        page_id: page.id,
        page_title: page.title,
        days_idle: daysIdle,
      },
      status: "open",
    });
  }

  console.log(
    `[orphan-detect] user ${userId}: ${toSuggest.length} orphan suggestion(s) written`
  );

  return {
    user_id: userId,
    orphans_found: candidates.length,
    suggestions: toSuggest.length,
  };
}

// ─── Inngest scheduled function ───────────────────────────────────────────────

export const orphanDetect = inngest.createFunction(
  { id: "orphan-detect", name: "Cold Storage Detection" },
  { cron: "0 4 * * *" }, // 04:00 UTC daily
  async ({ step }) => {
    const allUsers = await step.run("fetch-users", async () => {
      return db.select({ id: users.id }).from(users);
    });

    const results: {
      user_id: string;
      orphans_found: number;
      suggestions: number;
    }[] = [];

    for (const user of allUsers) {
      const result = await step.run(`orphan-detect-${user.id}`, async () => {
        return detectOrphansForUser(user.id);
      });
      results.push(result);
    }

    return {
      processed_users: results.length,
      total_suggestions: results.reduce((sum, r) => sum + r.suggestions, 0),
      results,
    };
  }
);
