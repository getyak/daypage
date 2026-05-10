import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { users, chat_threads, chat_messages } from "@/lib/db/schema";
import { eq, and, asc } from "drizzle-orm";
import { notFound } from "next/navigation";
import Link from "next/link";
import { desc } from "drizzle-orm";
import { ChatView } from "./ChatView";

async function resolveUserId(email: string): Promise<string | null> {
  const rows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, email))
    .limit(1);
  return rows[0]?.id ?? null;
}

export default async function ChatThreadPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const session = await auth();
  if (!session?.user?.email) return notFound();

  const userId = await resolveUserId(session.user.email);
  if (!userId) return notFound();

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

  const threads = await db
    .select({
      id: chat_threads.id,
      title: chat_threads.title,
      updated_at: chat_threads.updated_at,
    })
    .from(chat_threads)
    .where(eq(chat_threads.user_id, userId))
    .orderBy(desc(chat_threads.updated_at))
    .limit(50);

  const serializedMessages = messages.map((m) => ({
    id: m.id,
    role: m.role as "user" | "assistant",
    content: m.content,
    citations: (m.citations as Citation[] | null) ?? null,
    created_at: m.created_at.toISOString(),
  }));

  const serializedThreads = threads.map((t) => ({
    id: t.id,
    title: t.title,
    updated_at: t.updated_at.toISOString(),
  }));

  return (
    <ChatView
      threadId={id}
      threadTitle={thread.title}
      initialMessages={serializedMessages}
      threads={serializedThreads}
    />
  );
}

export interface Citation {
  n: number;
  page_id: string;
  slug: string;
  title: string;
  type: string;
  excerpt: string;
}
