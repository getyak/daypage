import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { memos, users } from "@/lib/db/schema";
import { eq, and } from "drizzle-orm";
import { z } from "zod";

function unauthorized() {
  return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
}

function notFound() {
  return NextResponse.json({ error: "Not found" }, { status: 404 });
}

function badRequest(message: string) {
  return NextResponse.json({ error: message }, { status: 400 });
}

const EmbeddingSchema = z.object({
  embedding: z
    .array(z.number())
    .length(1536, "Embedding must be exactly 1536 dimensions"),
});

type RouteContext = { params: Promise<{ id: string }> };

// PATCH /api/memos/:id/embedding — upsert embedding vector
export async function PATCH(req: NextRequest, ctx: RouteContext) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userRows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, session.user.email))
    .limit(1);
  if (!userRows.length) return unauthorized();
  const userId = userRows[0].id;

  const { id } = await ctx.params;

  const body: unknown = await req.json().catch(() => null);
  if (!body) return badRequest("Invalid JSON body");

  const parsed = EmbeddingSchema.safeParse(body);
  if (!parsed.success) {
    return badRequest(parsed.error.issues[0]?.message ?? "Validation error");
  }

  const rows = await db
    .update(memos)
    .set({ embedding: parsed.data.embedding })
    .where(and(eq(memos.id, id), eq(memos.user_id, userId)))
    .returning({ id: memos.id, embedding: memos.embedding });

  if (!rows.length) return notFound();
  return NextResponse.json(rows[0]);
}
