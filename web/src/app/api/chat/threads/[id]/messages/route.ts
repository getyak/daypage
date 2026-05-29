import "server-only";
import { NextRequest } from "next/server";
import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { users, chat_threads, chat_messages, prompt_log } from "@/lib/db/schema";
import { eq, and, gte, sum } from "drizzle-orm";
import { z } from "zod";
import { llm } from "@/lib/ai";
import { retrievePages, type RetrievedPage } from "@/lib/ai/rag";
import { getAssistantPersona, personaPreamble } from "@/lib/ai/persona";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

const DAILY_TOKEN_LIMIT = 100_000;
const LOW_SCORE_THRESHOLD = 0.4;

const SendMessageSchema = z.object({
  content: z.string().min(1).max(20_000),
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
    .select({ total: sum(prompt_log.tokens_in).mapWith(Number), total_out: sum(prompt_log.tokens_out).mapWith(Number) })
    .from(prompt_log)
    .where(and(eq(prompt_log.user_id, userId), gte(prompt_log.created_at, since)));
  const row = rows[0];
  return (row?.total ?? 0) + (row?.total_out ?? 0);
}

function buildSystemPrompt(refs: RetrievedPage[], persona: string | null): string {
  const preamble = personaPreamble(persona);

  if (refs.length === 0) {
    return `${preamble}You are a helpful assistant. You have no reference pages available for this query.`;
  }

  const refBlock = refs
    .map(
      (p, i) =>
        `[${i + 1}] **${p.title}** (type: ${p.type})\n${(p.body_md ?? "").slice(0, 600)}`
    )
    .join("\n\n---\n\n");

  return `${preamble}You are a knowledgeable assistant with access to the user's personal wiki pages. \
Answer using ONLY the information in the references below. \
When you use information from a reference, cite it inline as {N} where N is the reference number. \
IMPORTANT: Any sentence that does not have a supporting reference MUST be wrapped in *italic* and \
appended with [uncited] — for example: *This fact has no citation.* [uncited] \
Never invent facts not present in the references. \
If the references do not contain enough information to answer, say so clearly.

REFERENCES:
${refBlock}`;
}

/** Returns true if retrievePages returned no useful results (0 items or all scores below threshold). */
export function isLowConfidence(refs: RetrievedPage[]): boolean {
  if (refs.length === 0) return true;
  return refs.every((r) => r.score < LOW_SCORE_THRESHOLD);
}

const IDK_MESSAGE =
  "I don't know yet — try adding content about that topic first.";

async function generateSuggestedFollowups(
  userMessage: string,
  assistantMessage: string
): Promise<string[]> {
  try {
    const context = `User: ${userMessage.slice(0, 500)}\nAssistant: ${assistantMessage.slice(0, 800)}`;
    const { content } = await llm.chat(
      [
        {
          role: "system",
          content:
            'You are a helpful assistant. Given the conversation context, suggest 3 short follow-up questions the user might want to ask next. Each question must be under 80 characters and directly relevant to the topic. Return ONLY valid JSON: {"questions": ["q1", "q2", "q3"]}',
        },
        { role: "user", content: `Conversation context:\n${context}` },
      ],
      { jsonMode: true, temperature: 0.8, maxTokens: 256 }
    );

    const parsed = JSON.parse(content) as { questions?: unknown };
    if (
      parsed &&
      Array.isArray(parsed.questions) &&
      parsed.questions.every((q) => typeof q === "string")
    ) {
      return (parsed.questions as string[]).slice(0, 3);
    }
    return [];
  } catch {
    return [];
  }
}

// POST /api/chat/threads/:id/messages — send a message and stream the response
export async function POST(
  req: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const { id: threadId } = await params;

  // Verify thread belongs to user
  const [thread] = await db
    .select({ id: chat_threads.id, title: chat_threads.title })
    .from(chat_threads)
    .where(and(eq(chat_threads.id, threadId), eq(chat_threads.user_id, userId)))
    .limit(1);
  if (!thread) return notFound();

  // Parse body
  const bodyRaw: unknown = await req.json().catch(() => null);
  if (!bodyRaw) return badRequest("Invalid JSON body");
  const parsed = SendMessageSchema.safeParse(bodyRaw);
  if (!parsed.success) return badRequest(parsed.error.issues[0]?.message ?? "Validation error");
  const { content } = parsed.data;

  // US-032: resolve the user's knowledge-assistant persona once, up front, so it
  // can be injected into the system prompt below.
  const persona = await getAssistantPersona(userId);

  // Step 7: Check daily token limit (before streaming so we can return 429 synchronously)
  const usedTokens = await getDailyTokens(userId);
  if (usedTokens >= DAILY_TOKEN_LIMIT) {
    return tooManyRequests("Daily token limit of 100k reached. Try again tomorrow.");
  }

  // Step 1: Write user message
  const [userMsg] = await db
    .insert(chat_messages)
    .values({ thread_id: threadId, role: "user", content })
    .returning({ id: chat_messages.id });

  const userMsgId = userMsg?.id ?? crypto.randomUUID();

  // Auto-title on first message (fire-and-forget)
  if (thread.title === "New conversation") {
    void autoTitleThread(threadId, userId, content);
  }

  // Stream the rest
  const stream = new ReadableStream({
    async start(controller) {
      const enc = new TextEncoder();
      let closed = false;

      req.signal.addEventListener("abort", () => {
        closed = true;
        try { controller.close(); } catch { /* already closed */ }
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
        // Step 2: Retrieve relevant pages
        send({ type: "step", step: "retrieving" });
        const refs = await retrievePages(userId, content, { topK: 8 });

        // I-don't-know fallback: no results or all scores below threshold
        if (isLowConfidence(refs)) {
          const topic = content.slice(0, 60).trim();
          const idkContent = `I don't know yet — try adding content about "${topic}" first.`;

          const [assistantMsg] = await db
            .insert(chat_messages)
            .values({
              thread_id: threadId,
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
            .where(eq(chat_threads.id, threadId));

          send({
            type: "token",
            content: idkContent,
          });
          send({
            type: "done",
            message_id: assistantMsg?.id ?? crypto.randomUUID(),
            user_message_id: userMsgId,
            citations: [],
            references: [],
            tokens_in: 0,
            tokens_out: 0,
            suggested_followups: [],
            idk: true,
          });
          return;
        }

        // Step 3: Build prompt
        const systemPrompt = buildSystemPrompt(refs, persona);
        const messages: { role: "system" | "user" | "assistant"; content: string }[] = [
          { role: "system", content: systemPrompt },
        ];

        // Include recent thread history (last 10 messages) for context
        const history = await db
          .select({ role: chat_messages.role, content: chat_messages.content })
          .from(chat_messages)
          .where(and(eq(chat_messages.thread_id, threadId), eq(chat_messages.role, "user")))
          .orderBy(chat_messages.created_at)
          .limit(10);

        for (const h of history) {
          messages.push({ role: h.role as "user" | "assistant", content: h.content });
        }

        // Step 4: Stream from LLM (DeepSeek)
        send({ type: "step", step: "generating" });
        let fullContent = "";

        const { tokens_in, tokens_out } = await llm.chatStream(
          messages,
          (chunk) => {
            if (closed) return;
            fullContent += chunk;
            send({ type: "token", content: chunk });
          }
        );

        // Step 5: Parse {N} citation tokens
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

        // Step 6: Write assistant message
        const [assistantMsg] = await db
          .insert(chat_messages)
          .values({
            thread_id: threadId,
            role: "assistant",
            content: fullContent,
            citations: citations.length ? citations : null,
            tokens_in,
            tokens_out,
          })
          .returning({ id: chat_messages.id });

        // Update thread updated_at via a no-op patch
        await db
          .update(chat_threads)
          .set({ updated_at: new Date() })
          .where(eq(chat_threads.id, threadId));

        // Generate suggested follow-ups (lightweight, fire after main response)
        send({ type: "step", step: "suggesting" });
        const suggestedFollowups = await generateSuggestedFollowups(content, fullContent);

        // Emit done with all reference metadata (not just cited ones)
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
          citations,
          references: allRefs,
          tokens_in,
          tokens_out,
          suggested_followups: suggestedFollowups,
          idk: false,
        });
      } catch (err: unknown) {
        const message = err instanceof Error ? err.message : String(err);
        send({ type: "error", message });
      } finally {
        if (!closed) {
          try { controller.close(); } catch { /* already closed */ }
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

async function autoTitleThread(threadId: string, userId: string, firstUserMessage: string) {
  try {
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
    // best-effort, don't surface
  }
}
