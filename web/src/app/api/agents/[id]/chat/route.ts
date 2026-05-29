import "server-only";
import { NextRequest } from "next/server";
import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import {
  users,
  agents,
  chat_threads,
  chat_messages,
  prompt_log,
} from "@/lib/db/schema";
import { eq, and, gte, sum } from "drizzle-orm";
import { z } from "zod";
import { llm } from "@/lib/ai";
import { retrievePages, type RetrievedPage } from "@/lib/ai/rag";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

const DAILY_TOKEN_LIMIT = 100_000;
const LOW_SCORE_THRESHOLD = 0.4;

const ChatSchema = z.object({
  content: z.string().min(1).max(20_000),
  // Optional existing thread to continue; omit to start a new conversation.
  thread_id: z.string().uuid().optional(),
});

function sseEvent(data: Record<string, unknown>): string {
  return `data: ${JSON.stringify(data)}\n\n`;
}

function unauthorized(): Response {
  return new Response("Unauthorized", { status: 401 });
}
function notFound(): Response {
  return new Response("Not found", { status: 404 });
}
function badRequest(msg: string): Response {
  return new Response(JSON.stringify({ error: msg }), {
    status: 400,
    headers: { "Content-Type": "application/json" },
  });
}
function tooManyRequests(msg: string): Response {
  return new Response(JSON.stringify({ error: msg }), {
    status: 429,
    headers: { "Content-Type": "application/json" },
  });
}

async function resolveUserId(email: string): Promise<string | null> {
  const rows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, email))
    .limit(1);
  return rows[0]?.id ?? null;
}

async function getDailyTokens(userId: string): Promise<number> {
  const since = new Date();
  since.setUTCHours(0, 0, 0, 0);
  const rows = await db
    .select({
      total: sum(prompt_log.tokens_in).mapWith(Number),
      total_out: sum(prompt_log.tokens_out).mapWith(Number),
    })
    .from(prompt_log)
    .where(and(eq(prompt_log.user_id, userId), gte(prompt_log.created_at, since)));
  const row = rows[0];
  return (row?.total ?? 0) + (row?.total_out ?? 0);
}

/** Build the agent system prompt: persona + grounding rules + reference block. */
function buildSystemPrompt(persona: string, refs: RetrievedPage[]): string {
  const refBlock =
    refs.length === 0
      ? "(no relevant wiki pages were found for this query)"
      : refs
          .map(
            (p, i) =>
              `[${i + 1}] **${p.title}** (type: ${p.type})\n${(p.body_md ?? "").slice(0, 600)}`
          )
          .join("\n\n---\n\n");

  return `${persona.trim()}

You are grounded in the user's personal DayPage wiki. \
Prefer the REFERENCES below when answering and cite them inline as {N} where N is the reference number. \
Any claim about the user's life/notes that is NOT supported by a reference MUST be wrapped in *italic* and \
appended with [uncited] — for example: *This is not in your notes.* [uncited] \
Never invent facts about the user not present in the references. \
If the references do not contain enough information, say so clearly while staying in character.

REFERENCES:
${refBlock}`;
}

function isLowConfidence(refs: RetrievedPage[]): boolean {
  if (refs.length === 0) return true;
  return refs.every((r) => r.score < LOW_SCORE_THRESHOLD);
}

