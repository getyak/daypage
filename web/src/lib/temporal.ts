// ─── US-040: Temporal knowledge graph (演变 / as-of 某日) ──────────────────────
// Server-only. DayPage's data is day-stamped at the source — every memo and
// every page_link carries a timestamp — which lets the knowledge graph answer
// *temporal* questions instead of only showing a single "current" snapshot:
//
//   • date-window query : what links held between two dates
//   • as-of query       : what the graph looked like on a given day
//   • evolution         : how one concept's mentions accumulated month by month
//
// Facts are INVALIDATED, not deleted: `invalidateLink` sets `valid_to` so the
// row survives and an as-of query before that date still sees the fact. That is
// what makes an entity's history a *sequence* rather than an overwrite.

import "server-only";
import { and, eq, isNull, lte, gte, or, inArray } from "drizzle-orm";
import { db } from "@/lib/db/client";
import { page_links, pages, memos, change_log } from "@/lib/db/schema";

export interface TemporalWindow {
  /** only facts valid on/before this day (YYYY-MM-DD) — the "as-of" point */
  asOf?: string;
  /** window start: only facts whose valid_from >= this day */
  from?: string;
  /** window end: only facts whose valid_from <= this day */
  to?: string;
}

export interface EvolutionMention {
  date: string; // YYYY-MM-DD
  excerpt: string;
  via_memo_id: string | null;
  rationale: string | null;
  invalidated: boolean;
}

export interface EvolutionPoint {
  period: string; // YYYY-MM
  count: number;
  mentions: EvolutionMention[];
}

export interface EntityEvolution {
  slug: string;
  title: string;
  firstSeen: string | null;
  lastSeen: string | null;
  total: number;
  /** month-by-month series, oldest first */
  series: EvolutionPoint[];
}

// ─── helpers ──────────────────────────────────────────────────────────────────

function dayStr(d: Date | string | null): string {
  if (!d) return "";
  const date = d instanceof Date ? d : new Date(d);
  return date.toISOString().slice(0, 10);
}

function monthOf(day: string): string {
  return day.slice(0, 7);
}

function snippet(body: string | null, max = 120): string {
  if (!body) return "";
  const t = body.replace(/\s+/g, " ").trim();
  return t.length > max ? `${t.slice(0, max)}…` : t;
}

/**
 * Drizzle predicate list implementing a temporal window over page_links.
 *
 *  as-of D : valid_from <= D  AND (valid_to IS NULL OR valid_to > D)
 *  from  F : valid_from >= F
 *  to    T : valid_from <= T
 *
 * The as-of clause is what distinguishes invalidation from deletion: a link
 * superseded *after* D is still visible when querying as-of D.
 */
function windowPredicate(w: TemporalWindow) {
  const clauses = [];
  if (w.asOf) {
    const d = new Date(`${w.asOf}T23:59:59.999Z`);
    clauses.push(lte(page_links.valid_from, d));
    clauses.push(or(isNull(page_links.valid_to), gte(page_links.valid_to, d)));
  }
  if (w.from) {
    clauses.push(gte(page_links.valid_from, new Date(`${w.from}T00:00:00.000Z`)));
  }
  if (w.to) {
    clauses.push(lte(page_links.valid_from, new Date(`${w.to}T23:59:59.999Z`)));
  }
  return clauses;
}

// ─── entity evolution ───────────────────────────────────────────────────────

/**
 * How a single concept/entity evolved over time for a user. Returns a
 * month-by-month series of dated mentions (every page_link pointing at the
 * page, plus the source memo it came through), honouring the temporal window.
 *
 * Because no mention is ever collapsed, an entity referenced in several months
 * yields several points — proving the data is a sequence, not an overwrite.
 */
