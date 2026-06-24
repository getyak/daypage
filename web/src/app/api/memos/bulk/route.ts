import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { memos, memo_attachments, users } from "@/lib/db/schema";
import { eq, sql } from "drizzle-orm";
import { BulkMemosSchema, BulkMemoItem } from "@/lib/schemas/memo";
import { checkMutationRateLimit } from "@/lib/ratelimit";
import { authenticateApiKey, hasScope } from "@/lib/api-auth";

function unauthorized() {
  return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
}

function forbidden(message: string) {
  return NextResponse.json({ error: message }, { status: 403 });
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

/**
 * Resolve the acting user for a bulk-sync request. Two auth paths:
 *
 *  1. **API Key Bearer** (iOS sync, third-party clients) — the iOS app holds
 *     a `write`-scoped key the user generated under web Settings → API Keys.
 *     The key's `user_id` binds the memos to the right account, so no
 *     Supabase↔NextAuth email bridge is needed. This mirrors the existing
 *     `/api/ingest` auth model.
 *  2. **NextAuth session** (web itself) — unchanged from the original
 *     behaviour; a logged-in browser session resolves to its user by email.
 *
 * Returns the resolved `userId`, or a ready-to-send error `Response` (401 for
 * no/invalid credentials, 403 for a valid key lacking the `write` scope) plus
 * a `rateKey` used to scope mutation rate limiting per key/user.
 */
async function resolveActor(
  req: NextRequest
): Promise<
  | { userId: string; rateKey: string }
  | { error: NextResponse }
> {
  // Path 1: API key (preferred for non-browser clients).
  const apiAuth = await authenticateApiKey(req);
  if (apiAuth) {
    if (!hasScope(apiAuth, "write")) {
      return { error: forbidden("API key requires 'write' scope") };
    }
    // Rate-limit by user id so multiple keys for the same user share a budget.
    return { userId: apiAuth.userId, rateKey: `apikey:${apiAuth.userId}` };
  }

  // Path 2: NextAuth browser session (web self-calls).
  const session = await auth();
  if (session?.user?.email) {
    const userId = await resolveUserId(session.user.email);
    if (userId) return { userId, rateKey: session.user.email };
  }

  return { error: unauthorized() };
}

// POST /api/memos/bulk — iOS sync upsert (last-write-wins by updated_at)
export async function POST(req: NextRequest) {
  const actor = await resolveActor(req);
  if ("error" in actor) return actor.error;
  const { userId, rateKey } = actor;

  const rl = await checkMutationRateLimit(rateKey);
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
