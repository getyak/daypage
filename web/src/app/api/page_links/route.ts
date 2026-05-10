import { NextResponse } from "next/server";
import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { users, page_links, pages } from "@/lib/db/schema";
import { eq } from "drizzle-orm";

async function resolveUserId(email: string): Promise<string | null> {
  const rows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, email))
    .limit(1);
  return rows[0]?.id ?? null;
}

export async function GET() {
  const session = await auth();
  if (!session?.user?.email) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const userId = await resolveUserId(session.user.email);
  if (!userId) {
    return NextResponse.json({ links: [], nodes: [] });
  }

  const [links, userPages] = await Promise.all([
    db
      .select({
        id: page_links.id,
        from_page_id: page_links.from_page_id,
        to_page_id: page_links.to_page_id,
        weight: page_links.weight,
        rationale: page_links.rationale,
      })
      .from(page_links)
      .where(eq(page_links.user_id, userId)),
    db
      .select({
        id: pages.id,
        slug: pages.slug,
        type: pages.type,
        title: pages.title,
        status: pages.status,
        source_count: pages.source_count,
        backlink_count: pages.backlink_count,
      })
      .from(pages)
      .where(eq(pages.user_id, userId)),
  ]);

  return NextResponse.json({ nodes: userPages, links });
}
