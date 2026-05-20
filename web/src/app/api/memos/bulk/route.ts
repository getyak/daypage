import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { memos, memo_attachments, users } from "@/lib/db/schema";
import { eq, sql } from "drizzle-orm";
import { BulkMemosSchema, BulkMemoItem } from "@/lib/schemas/memo";
import { checkMutationRateLimit } from "@/lib/ratelimit";

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

// POST /api/memos/bulk — iOS sync upsert (last-write-wins by updated_at)
export async function POST(req: NextRequest) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

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

  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const body: unknown = await req.json().catch(() => null);
  if (!body) return badRequest("Invalid JSON body");

  const parsed = BulkMemosSchema.safeParse(body);
  if (!parsed.success) {
    return badRequest(parsed.error.issues[0]?.message ?? "Validation error");
  }

  const items = parsed.data.memos;

  const accepted: string[] = [];
  const skipped: { id: string; reason: string }[] = [];

  for (const item of items) {
    const result = await upsertMemo(userId, item);
    if (result.ok) {
      accepted.push(item.id);
      // Upsert attachments for this memo if provided
      if (item.attachments?.length) {
        await db
          .delete(memo_attachments)
          .where(eq(memo_attachments.memo_id, item.id));
        await db.insert(memo_attachments).values(
          item.attachments.map((a) => ({
            memo_id: item.id,
            kind: a.kind,
            storage_key: a.storage_key,
            filename: a.filename ?? null,
            mime_type: a.mime_type ?? null,
            size_bytes: a.size_bytes ?? null,
            duration_sec: a.duration_sec ?? null,
            transcript: a.transcript ?? null,
            ocr_text: a.ocr_text ?? null,
            exif: a.exif ?? null,
          }))
        );
      }
    } else {
      skipped.push({ id: item.id, reason: result.reason });
    }
  }

  return NextResponse.json({ accepted, skipped }, { status: 200 });
}

async function upsertMemo(
  userId: string,
  item: BulkMemoItem
): Promise<{ ok: true } | { ok: false; reason: string }> {
  const incomingUpdatedAt = item.updated_at
    ? new Date(item.updated_at)
    : new Date();
  const incomingCreatedAt = item.created_at
    ? new Date(item.created_at)
    : new Date();

  try {
    await db
      .insert(memos)
      .values({
        id: item.id,
        user_id: userId,
        type: item.type ?? "text",
        body: item.body,
        created_at: incomingCreatedAt,
        location: item.location ?? null,
        weather: item.weather ?? null,
        device: item.device ?? null,
        source_url: item.source_url ?? null,
        origin: item.origin ?? "ios",
        ingest_mode: item.ingest_mode ?? "light",
        vault_path: item.vault_path ?? null,
        updated_at: incomingUpdatedAt,
      })
      .onConflictDoUpdate({
        target: memos.id,
        set: {
          // Only update if the incoming updated_at is newer than what's stored
          type: sql`CASE WHEN ${memos.updated_at} <= excluded.updated_at THEN excluded.type ELSE ${memos.type} END`,
          body: sql`CASE WHEN ${memos.updated_at} <= excluded.updated_at THEN excluded.body ELSE ${memos.body} END`,
          // Preserve existing location if backend's created_at is later
          location: sql`CASE
            WHEN ${memos.location} IS NOT NULL AND ${memos.created_at} > excluded.created_at
            THEN ${memos.location}
            WHEN ${memos.updated_at} <= excluded.updated_at
            THEN excluded.location
            ELSE ${memos.location}
          END`,
          weather: sql`CASE WHEN ${memos.updated_at} <= excluded.updated_at THEN excluded.weather ELSE ${memos.weather} END`,
          device: sql`CASE WHEN ${memos.updated_at} <= excluded.updated_at THEN excluded.device ELSE ${memos.device} END`,
          source_url: sql`CASE WHEN ${memos.updated_at} <= excluded.updated_at THEN excluded.source_url ELSE ${memos.source_url} END`,
          ingest_mode: sql`CASE WHEN ${memos.updated_at} <= excluded.updated_at THEN excluded.ingest_mode ELSE ${memos.ingest_mode} END`,
          vault_path: sql`CASE WHEN ${memos.updated_at} <= excluded.updated_at THEN excluded.vault_path ELSE ${memos.vault_path} END`,
          updated_at: sql`CASE WHEN ${memos.updated_at} <= excluded.updated_at THEN excluded.updated_at ELSE ${memos.updated_at} END`,
        },
        // Scope the conflict check: only update if the memo belongs to this user
        setWhere: eq(memos.user_id, userId),
      });
    return { ok: true };
  } catch (err) {
    const message = err instanceof Error ? err.message : "Unknown error";
    return { ok: false, reason: message };
  }
}
