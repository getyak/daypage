import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/lib/auth/session";
import { db } from "@/lib/db/client";
import { users, pages } from "@/lib/db/schema";
import { eq, and, desc } from "drizzle-orm";

export const revalidate = 0;

export type MarkerType = "day" | "week" | "month" | "year";

// ─── Row shapes ──────────────────────────────────────────────────────────────
// The four granularity levels of the museum spine. Days carry real compiled
// `daily` pages; weeks/months/years are derived aggregates (see SYNTHESIS note
// below) until real weekly/monthly/yearly compilation lands.

export type DayItem = {
  id: string;
  marker_type: "day";
  date_slug: string;
  day: string; // "WED"
  date: string; // "05 · 27"
  title: string;
  lede: string;
  tags: string[];
  words: number;
};

export type WeekItem = {
  id: string;
  marker_type: "week";
  weekNo: number;
  range: string; // "05·19 – 05·25"
  rangeStart: string; // "05·19"
  title: string;
  lede: string;
  tags: string[];
  entries: number;
  words: number;
};

export type MonthItem = {
  id: string;
  marker_type: "month";
  label: string; // "APRIL"
  year: string; // "2026"
  title: string;
  lede: string;
  tags: string[];
  entries: number;
  words: number;
};

export type YearItem = {
  id: string;
  marker_type: "year";
  label: string; // "2025"
  title: string;
  lede: string;
  tags: string[];
  entries: number;
  words: number;
};

export type WeekFeedResponse = {
  days: DayItem[];
  weeks: WeekItem[];
  months: MonthItem[];
  years: YearItem[];
  /** true when weeks/months/years are derived aggregates, not real compiled pages. */
  synthesized: boolean;
};

// NOTE — page_type enum currently only has "daily" among the time-based wiki
// types (concept/source/entity/synthesis/daily). Postgres rejects unknown enum
// literals, so we can only *query* daily pages today. Until weekly/monthly/
// yearly compilation backfills the DB, we SYNTHESIZE those three coarser levels
// by aggregating the real dailies below, so the 4-level spine renders elegantly
// now. The day level is always real data.
// TODO(compile-backfill): once pageTypeEnum gains weekly/monthly/yearly and the
// compiler populates them, replace the synthesis block with a single query over
// all four types grouped by marker_type + metadata.range/label.

async function resolveUserId(email: string): Promise<string | null> {
  const rows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, email))
    .limit(1);
  return rows[0]?.id ?? null;
}

const DATE_RE = /(\d{4}-\d{2}-\d{2})/;

const DAY_ABBR = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"];
const MONTH_NAMES = [
  "JANUARY",
  "FEBRUARY",
  "MARCH",
  "APRIL",
  "MAY",
  "JUNE",
  "JULY",
  "AUGUST",
  "SEPTEMBER",
  "OCTOBER",
  "NOVEMBER",
  "DECEMBER",
];

// Pull a YYYY-MM-DD out of the slug (e.g. "daily/2026-05-28" or "2026-05-28").
// Fall back to the page's created_at date when the slug carries no date.
function dateSlugFromPage(slug: string, createdAt: Date): string {
  const segments = slug.split("/");
  const last = segments[segments.length - 1] ?? "";
  const match = last.match(DATE_RE) ?? slug.match(DATE_RE);
  if (match) return match[1];
  return createdAt.toISOString().slice(0, 10);
}

// "2026-05-27" → "05 · 27"
function dateDisplay(dateSlug: string): string {
  const parts = dateSlug.split("-");
  if (parts.length < 3) return dateSlug;
  return `${parts[1]} · ${parts[2]}`;
}

// "2026-05-27" → "05·27" (compact, for ranges + left labels)
function dateCompact(dateSlug: string): string {
  const parts = dateSlug.split("-");
  if (parts.length < 3) return dateSlug;
  return `${parts[1]}·${parts[2]}`;
}

function dayAbbr(dateSlug: string): string {
  const d = new Date(dateSlug + "T00:00:00");
  return DAY_ABBR[d.getDay()] ?? "---";
}

