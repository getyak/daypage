import { NextResponse } from "next/server";
import { auth } from "@/lib/auth/session";
import { db } from "@/lib/db/client";
import { users, inbox_items } from "@/lib/db/schema";
import { eq, and } from "drizzle-orm";

function unauthorized() {
  return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
}

function notFound() {
  return NextResponse.json({ error: "Not found" }, { status: 404 });
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

// POST /api/inbox/:id/dismiss
export async function POST(_req: Request, ctx: RouteContext) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const { id } = await ctx.params;

  const [updated] = await db
    .update(inbox_items)
    .set({ status: "dismissed", resolved_at: new Date() })
    .where(and(eq(inbox_items.id, id), eq(inbox_items.user_id, userId)))
    .returning();

  if (!updated) return notFound();
  return NextResponse.json(updated);
}