export async function getEntityEvolution(
  userId: string,
  slug: string,
  w: TemporalWindow = {}
): Promise<EntityEvolution | null> {
  const pageRows = await db
    .select({ id: pages.id, title: pages.title, slug: pages.slug })
    .from(pages)
    .where(and(eq(pages.user_id, userId), eq(pages.slug, slug)))
    .limit(1);
  const page = pageRows[0];
  if (!page) return null;

  const rows = await db
    .select({
      valid_from: page_links.valid_from,
      valid_to: page_links.valid_to,
      via_memo_id: page_links.via_memo_id,
      rationale: page_links.rationale,
      memo_body: memos.body,
    })
    .from(page_links)
    .leftJoin(memos, eq(page_links.via_memo_id, memos.id))
    .where(
      and(
        eq(page_links.user_id, userId),
        eq(page_links.to_page_id, page.id),
        ...windowPredicate(w)
      )
    )
    .orderBy(page_links.valid_from);

  const byMonth = new Map<string, EvolutionPoint>();
  let firstSeen: string | null = null;
  let lastSeen: string | null = null;

  for (const r of rows) {
    const day = dayStr(r.valid_from);
    if (!day) continue;
    if (!firstSeen) firstSeen = day;
    lastSeen = day;
    const period = monthOf(day);
    let pt = byMonth.get(period);
    if (!pt) {
      pt = { period, count: 0, mentions: [] };
      byMonth.set(period, pt);
    }
    pt.count += 1;
    pt.mentions.push({
      date: day,
      excerpt: snippet(r.memo_body) || r.rationale || "(linked)",
      via_memo_id: r.via_memo_id,
      rationale: r.rationale,
      invalidated: r.valid_to != null,
    });
  }

  const series = Array.from(byMonth.values()).sort((a, b) =>
    a.period.localeCompare(b.period)
  );

  return {
    slug: page.slug,
    title: page.title,
    firstSeen,
    lastSeen,
    total: rows.length,
    series,
  };
}

// ─── as-of / window graph ───────────────────────────────────────────────────

export interface TemporalGraphNode {
  id: string;
  slug: string;
  title: string;
  type: string;
}
export interface TemporalGraphEdge {
  from_page_id: string;
  to_page_id: string;
  valid_from: string;
  valid_to: string | null;
  rationale: string | null;
}

/**
 * The knowledge graph restricted to a temporal window. Edges are page_links
 * filtered by the window; nodes are the pages those edges touch. An as-of query
 * yields the graph as it stood on that day (links superseded later are included,
 * links not yet created are excluded).
 */
export async function getTemporalGraph(
  userId: string,
  w: TemporalWindow = {}
): Promise<{ nodes: TemporalGraphNode[]; edges: TemporalGraphEdge[] }> {
  const links = await db
    .select({
      from_page_id: page_links.from_page_id,
      to_page_id: page_links.to_page_id,
      valid_from: page_links.valid_from,
      valid_to: page_links.valid_to,
      rationale: page_links.rationale,
    })
    .from(page_links)
    .where(and(eq(page_links.user_id, userId), ...windowPredicate(w)))
    .orderBy(page_links.valid_from);

  const ids = new Set<string>();
  for (const l of links) {
    ids.add(l.from_page_id);
    ids.add(l.to_page_id);
  }

  let nodes: TemporalGraphNode[] = [];
  if (ids.size > 0) {
    const pageRows = await db
      .select({
        id: pages.id,
        slug: pages.slug,
        title: pages.title,
        type: pages.type,
      })
      .from(pages)
      .where(and(eq(pages.user_id, userId), inArray(pages.id, Array.from(ids))));
    nodes = pageRows.map((p) => ({
      id: p.id,
      slug: p.slug,
      title: p.title,
      type: p.type,
    }));
  }

  const edges: TemporalGraphEdge[] = links.map((l) => ({
    from_page_id: l.from_page_id,
    to_page_id: l.to_page_id,
    valid_from: dayStr(l.valid_from),
    valid_to: l.valid_to ? dayStr(l.valid_to) : null,
    rationale: l.rationale,
  }));

  return { nodes, edges };
}

// ─── invalidation (supersede, do not delete) ────────────────────────────────

/**
 * Invalidate a link as of a day: set valid_to instead of deleting the row, so
 * the fact remains queryable for any as-of date before `since`. Records the
 * change in change_log for the audit trail (US-024).
 */
export async function invalidateLink(
  userId: string,
  linkId: string,
  since: string
): Promise<boolean> {
  const before = await db
    .select({ id: page_links.id, valid_to: page_links.valid_to })
    .from(page_links)
    .where(and(eq(page_links.id, linkId), eq(page_links.user_id, userId)))
    .limit(1);
  if (before.length === 0) return false;

  const sinceDate = new Date(`${since}T00:00:00.000Z`);
  await db
    .update(page_links)
    .set({ valid_to: sinceDate })
    .where(and(eq(page_links.id, linkId), eq(page_links.user_id, userId)));

  await db.insert(change_log).values({
    user_id: userId,
    action_kind: "invalidate_link",
    target_type: "page_link",
    target_id: linkId,
    before: { valid_to: before[0].valid_to },
    after: { valid_to: sinceDate.toISOString() },
    reason: `fact superseded as of ${since}`,
    performed_by: "user",
  });
  return true;
}