// ISO-8601 week number (Mon-anchored). Used for the "W·NN" left label.
function isoWeekNo(dateSlug: string): number {
  const d = new Date(dateSlug + "T00:00:00Z");
  const day = (d.getUTCDay() + 6) % 7; // Mon=0..Sun=6
  d.setUTCDate(d.getUTCDate() - day + 3); // Thursday of this week
  const firstThursday = new Date(Date.UTC(d.getUTCFullYear(), 0, 4));
  const fday = (firstThursday.getUTCDay() + 6) % 7;
  firstThursday.setUTCDate(firstThursday.getUTCDate() - fday + 3);
  return 1 + Math.round((d.getTime() - firstThursday.getTime()) / (7 * 86400000));
}

// Strip markdown heading markers / list bullets / emphasis and collapse
// whitespace, then truncate to a plain-text lede.
function ledeFromBody(bodyMd: string | null, max = 120): string {
  if (!bodyMd) return "";
  const text = bodyMd
    .replace(/```[\s\S]*?```/g, " ") // fenced code blocks
    .replace(/^\s{0,3}#{1,6}\s+/gm, "") // ATX headings
    .replace(/^\s{0,3}[-*+]\s+/gm, "") // list bullets
    .replace(/^\s{0,3}>\s?/gm, "") // blockquotes
    .replace(/[*_`~]/g, "") // emphasis / inline code
    .replace(/\s+/g, " ")
    .trim();
  return text.length > max ? text.slice(0, max) : text;
}

// Approximate word count: CJK characters counted individually + whitespace-
// delimited runs of non-CJK (latin words).
function wordCountFromBody(bodyMd: string | null): number {
  if (!bodyMd) return 0;
  const cjk = bodyMd.match(/[一-龥]/g)?.length ?? 0;
  const latin =
    bodyMd
      .replace(/[一-龥]/g, " ")
      .trim()
      .split(/\s+/)
      .filter(Boolean).length;
  return cjk + latin;
}

function tagsFromMetadata(metadata: unknown): string[] {
  if (metadata && typeof metadata === "object") {
    const raw = (metadata as { tags?: unknown }).tags;
    if (Array.isArray(raw)) {
      return raw.filter((t): t is string => typeof t === "string");
    }
  }
  return [];
}

type DailyRow = {
  id: string;
  date_slug: string;
  title: string;
  lede: string;
  tags: string[];
  words: number;
  memo_count: number;
};

// Pick the most representative title/lede for an aggregate: the entry with the
// most words "speaks for" the span. Keeps the synthesis honest (it's a real
// daily, just surfaced as the period's headline) rather than fabricating prose.
function representative(rows: DailyRow[]): DailyRow {
  return rows.reduce((best, r) => (r.words > best.words ? r : best), rows[0]);
}

function topTags(rows: DailyRow[], n: number): string[] {
  const freq = new Map<string, number>();
  for (const r of rows) {
    for (const t of r.tags) freq.set(t, (freq.get(t) ?? 0) + 1);
  }
  return [...freq.entries()]
    .sort((a, b) => b[1] - a[1])
    .slice(0, n)
    .map(([t]) => t);
}

// ─── Synthesis: aggregate real dailies into week / month / year rows ──────────

function synthesizeWeeks(dailies: DailyRow[]): WeekItem[] {
  const buckets = new Map<number, DailyRow[]>();
  for (const d of dailies) {
    const wk = isoWeekNo(d.date_slug);
    const arr = buckets.get(wk) ?? [];
    arr.push(d);
    buckets.set(wk, arr);
  }
  // Sort weeks descending (most recent first), then drop the current/most-recent
  // week (it lives in the 本周 day section) so each datum appears once.
  const ordered = [...buckets.entries()].sort((a, b) => b[0] - a[0]);
  return ordered.slice(1).map(([weekNo, rows]) => {
    const sorted = [...rows].sort((a, b) => a.date_slug.localeCompare(b.date_slug));
    const start = sorted[0].date_slug;
    const end = sorted[sorted.length - 1].date_slug;
    const lead = representative(sorted);
    return {
      id: `week-${weekNo}`,
      marker_type: "week" as const,
      weekNo,
      rangeStart: dateCompact(start),
      range:
        start === end
          ? dateCompact(start)
          : `${dateCompact(start)} – ${dateCompact(end)}`,
      title: lead.title,
      lede: lead.lede,
      tags: topTags(sorted, 3),
      entries: rows.length,
      words: rows.reduce((s, r) => s + r.words, 0),
    };
  });
}

function synthesizeMonths(dailies: DailyRow[]): MonthItem[] {
  const buckets = new Map<string, DailyRow[]>(); // key "YYYY-MM"
  for (const d of dailies) {
    const key = d.date_slug.slice(0, 7);
    const arr = buckets.get(key) ?? [];
    arr.push(d);
    buckets.set(key, arr);
  }
  const ordered = [...buckets.entries()].sort((a, b) => b[0].localeCompare(a[0]));
  // Drop the current month (already represented day-by-day in 本周/本月) so the
  // 今年 section reads as "earlier months of this year".
  return ordered.slice(1).map(([key, rows]) => {
    const [year, month] = key.split("-");
    const lead = representative(rows);
    return {
      id: `month-${key}`,
      marker_type: "month" as const,
      label: MONTH_NAMES[parseInt(month, 10) - 1] ?? month,
      year,
      title: lead.title,
      lede: lead.lede,
      tags: topTags(rows, 3),
      entries: rows.length,
      words: rows.reduce((s, r) => s + r.words, 0),
    };
  });
}

function synthesizeYears(dailies: DailyRow[]): YearItem[] {
  const buckets = new Map<string, DailyRow[]>(); // key "YYYY"
  for (const d of dailies) {
    const key = d.date_slug.slice(0, 4);
    const arr = buckets.get(key) ?? [];
    arr.push(d);
    buckets.set(key, arr);
  }
  const ordered = [...buckets.entries()].sort((a, b) => b[0].localeCompare(a[0]));
  // Drop the current year (covered by the three finer sections above).
  return ordered.slice(1).map(([year, rows]) => {
    const lead = representative(rows);
    return {
      id: `year-${year}`,
      marker_type: "year" as const,
      label: year,
      title: lead.title,
      lede: lead.lede,
      tags: topTags(rows, 3),
      entries: rows.length,
      words: rows.reduce((s, r) => s + r.words, 0),
    };
  });
}

export async function GET(req: NextRequest) {
  const { searchParams } = new URL(req.url);
  const limit = Math.min(
    Math.max(parseInt(searchParams.get("limit") ?? "7", 10) || 7, 1),
    7
  );

  const session = await auth();
  if (!session?.user?.email) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const userId = await resolveUserId(session.user.email);
  if (!userId) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  // Real data: all daily compiled pages (most recent first). We pull a generous
  // window so synthesis has enough to bucket into weeks/months/years; the day
  // section itself only shows `limit` rows.
  const rows = await db
    .select({
      id: pages.id,
      slug: pages.slug,
      title: pages.title,
      body_md: pages.body_md,
      metadata: pages.metadata,
      source_count: pages.source_count,
      created_at: pages.created_at,
    })
    .from(pages)
    .where(and(eq(pages.user_id, userId), eq(pages.type, "daily")))
    .orderBy(desc(pages.created_at))
    .limit(400);

  const dailies: DailyRow[] = rows.map((row) => {
    const dateSlug = dateSlugFromPage(row.slug, row.created_at);
    return {
      id: row.id,
      date_slug: dateSlug,
      title: row.title,
      lede: ledeFromBody(row.body_md),
      tags: tagsFromMetadata(row.metadata),
      words: wordCountFromBody(row.body_md),
      memo_count: row.source_count ?? 0,
    };
  });

  const days: DayItem[] = dailies.slice(0, limit).map((d) => ({
    id: d.id,
    marker_type: "day" as const,
    date_slug: d.date_slug,
    day: dayAbbr(d.date_slug),
    date: dateDisplay(d.date_slug),
    title: d.title,
    lede: d.lede,
    tags: d.tags,
    words: d.words,
  }));

  const weeks = synthesizeWeeks(dailies).slice(0, 4);
  const months = synthesizeMonths(dailies).slice(0, 4);
  const years = synthesizeYears(dailies).slice(0, 3);

  const response: WeekFeedResponse = {
    days,
    weeks,
    months,
    years,
    synthesized: weeks.length + months.length + years.length > 0,
  };

  return NextResponse.json(response);
}
