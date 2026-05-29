import { db } from "@/lib/db/client";
import { pages, page_sources, change_log } from "@/lib/db/schema";
import { eq, and, inArray, sql } from "drizzle-orm";

// ─── US-004: page status machine — draft → live promotion ──────────────────────
//
// A page graduates from `draft` to `live` when EITHER:
//   1. it is referenced by ≥2 page_sources rows (≥2 distinct source memos), OR
//   2. it has been synthesized / touched by the weave-graph pipeline.
//
// `/wiki` only lists `live` pages by default; drafts live in the
// "待编织 / 原料" (raw / to-be-woven) sidebar section until they graduate.

export const PROMOTE_SOURCE_THRESHOLD = 2;

/**
 * Promote any of the given draft pages that now have ≥ PROMOTE_SOURCE_THRESHOLD
 * page_sources to `live`. Idempotent and best-effort (never throws). Returns the
 * ids that were promoted this call.
 */
export async function promoteBySourceCount(
  userId: string,
  pageIds: string[]
): Promise<string[]> {
  const uniqueIds = Array.from(new Set(pageIds.filter(Boolean)));
  if (uniqueIds.length === 0) return [];

  try {
    // Count distinct source memos per candidate page.
    const counts = await db
      .select({
        page_id: page_sources.page_id,
        n: sql<number>`count(*)::int`,
      })
      .from(page_sources)
      .where(inArray(page_sources.page_id, uniqueIds))
      .groupBy(page_sources.page_id);

    const eligible = counts
      .filter((c) => (c.n ?? 0) >= PROMOTE_SOURCE_THRESHOLD)
      .map((c) => c.page_id);

    if (eligible.length === 0) return [];

    const promoted = await db
      .update(pages)
      .set({ status: "live", updated_at: new Date() })
      .where(
        and(
          eq(pages.user_id, userId),
          inArray(pages.id, eligible),
          eq(pages.status, "draft")
        )
      )
      .returning({ id: pages.id });

    await logPromotions(
      userId,
      promoted.map((p) => p.id),
      `Referenced by ≥${PROMOTE_SOURCE_THRESHOLD} sources.`
    );

    return promoted.map((p) => p.id);
  } catch (err) {
    console.warn(`[promote] promoteBySourceCount: non-fatal — ${String(err)}`);
    return [];
  }
}

/**
 * Promote the given pages to `live` because the weave-graph pipeline synthesized
 * or wove them. Idempotent and best-effort. Returns the ids promoted this call.
 */
export async function promoteByWeave(
  userId: string,
  pageIds: string[]
): Promise<string[]> {
  const uniqueIds = Array.from(new Set(pageIds.filter(Boolean)));
  if (uniqueIds.length === 0) return [];

  try {
    const promoted = await db
      .update(pages)
      .set({ status: "live", updated_at: new Date() })
      .where(
        and(
          eq(pages.user_id, userId),
          inArray(pages.id, uniqueIds),
          eq(pages.status, "draft")
        )
      )
      .returning({ id: pages.id });

    await logPromotions(
      userId,
      promoted.map((p) => p.id),
      "Synthesized by graph weaving."
    );

    return promoted.map((p) => p.id);
  } catch (err) {
    console.warn(`[promote] promoteByWeave: non-fatal — ${String(err)}`);
    return [];
  }
}

async function logPromotions(
  userId: string,
  pageIds: string[],
  reason: string
): Promise<void> {
  if (pageIds.length === 0) return;
  try {
    await db.insert(change_log).values(
      pageIds.map((id) => ({
        user_id: userId,
        action_kind: "update_page" as const,
        target_type: "page",
        target_id: id,
        before: { status: "draft" },
        after: { status: "live" },
        reason,
        performed_by: "agent" as const,
        agent_action_id: "promote",
      }))
    );
  } catch (err) {
    console.warn(`[promote] logPromotions: non-fatal — ${String(err)}`);
  }
}
