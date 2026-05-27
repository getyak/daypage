import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db/client";
import { memos, activities } from "@/lib/db/schema";
import { z } from "zod";
import { authenticateApiKey } from "@/lib/api-auth";
import { sendEvent } from "@/lib/inngest/client";

function unauthorized() {
  return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
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

  const userId = apiAuth.userId;

  const raw: unknown = await req.json().catch(() => null);
  if (!raw) return badRequest("Invalid JSON body");

  const parsed = EmailIngestSchema.safeParse(raw);
  if (!parsed.success) {
    return badRequest(parsed.error.issues[0]?.message ?? "Validation error");
  }

  const { from, subject, body, attachments, idempotency_key } = parsed.data;

  const memoBody = subject ? `# ${subject}\n\n${body}` : body;

  const [memo] = await db
    .insert(memos)
    .values({
      user_id: userId,
      type: "text",
      body: memoBody,
      origin: "api",
      source: "email",
      device: "email",
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
