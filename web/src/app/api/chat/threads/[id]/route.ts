import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { users, chat_threads, chat_messages } from "@/lib/db/schema";
import { eq, and, asc } from "drizzle-orm";
import { z } from "zod";
import { llm } from "@/lib/ai";

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

const PatchThreadSchema = z.object({
  title: z.string().min(1).max(200).optional(),
  status: z.enum(["active", "archived"]).optional(),
});

// GET /api/chat/threads/:id — return thread + messages
export async function GET(
  _req: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const { id } = await params;

  const [thread] = await db
    .select()
    .from(chat_threads)
    .where(and(eq(chat_threads.id, id), eq(chat_threads.user_id, userId)))
    .limit(1);

  if (!thread) return notFound();

  const messages = await db
    .select()
    .from(chat_messages)
    .where(eq(chat_messages.thread_id, id))
    .orderBy(asc(chat_messages.created_at));

  return NextResponse.json({ ...thread, messages });
}

// PATCH /api/chat/threads/:id — update title or status
export async function PATCH(
  req: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const { id } = await params;

  const body: unknown = await req.json().catch(() => null);
  if (!body) return badRequest("Invalid JSON body");

  const parsed = PatchThreadSchema.safeParse(body);
  if (!parsed.success) {
    return badRequest(parsed.error.issues[0]?.message ?? "Validation error");
  }

  const input = parsed.data;
  if (Object.keys(input).length === 0) return badRequest("No fields to update");

  const updates: Partial<{ title: string; status: "active" | "archived" }> = {};
  if (input.title !== undefined) updates.title = input.title;
  if (input.status !== undefined) updates.status = input.status;

  const [updated] = await db
    .update(chat_threads)
    .set(updates)
    .where(and(eq(chat_threads.id, id), eq(chat_threads.user_id, userId)))
    .returning();

  if (!updated) return notFound();

  return NextResponse.json(updated);
}

// DELETE /api/chat/threads/:id — soft-delete (set status to archived)
export async function DELETE(
  _req: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const { id } = await params;

  const [deleted] = await db
    .update(chat_threads)
    .set({ status: "archived" })
    .where(and(eq(chat_threads.id, id), eq(chat_threads.user_id, userId)))
    .returning();

  if (!deleted) return notFound();

  return new NextResponse(null, { status: 204 });
}

// Auto-title helper: schedule a qwen call to summarize first user message into <60 chars.
// Called internally when a user message is added to a thread that still has the default title.
export async function autoTitleThread(
  threadId: string,
  userId: string,
  firstUserMessage: string
): Promise<void> {
  try {
    const [thread] = await db
      .select({ title: chat_threads.title })
      .from(chat_threads)
      .where(and(eq(chat_threads.id, threadId), eq(chat_threads.user_id, userId)))
      .limit(1);

    if (!thread || thread.title !== "New conversation") return;

    const { content } = await llm.chat([
      {
        role: "system",
        content:
          "Generate a concise title (under 60 characters, no quotes) that summarizes the user's message. Reply with only the title text.",
      },
      { role: "user", content: firstUserMessage },
    ]);

    const title = content.trim().slice(0, 59);
    if (title) {
      await db
        .update(chat_threads)
        .set({ title })
        .where(and(eq(chat_threads.id, threadId), eq(chat_threads.user_id, userId)));
    }
  } catch {
    // Auto-title is best-effort — don't fail the message write if it errors
  }
}
