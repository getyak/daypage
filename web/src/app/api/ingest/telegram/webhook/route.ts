import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db/client";
import { memos, activities, ingest_sources } from "@/lib/db/schema";
import { eq, and } from "drizzle-orm";
import { sendEvent } from "@/lib/inngest/client";

// Telegram Update object (partial — only fields we use)
interface TelegramMessage {
  message_id: number;
  from?: { id: number; username?: string; first_name?: string };
  chat: { id: number; type: string };
  text?: string;
  photo?: { file_id: string }[];
  voice?: { file_id: string; duration: number };
  caption?: string;
  date: number;
}

interface TelegramUpdate {
  update_id: number;
  message?: TelegramMessage;
}

async function logActivity(userId: string, verb: string, subject: string, targetType: string, targetId: string) {
  await db.insert(activities).values({ user_id: userId, verb, subject, target_type: targetType, target_id: targetId });
}

// POST /api/ingest/telegram/webhook
export async function POST(req: NextRequest) {
  // Verify secret token sent by Telegram
  const secretToken = process.env.TELEGRAM_WEBHOOK_SECRET;
  if (secretToken) {
    const provided = req.headers.get("X-Telegram-Bot-Api-Secret-Token");
    if (provided !== secretToken) {
      // Return 200 to avoid Telegram retrying; just ignore
      return NextResponse.json({ ok: true });
    }
  }

  let update: TelegramUpdate;
  try {
    update = (await req.json()) as TelegramUpdate;
  } catch {
    return NextResponse.json({ ok: true });
  }

  const message = update.message;
  if (!message) return NextResponse.json({ ok: true });

  const chatId = String(message.chat.id);

  // Find the user linked to this Telegram chat_id via ingest_sources config
  const sources = await db
    .select()
    .from(ingest_sources)
    .where(and(eq(ingest_sources.source_type, "telegram"), eq(ingest_sources.enabled, true)));

  const matchingSource = sources.find((s) => {
    const cfg = s.config as Record<string, unknown>;
    return String(cfg.chat_id) === chatId;
  });

  if (!matchingSource) {
    // Unknown chat — no user linked; still return 200
    return NextResponse.json({ ok: true });
  }

  const userId = matchingSource.user_id;

  let memoBody: string;
  if (message.text) {
    memoBody = message.text;
  } else if (message.photo) {
    memoBody = message.caption ? `[photo] ${message.caption}` : "[photo received]";
  } else if (message.voice) {
    memoBody = "[voice message]";
  } else {
    return NextResponse.json({ ok: true });
  }

  const [memo] = await db
    .insert(memos)
    .values({
      user_id: userId,
      type: "text",
      body: memoBody,
      origin: "api",
      device: "telegram",
      created_at: new Date(message.date * 1000),
      idempotency_key: `telegram:${update.update_id}`,
    })
    .returning();

  if (memo) {
    await sendEvent({ name: "memo/created", data: { memo_id: memo.id } });
    await logActivity(userId, "ingest", "telegram", "memo", memo.id);
  }

  return NextResponse.json({ ok: true });
}
