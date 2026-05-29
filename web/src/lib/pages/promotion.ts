import type { SupabaseClient } from "@supabase/supabase-js";

// US-004: page status state machine — draft -> live.
//
// A draft page is promoted to 'live' (i.e. it becomes part of the formed
// knowledge network shown in /wiki by default) when either:
//   - it is referenced by >= PROMOTION_MIN_SOURCES distinct page_sources, OR
//   - it has been synthesized by the weave-graph pipeline.
//
// Promotion is monotonic: once a page is 'live' it stays 'live'. We therefore
// only ever update rows whose status is still 'draft', which keeps the writes
// idempotent and cheap.

export const PROMOTION_MIN_SOURCES = 2;

export type PageStatus = "draft" | "live";

/**
 * Given the rows of `page_sources` (each pointing at a target page), return the
 * set of target page ids that have reached the reference threshold for
 * promotion. Pure function — no I/O — so it is trivially unit-testable.
 */
export function pageIdsMeetingReferenceThreshold(
  sources: Array<{ target_page_id: string | null }>,
  minSources: number = PROMOTION_MIN_SOURCES,
): string[] {
  const counts = new Map<string, number>();
  for (const row of sources) {
    const id = row.target_page_id;
    if (!id) continue;
    counts.set(id, (counts.get(id) ?? 0) + 1);
  }
  const promotable: string[] = [];
  for (const [id, count] of counts) {
    if (count >= minSources) {
      promotable.push(id);
    }
  }
  return promotable;
}

/**
 * Decide whether a page should be promoted to 'live'.
 * Pure helper used by both the reference-count and synthesis paths.
 */
export function shouldPromote(input: {
  referenceCount: number;
  synthesized?: boolean;
  minSources?: number;
}): boolean {
  const min = input.minSources ?? PROMOTION_MIN_SOURCES;
  return Boolean(input.synthesized) || input.referenceCount >= min;
}

/**
 * Promote the given pages to 'live'. Only draft pages are touched, so calling
 * this repeatedly is safe. Returns the number of pages actually promoted.
 */
export async function promotePagesToLive(
  supabase: SupabaseClient,
  pageIds: string[],
): Promise<number> {
  const unique = Array.from(new Set(pageIds.filter(Boolean)));
  if (unique.length === 0) return 0;

  const { data, error } = await supabase
    .from("pages")
    .update({ status: "live" as PageStatus })
    .in("id", unique)
    .eq("status", "draft")
    .select("id");
  if (error) throw error;
  return data?.length ?? 0;
}

/**
 * Scan all page_sources, find pages that meet the reference threshold, and
 * promote any that are still drafts. Returns the number promoted.
 */
export async function promoteByReferenceCount(
  supabase: SupabaseClient,
  minSources: number = PROMOTION_MIN_SOURCES,
): Promise<number> {
  const { data, error } = await supabase
    .from("page_sources")
    .select("target_page_id");
  if (error) throw error;

  const promotable = pageIdsMeetingReferenceThreshold(
    (data ?? []) as Array<{ target_page_id: string | null }>,
    minSources,
  );
  return promotePagesToLive(supabase, promotable);
}
