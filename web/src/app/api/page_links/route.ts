import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/lib/auth/session";
import { db } from "@/lib/db/client";
import { users, page_links, pages } from "@/lib/db/schema";
import { eq } from "drizzle-orm";
import { getTemporalGraph, type TemporalWindow } from "@/lib/temporal";

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
    return NextResponse.json({ links: [], nodes: [] });
  }

  // US-040: when a temporal window is requested, return the time-aware graph
  // (as-of / date-window). Otherwise return the full current graph unchanged.
  const sp = req.nextUrl.searchParams;
  const w: TemporalWindow = {
    asOf: sp.get("asOf") || undefined,
    from: sp.get("from") || undefined,
    to: sp.get("to") || undefined,
  };
  if (w.asOf || w.from || w.to) {
    const g = await getTemporalGraph(userId, w);
    const nodes = g.nodes.map((n) => ({
      id: n.id,
      slug: n.slug,
      type: n.type,
      title: n.title,
      status: "live",
      source_count: 0,
      backlink_count: 0,
    }));
    const links = g.edges.map((e, i) => ({
      id: `t${i}`,
      from_page_id: e.from_page_id,
      to_page_id: e.to_page_id,
      weight: 1,
      rationale: e.rationale,
    }));
    return NextResponse.json({ nodes, links, asOf: w.asOf, from: w.from, to: w.to });
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