// POST /api/agents/:id/chat — RAG-grounded streaming chat with a user agent.
export async function POST(
  req: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();
  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const { id: agentId } = await params;

  const [agent] = await db
    .select()
    .from(agents)
    .where(and(eq(agents.id, agentId), eq(agents.user_id, userId)))
    .limit(1);
  if (!agent) return notFound();

  const bodyRaw: unknown = await req.json().catch(() => null);
  if (!bodyRaw) return badRequest("Invalid JSON body");
  const parsed = ChatSchema.safeParse(bodyRaw);
  if (!parsed.success)
    return badRequest(parsed.error.issues[0]?.message ?? "Validation error");
  const { content, thread_id } = parsed.data;

  const usedTokens = await getDailyTokens(userId);
  if (usedTokens >= DAILY_TOKEN_LIMIT) {
    return tooManyRequests("Daily token limit of 100k reached. Try again tomorrow.");
  }

  // Resolve (or create) the conversation thread, tagged with this agent.
  let threadId = thread_id;
  if (threadId) {
    const [t] = await db
      .select({ id: chat_threads.id })
      .from(chat_threads)
      .where(
        and(
          eq(chat_threads.id, threadId),
          eq(chat_threads.user_id, userId),
          eq(chat_threads.agent_id, agentId)
        )
      )
      .limit(1);
    if (!t) return notFound();
  } else {
    const [created] = await db
      .insert(chat_threads)
      .values({
        user_id: userId,
        agent_id: agentId,
        title: content.slice(0, 59) || `Chat with ${agent.name}`,
        status: "active",
      })
      .returning({ id: chat_threads.id });
    threadId = created?.id;
  }
  if (!threadId) return badRequest("Could not open a conversation");
  const activeThreadId = threadId;

  // Persist the user's message.
  const [userMsg] = await db
    .insert(chat_messages)
    .values({ thread_id: activeThreadId, role: "user", content })
    .returning({ id: chat_messages.id });
  const userMsgId = userMsg?.id ?? crypto.randomUUID();

  const stream = new ReadableStream({
    async start(controller) {
      const enc = new TextEncoder();
      let closed = false;

      req.signal.addEventListener("abort", () => {
        closed = true;
        try {
          controller.close();
        } catch {
          /* already closed */
        }
      });

      const send = (data: Record<string, unknown>) => {
        if (closed) return;
        try {
          controller.enqueue(enc.encode(sseEvent(data)));
        } catch {
          closed = true;
        }
      };

      try {
        // Always announce the thread id first so the client can keep the
        // conversation going on subsequent turns.
        send({ type: "thread", thread_id: activeThreadId });

        // Step 1: RAG recall — the SAME rag.ts retrievePages the MCP server uses,
        // scoped to the agent's domain (if any).
        send({ type: "step", step: "retrieving" });
        const refs = await retrievePages(userId, content, {
          topK: agent.top_k,
          domainId: agent.domain_id ?? undefined,
        });

        if (isLowConfidence(refs)) {
          const topic = content.slice(0, 60).trim();
          const idkContent = `I don't have enough in your wiki to answer that yet — try adding notes about "${topic}" first.`;
          const [assistantMsg] = await db
            .insert(chat_messages)
            .values({
              thread_id: activeThreadId,
              role: "assistant",
              content: idkContent,
              citations: null,
              tokens_in: 0,
              tokens_out: 0,
            })
            .returning({ id: chat_messages.id });
          await db
            .update(chat_threads)
            .set({ updated_at: new Date() })
            .where(eq(chat_threads.id, activeThreadId));

          send({ type: "token", content: idkContent });
          send({
            type: "done",
            message_id: assistantMsg?.id ?? crypto.randomUUID(),
            user_message_id: userMsgId,
            thread_id: activeThreadId,
            citations: [],
            references: [],
            tokens_in: 0,
            tokens_out: 0,
            idk: true,
          });
          return;
        }

        // Step 2: Build the persona-grounded prompt.
        const systemPrompt = buildSystemPrompt(agent.persona_prompt, refs);
        const messages: {
          role: "system" | "user" | "assistant";
          content: string;
        }[] = [{ role: "system", content: systemPrompt }];

        // Recent user history for continuity (last 10 user turns).
        const history = await db
          .select({ role: chat_messages.role, content: chat_messages.content })
          .from(chat_messages)
          .where(
            and(
              eq(chat_messages.thread_id, activeThreadId),
              eq(chat_messages.role, "user")
            )
          )
          .orderBy(chat_messages.created_at)
          .limit(10);
        for (const h of history) {
          messages.push({ role: h.role as "user" | "assistant", content: h.content });
        }

        // Step 3: Stream from the agent's selected model.
        send({ type: "step", step: "generating" });
        let fullContent = "";
        const { tokens_in, tokens_out } = await llm.chatStream(
          messages,
          (chunk) => {
            if (closed) return;
            fullContent += chunk;
            send({ type: "token", content: chunk });
          },
          { model: agent.model }
        );

        // Step 4: Parse {N} citations.
        const citedNums = new Set<number>();
        for (const match of fullContent.matchAll(/\{(\d+)\}/g)) {
          const n = parseInt(match[1], 10);
          if (n >= 1 && n <= refs.length) citedNums.add(n);
        }
        const citations = Array.from(citedNums).map((n) => {
          const ref = refs[n - 1];
          return {
            n,
            page_id: ref.page_id,
            slug: ref.slug,
            title: ref.title,
            type: ref.type,
            excerpt: (ref.body_md ?? "").slice(0, 200),
          };
        });

        // Step 5: Persist the assistant message.
        const [assistantMsg] = await db
          .insert(chat_messages)
          .values({
            thread_id: activeThreadId,
            role: "assistant",
            content: fullContent,
            citations: citations.length ? citations : null,
            tokens_in,
            tokens_out,
          })
          .returning({ id: chat_messages.id });
        await db
          .update(chat_threads)
          .set({ updated_at: new Date() })
          .where(eq(chat_threads.id, activeThreadId));

        const allRefs = refs.map((r, i) => ({
          n: i + 1,
          page_id: r.page_id,
          slug: r.slug,
          title: r.title,
          type: r.type,
          score: r.score,
          excerpt: (r.body_md ?? "").slice(0, 200),
        }));

        send({
          type: "done",
          message_id: assistantMsg?.id ?? crypto.randomUUID(),
          user_message_id: userMsgId,
          thread_id: activeThreadId,
          citations,
          references: allRefs,
          tokens_in,
          tokens_out,
          idk: false,
        });
      } catch (err: unknown) {
        const message = err instanceof Error ? err.message : String(err);
        send({ type: "error", message });
      } finally {
        if (!closed) {
          try {
            controller.close();
          } catch {
            /* already closed */
          }
        }
      }
    },
  });

  return new Response(stream, {
    headers: {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache, no-transform",
      Connection: "keep-alive",
      "X-Accel-Buffering": "no",
    },
  });
}
