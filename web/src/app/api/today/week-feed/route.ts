import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { users, pages } from "@/lib/db/schema";
import { eq, and, desc } from "drizzle-orm";

export const revalidate = 0;

export type MarkerType = "day" | "week" | "month" | "year";

export type WeekFeedItem = {
  id: string;
  date_slug: string;
  day: string;
  date_display: string;
  title: string;
  lede: string;
  tags: string[];
  word_count: number;
  memo_count: number;
  marker_type: MarkerType;
};

// pages.type → timeline marker shape. Only the four time-based wiki page types
// surface on the spine; everything else (concept/entity/source/...) is excluded.
const TYPE_TO_MARKER: Record<string, MarkerType> = {
  daily: "day",
  weekly: "week",
  monthly: "month",
  yearly: "year",
};

// pageTypeEnum currently only includes "daily" among the time-based wiki
// types. We can only query enum values that actually exist (Postgres rejects
// unknown enum literals), so the spine surfaces daily pages today; weekly/
// monthly/yearly markers are wired in TYPE_TO_MARKER for when the enum grows.

async function resolveUserId(email: string): Promise<string | null> {
  const rows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, email))
    .limit(1);
  return rows[0]?.id ?? null;
}

const DATE_RE = /(\d{4}-\d{2}-\d{2})/;

// Pull a YYYY-MM-DD out of the slug (e.g. "daily/2026-05-28" or "2026-05-28").
// Fall back to the page's created_at date when the slug carries no date.
function dateSlugFromPage(slug: string, createdAt: Date): string {
  const segments = slug.split("/");
  const last = segments[segments.length - 1] ?? "";
  const match = last.match(DATE_RE) ?? slug.match(DATE_RE);
  if (match) return match[1];
  return createdAt.toISOString().slice(0, 10);
}

// Strip markdown heading markers / list bullets / emphasis and collapse
// whitespace, then truncate to a plain-text lede.
function ledeFromBody(bodyMd: string | null): string {
  if (!bodyMd) return "";
  const text = bodyMd
    .replace(/```[\s\S]*?```/g, " ") // fenced code blocks
    .replace(/^\s{0,3}#{1,6}\s+/gm, "") // ATX headings
    .replace(/^\s{0,3}[-*+]\s+/gm, "") // list bullets
    .replace(/^\s{0,3}>\s?/gm, "") // blockquotes
    .replace(/[*_`~]/g, "") // emphasis / inline code
    .replace(/\s+/g, " ")
    .trim();
  return text.length > 120 ? text.slice(0, 120) : text;
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

export async function GET(req: NextRequest) {
  const { searchParams } = new URL(req.url);
  const limit = Math.min(Math.max(parseInt(searchParams.get("limit") ?? "7", 10) || 7, 1), 30);

  const session = await auth();
  if (!session?.user?.email) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const userId = await resolveUserId(session.user.email);
  if (!userId) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const rows = await db
    .select({
      id: pages.id,
      slug: pages.slug,
      type: pages.type,
      title: pages.title,
      body_md: pages.body_md,
      metadata: pages.metadata,
      source_count: pages.source_count,
      created_at: pages.created_at,
    })
    .from(pages)
    .where(and(eq(pages.user_id, userId), eq(pages.type, "daily")))
    .orderBy(desc(pages.created_at))
    .limit(limit);

  const items: WeekFeedItem[] = rows.map((row) => {
    const dateSlug = dateSlugFromPage(row.slug, row.created_at);
    return {
      id: row.id,
      date_slug: dateSlug,
      day: "",
      date_display: "",
      title: row.title,
      lede: ledeFromBody(row.body_md),
      tags: tagsFromMetadata(row.metadata),
      word_count: wordCountFromBody(row.body_md),
      memo_count: row.source_count ?? 0,
      marker_type: TYPE_TO_MARKER[row.type] ?? "day",
    };
  });

  return NextResponse.json({ items });
}
