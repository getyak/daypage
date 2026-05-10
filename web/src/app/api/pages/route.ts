import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { pages, users } from "@/lib/db/schema";
import { eq, and, ilike, asc } from "drizzle-orm";
import type { pageTypeEnum } from "@/lib/db/schema";

type PageType = (typeof pageTypeEnum.enumValues)[number];

async function resolveUserId(email: string): Promise<string | null> {
  const rows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, email))
    .limit(1);
  return rows[0]?.id ?? null;
}

export async function GET(req: NextRequest) {
  const session = await auth();
  if (!session?.user?.email) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const userId = await resolveUserId(session.user.email);
  if (!userId) {
    return NextResponse.json({ pages: [] });
  }

  const { searchParams } = req.nextUrl;
  const typeParam = searchParams.get("type") as PageType | null;
  const domainParam = searchParams.get("domain");
  const qParam = searchParams.get("q");

  const conditions = [eq(pages.user_id, userId)];

  if (typeParam) {
    const validTypes: PageType[] = [
      "concept",
      "source",
      "entity",
      "synthesis",
      "daily",
    ];
    if (validTypes.includes(typeParam)) {
      conditions.push(eq(pages.type, typeParam));
    }
  }

  if (domainParam) {
    conditions.push(eq(pages.domain_id, domainParam));
  }

  if (qParam && qParam.trim()) {
    conditions.push(ilike(pages.title, `%${qParam.trim()}%`));
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
    .orderBy(asc(pages.type), asc(pages.title));

  return NextResponse.json({ pages: rows });
}

export async function POST(req: NextRequest) {
  const session = await auth();
  if (!session?.user?.email) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const userId = await resolveUserId(session.user.email);
  if (!userId) {
    return NextResponse.json({ error: "User not found" }, { status: 404 });
  }

  const body = (await req.json()) as {
    title?: string;
    body_md?: string;
    type?: string;
    source_thread_id?: string;
  };

  if (!body.title || !body.type) {
    return NextResponse.json(
      { error: "title and type are required" },
      { status: 400 }
    );
  }

  const slug =
    body.title
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
      type: body.type as PageType,
      title: body.title,
      body_md: body.body_md ?? "",
      status: "draft",
    })
    .returning();

  return NextResponse.json({ page: created }, { status: 201 });
}
