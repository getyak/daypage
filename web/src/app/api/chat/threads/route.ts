import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/lib/auth/session";
import { db } from "@/lib/db/client";
import { users, chat_threads } from "@/lib/db/schema";
import { eq, desc } from "drizzle-orm";
import { z } from "zod";

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

const CreateThreadSchema = z.object({
  title: z.string().min(1).max(200).optional(),
});

// GET /api/chat/threads — list user's threads ordered by updated_at desc
export async function GET(req: NextRequest) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const { searchParams } = new URL(req.url);
  const status = searchParams.get("status");

  let query = db
    .select()
    .from(chat_threads)
    .where(eq(chat_threads.user_id, userId))
    .orderBy(desc(chat_threads.updated_at))
    .$dynamic();

  if (status === "active" || status === "archived") {
    const { and } = await import("drizzle-orm");
    query = db
      .select()
      .from(chat_threads)
      .where(and(eq(chat_threads.user_id, userId), eq(chat_threads.status, status)))
      .orderBy(desc(chat_threads.updated_at))
      .$dynamic();
  }

  const rows = await query;
  return NextResponse.json({ items: rows });
}

// POST /api/chat/threads — create new thread
export async function POST(req: NextRequest) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const body: unknown = await req.json().catch(() => ({}));
  const parsed = CreateThreadSchema.safeParse(body ?? {});
  if (!parsed.success) {
    return badRequest(parsed.error.issues[0]?.message ?? "Validation error");
  }

  const [thread] = await db
    .insert(chat_threads)
    .values({
      user_id: userId,
      title: parsed.data.title ?? "New conversation",
      status: "active",
    })
    .returning();

  return NextResponse.json(thread, { status: 201 });
}
