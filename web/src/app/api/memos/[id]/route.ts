import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/lib/auth/session";
import { db } from "@/lib/db/client";
import { memos, users } from "@/lib/db/schema";
import { eq, and } from "drizzle-orm";
import { PatchMemoSchema } from "@/lib/schemas/memo";
import { checkMutationRateLimit } from "@/lib/ratelimit";

function unauthorized() {
  return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
}

function notFound() {
  return NextResponse.json({ error: "Not found" }, { status: 404 });
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

type RouteContext = { params: Promise<{ id: string }> };

// GET /api/memos/:id
export async function GET(_req: NextRequest, ctx: RouteContext) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const { id } = await ctx.params;
  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const rows = await db
    .select()
    .from(memos)
    .where(and(eq(memos.id, id), eq(memos.user_id, userId)))
    .limit(1);

  if (!rows.length) return notFound();
  return NextResponse.json(rows[0]);
}

// PATCH /api/memos/:id — partial update
export async function PATCH(req: NextRequest, ctx: RouteContext) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const rl = await checkMutationRateLimit(session.user.email);
  if (!rl.success) {
    return NextResponse.json(
      { error: "Rate limit exceeded" },
      {
        status: 429,
        headers: { "Retry-After": Math.ceil((rl.reset - Date.now()) / 1000).toString() },
      }
    );
  }

  const { id } = await ctx.params;
  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const body: unknown = await req.json().catch(() => null);
  if (!body) return badRequest("Invalid JSON body");

  const parsed = PatchMemoSchema.safeParse(body);
  if (!parsed.success) {
    return badRequest(parsed.error.issues[0]?.message ?? "Validation error");
  }

  const input = parsed.data;
  const updateData: Record<string, unknown> = {};

  if (input.type !== undefined) updateData.type = input.type;
  if (input.body !== undefined) updateData.body = input.body;
  if (input.location !== undefined) updateData.location = input.location;
  if (input.weather !== undefined) updateData.weather = input.weather;
  if (input.device !== undefined) updateData.device = input.device;
  if (input.source_url !== undefined) updateData.source_url = input.source_url;
  if (input.ingest_mode !== undefined) updateData.ingest_mode = input.ingest_mode;
  if (input.compile_status !== undefined) updateData.compile_status = input.compile_status;
  if (input.pinned_at !== undefined) {
    updateData.pinned_at = input.pinned_at ? new Date(input.pinned_at) : null;
  }

  if (Object.keys(updateData).length === 0) {
    return badRequest("No fields to update");
  }

  const rows = await db
    .update(memos)
    .set(updateData)
    .where(and(eq(memos.id, id), eq(memos.user_id, userId)))
    .returning();

  if (!rows.length) return notFound();
  return NextResponse.json(rows[0]);
}

// DELETE /api/memos/:id — soft delete via compile_status='failed' is not right;
// the schema has no deleted_at, so we do a hard delete scoped to the user.
export async function DELETE(_req: NextRequest, ctx: RouteContext) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const rl = await checkMutationRateLimit(session.user.email);
  if (!rl.success) {
    return NextResponse.json(
      { error: "Rate limit exceeded" },
      {
        status: 429,
        headers: { "Retry-After": Math.ceil((rl.reset - Date.now()) / 1000).toString() },
      }
    );
  }

  const { id } = await ctx.params;
  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const rows = await db
    .delete(memos)
    .where(and(eq(memos.id, id), eq(memos.user_id, userId)))
    .returning({ id: memos.id });

  if (!rows.length) return notFound();
  return new NextResponse(null, { status: 204 });
}
