import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { annotations, pages, users } from "@/lib/db/schema";
import { eq, and, asc } from "drizzle-orm";

function unauthorized() {
  return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
}

async function resolveUserId(email: string): Promise<string | null> {
  const rows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, email))
    .limit(1);
  return rows[0]?.id ?? null;
}

type RouteContext = { params: Promise<{ id: string }> };

// GET /api/pages/:id/annotations
export async function GET(_req: NextRequest, ctx: RouteContext) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const { id } = await ctx.params;

  // Verify page belongs to user
  const pageRows = await db
    .select({ id: pages.id })
    .from(pages)
    .where(and(eq(pages.id, id), eq(pages.user_id, userId)))
    .limit(1);

  if (!pageRows.length) {
    return NextResponse.json({ error: "Not found" }, { status: 404 });
  }

  const rows = await db
    .select()
    .from(annotations)
    .where(and(eq(annotations.page_id, id), eq(annotations.user_id, userId)))
    .orderBy(asc(annotations.created_at));

  return NextResponse.json({ annotations: rows });
}
