import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { memos, memo_attachments } from "@/lib/db/schema";
import { eq, and, lt, gte, desc } from "drizzle-orm";
import { CreateMemoSchema, ListMemosQuerySchema } from "@/lib/schemas/memo";
import { checkMutationRateLimit } from "@/lib/ratelimit";

function unauthorized() {
  return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
}

function badRequest(message: string) {
  return NextResponse.json({ error: message }, { status: 400 });
}

// GET /api/memos — list with cursor pagination + since filter
export async function GET(req: NextRequest) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  // Resolve user_id from session email
  const { users } = await import("@/lib/db/schema");
  const userRows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, session.user.email))
    .limit(1);

  if (!userRows.length) return unauthorized();
  const userId = userRows[0].id;

  const params = Object.fromEntries(req.nextUrl.searchParams.entries());
  const parsed = ListMemosQuerySchema.safeParse(params);
  if (!parsed.success) {
    return badRequest(parsed.error.issues[0]?.message ?? "Invalid query");
  }

  const { cursor, since, compile_status, limit } = parsed.data;

  const conditions = [eq(memos.user_id, userId)];

  if (compile_status) {
    const { compileStatusEnum: _e, ...rest } = await import("@/lib/db/schema");
    void rest;
    conditions.push(eq(memos.compile_status, compile_status));
  }

  if (since) {
    conditions.push(gte(memos.created_at, new Date(since)));
  }

  if (cursor) {
    conditions.push(lt(memos.created_at, new Date(cursor)));
  }

  const rows = await db
    .select()
    .from(memos)
    .where(and(...conditions))
    .orderBy(desc(memos.created_at))
    .limit(limit + 1);

  const hasMore = rows.length > limit;
  const items = hasMore ? rows.slice(0, limit) : rows;
  const nextCursor =
    hasMore ? items[items.length - 1].created_at.toISOString() : null;

  return NextResponse.json({ items, next_cursor: nextCursor, has_more: hasMore });
}

// POST /api/memos — create memo
export async function POST(req: NextRequest) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  // Rate limit
  const rl = await checkMutationRateLimit(session.user.email);
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

  const body: unknown = await req.json().catch(() => null);
  if (!body) return badRequest("Invalid JSON body");

  const parsed = CreateMemoSchema.safeParse(body);
  if (!parsed.success) {
    return badRequest(parsed.error.issues[0]?.message ?? "Validation error");
  }

  const input = parsed.data;

  // Resolve user_id
  const { users } = await import("@/lib/db/schema");
  const userRows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, session.user.email))
    .limit(1);

  if (!userRows.length) return unauthorized();
  const userId = userRows[0].id;

  const [memo] = await db
    .insert(memos)
    .values({
      user_id: userId,
      type: input.type,
      body: input.body,
      created_at: input.created_at ? new Date(input.created_at) : undefined,
      location: input.location ?? null,
      weather: input.weather ?? null,
      device: input.device ?? null,
      source_url: input.source_url ?? null,
      origin: input.origin,
      ingest_mode: input.ingest_mode,
      vault_path: input.vault_path ?? null,
    })
    .returning();

  // Insert attachments if provided
  if (input.attachments?.length && memo) {
    await db.insert(memo_attachments).values(
      input.attachments.map((a) => ({
        memo_id: memo.id,
        kind: a.kind,
        storage_key: a.storage_key,
        filename: a.filename ?? null,
        mime_type: a.mime_type ?? null,
        size_bytes: a.size_bytes ?? null,
        duration_sec: a.duration_sec ? String(a.duration_sec) : null,
        transcript: a.transcript ?? null,
        ocr_text: a.ocr_text ?? null,
        exif: a.exif ?? null,
      }))
    );
  }

  return NextResponse.json(memo, { status: 201 });
}
