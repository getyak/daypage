import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { memos, users } from "@/lib/db/schema";
import { eq, and } from "drizzle-orm";
import { inngest } from "@/lib/inngest/client";

function unauthorized() {
  return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
}

function notFound() {
  return NextResponse.json({ error: "Not found" }, { status: 404 });
}

type RouteContext = { params: Promise<{ id: string }> };

// POST /api/memos/:id/recompile — reset compile_status to pending and re-send inngest event
export async function POST(_req: NextRequest, ctx: RouteContext) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userRows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, session.user.email))
    .limit(1);

  const userId = userRows[0]?.id;
  if (!userId) return unauthorized();

  const { id } = await ctx.params;

  const rows = await db
    .select({ id: memos.id })
    .from(memos)
    .where(and(eq(memos.id, id), eq(memos.user_id, userId)))
    .limit(1);

  if (!rows.length) return notFound();

  // Reset compile state
  await db
    .update(memos)
    .set({ compile_status: "pending", compile_error: null })
    .where(and(eq(memos.id, id), eq(memos.user_id, userId)));

  // Re-trigger compilation pipeline
  await inngest.send({ name: "memo/created", data: { memo_id: id } });

  return NextResponse.json({ ok: true });
}
