import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db/client";
import { memos, activities, ingest_sources } from "@/lib/db/schema";
import { eq, and, desc } from "drizzle-orm";
import { z } from "zod";
import { authenticateApiKey, hasScope } from "@/lib/api-auth";
import { sendEvent } from "@/lib/inngest/client";
import { checkRateLimit } from "@/lib/ratelimit";

function unauthorized() {
  return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
}

function forbidden(message: string) {
  return NextResponse.json({ error: message }, { status: 403 });
}

function badRequest(message: string) {
  return NextResponse.json({ error: message }, { status: 400 });
}

const EmailIngestSchema = z.object({
  from: z.string().min(1),
  subject: z.string().default(""),
  body: z.string().min(1),
  attachments: z
    .array(
      z.object({
        filename: z.string(),
        content_type: z.string(),
        size: z.number().optional(),
      })
    )
    .optional(),
  idempotency_key: z.string().optional(),
});

// POST /api/ingest/email — receive inbound email and create a memo
export async function POST(req: NextRequest) {
  const apiAuth = await authenticateApiKey(req);
  if (!apiAuth) return unauthorized();
  // Email ingest is write-only — require the "write" scope.
  if (!hasScope(apiAuth, "write")) {
    return forbidden("API key lacks 'write' scope");
  }

  const userId = apiAuth.userId;

  // Rate limit per authenticated user — email ingest writes memos and fires a
  // compile event per call; cap it so a compromised key can't flood the pipeline.
  const rl = checkRateLimit(`ingest-email:${userId}`, 60, 60_000);
  if (!rl.success) {
    return NextResponse.json(
      { error: "Rate limit exceeded" },
      {
        status: 429,
        headers: {
          "Retry-After": Math.ceil((rl.reset - Date.now()) / 1000).toString(),
          "X-RateLimit-Remaining": "0",
        },
      }
    );
  }

  const raw: unknown = await req.json().catch(() => null);
  if (!raw) return badRequest("Invalid JSON body");

  const parsed = EmailIngestSchema.safeParse(raw);
  if (!parsed.success) {
    return badRequest(parsed.error.issues[0]?.message ?? "Validation error");
  }

  const { from, subject, body, attachments, idempotency_key } = parsed.data;

  const memoBody = subject ? `# ${subject}\n\n${body}` : body;

  // US-022: inherit the compile tier declared by the user's email source, if any.
  const [emailSource] = await db
    .select({ default_ingest_mode: ingest_sources.default_ingest_mode })
    .from(ingest_sources)
    .where(
      and(
        eq(ingest_sources.user_id, userId),
        eq(ingest_sources.source_type, "email"),
        eq(ingest_sources.enabled, true)
      )
    )
    .orderBy(desc(ingest_sources.created_at))
    .limit(1);

  const [memo] = await db
    .insert(memos)
    .values({
      user_id: userId,
      type: "text",
      body: memoBody,
      origin: "api",
      source: "email",
      device: "email",
      ingest_mode: emailSource?.default_ingest_mode ?? "light",
      idempotency_key: idempotency_key ?? `email:${from}:${Date.now()}`,
      word_count: memoBody.split(/\s+/).filter(Boolean).length,
    })
    .onConflictDoNothing()
    .returning();

  if (!memo) {
    // idempotency_key collision — already ingested
    return NextResponse.json({ deduplicated: true }, { status: 200 });
  }

  await sendEvent({ name: "memo/created", data: { memo_id: memo.id } });
  await db.insert(activities).values({
    user_id: userId,
    verb: "ingest",
    subject: "email",
    target_type: "memo",
    target_id: memo.id,
  });

  return NextResponse.json(
    {
      id: memo.id,
      source: "email",
      from,
      subject,
      attachments_received: attachments?.length ?? 0,
    },
    { status: 201 }
  );
}
