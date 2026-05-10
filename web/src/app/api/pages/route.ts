import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { pages, users } from "@/lib/db/schema";
import { eq, and, ilike, asc, lt } from "drizzle-orm";
import { z } from "zod";
import type { pageTypeEnum } from "@/lib/db/schema";

type PageType = (typeof pageTypeEnum.enumValues)[number];

function unauthorized() {
  return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
}

function badRequest(message: string) {
  return NextResponse.json({ error: message }, { status: 400 });
}

async function resolveUserId(email: string): Promise<string | null> {
  const rows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, email))
    .limit(1);
  return rows[0]?.id ?? null;
}

const VALID_TYPES: PageType[] = [
  "concept",
  "source",
  "entity",
  "synthesis",
  "daily",
];

const DEFAULT_LIMIT = 50;
const MAX_LIMIT = 200;

const CreatePageSchema = z.object({
  title: z.string().min(1).max(500),
  body_md: z.string().optional(),
  type: z.literal("synthesis"),
  source_thread_id: z.string().uuid().optional(),
});

// GET /api/pages?type=&domain=&q=&cursor=&limit= — paginated list
export async function GET(req: NextRequest) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userId = await resolveUserId(session.user.email);
  if (!userId) {
    return NextResponse.json({ pages: [], has_more: false, next_cursor: null });
  }

  const { searchParams } = req.nextUrl;
  const typeParam = searchParams.get("type") as PageType | null;
  const domainParam = searchParams.get("domain");
  const qParam = searchParams.get("q");
  const cursorParam = searchParams.get("cursor");
  const limitParam = searchParams.get("limit");

  const limit = Math.min(
    parseInt(limitParam ?? String(DEFAULT_LIMIT), 10) || DEFAULT_LIMIT,
    MAX_LIMIT
  );

  const conditions = [eq(pages.user_id, userId)];

  if (typeParam && VALID_TYPES.includes(typeParam)) {
    conditions.push(eq(pages.type, typeParam));
  }

  if (domainParam) {
    conditions.push(eq(pages.domain_id, domainParam));
  }

  if (qParam && qParam.trim()) {
    conditions.push(ilike(pages.title, `%${qParam.trim()}%`));
  }

  if (cursorParam) {
    conditions.push(lt(pages.updated_at, new Date(cursorParam)));
  }

  const rows = await db
    .select({
      id: pages.id,
      slug: pages.slug,
      type: pages.type,
      title: pages.title,
      status: pages.status,
      domain_id: pages.domain_id,
      source_count: pages.source_count,
      backlink_count: pages.backlink_count,
      last_compiled_at: pages.last_compiled_at,
      updated_at: pages.updated_at,
    })
    .from(pages)
    .where(and(...conditions))
    .orderBy(asc(pages.type), asc(pages.title))
    .limit(limit + 1);

  const hasMore = rows.length > limit;
  const items = hasMore ? rows.slice(0, limit) : rows;
  const nextCursor = hasMore
    ? items[items.length - 1]!.updated_at.toISOString()
    : null;

  return NextResponse.json({ pages: items, has_more: hasMore, next_cursor: nextCursor });
}

// POST /api/pages — create synthesis page
export async function POST(req: NextRequest) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const body: unknown = await req.json().catch(() => null);
  if (!body) return badRequest("Invalid JSON body");

  const parsed = CreatePageSchema.safeParse(body);
  if (!parsed.success) {
    return badRequest(parsed.error.issues[0]?.message ?? "Validation error");
  }

  const input = parsed.data;

  const slug =
    input.title
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-|-$/g, "") +
    "-" +
    Date.now();

  const [created] = await db
    .insert(pages)
    .values({
      user_id: userId,
      slug,
      type: "synthesis",
      title: input.title,
      body_md: input.body_md ?? "",
      status: "draft",
    })
    .returning();

  return NextResponse.json({ page: created }, { status: 201 });
}
