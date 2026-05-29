import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { users } from "@/lib/db/schema";
import { eq } from "drizzle-orm";
import { getEntityEvolution, type TemporalWindow } from "@/lib/temporal";

async function resolveUserId(email: string): Promise<string | null> {
  const rows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, email))
    .limit(1);
  return rows[0]?.id ?? null;
}

// GET /api/pages/:slug/evolution?asOf=&from=&to=
// How a concept evolved over time: a month-by-month series of dated mentions
// (US-040). Honours an as-of point or a from/to date window.
export async function GET(
  req: NextRequest,
  { params }: { params: Promise<{ slug: string }> }
) {
  const { slug } = await params;
  const session = await auth();
  if (!session?.user?.email) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }
  const userId = await resolveUserId(session.user.email);
  if (!userId) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const sp = req.nextUrl.searchParams;
  const w: TemporalWindow = {
    asOf: sp.get("asOf") || undefined,
    from: sp.get("from") || undefined,
    to: sp.get("to") || undefined,
  };

  const evolution = await getEntityEvolution(userId, slug, w);
  if (!evolution) {
    return NextResponse.json({ error: "Not found" }, { status: 404 });
  }
  return NextResponse.json({ evolution });
}
