import { NextResponse } from "next/server";
import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { users, memos, memo_attachments } from "@/lib/db/schema";
import { eq, and, gte, lt, desc } from "drizzle-orm";

export const revalidate = 0;

async function resolveUserId(email: string): Promise<string | null> {
  const rows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, email))
    .limit(1);
  return rows[0]?.id ?? null;
}

export async function GET() {
  const session = await auth();
  if (!session?.user?.email) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const userId = await resolveUserId(session.user.email);
  if (!userId) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const now = new Date();
  const todayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const tomorrowStart = new Date(todayStart.getTime() + 86_400_000);

  const rows = await db
    .select({
      id: memos.id,
      type: memos.type,
      body: memos.body,
      created_at: memos.created_at,
    })
    .from(memos)
    .where(
      and(
        eq(memos.user_id, userId),
        gte(memos.created_at, todayStart),
        lt(memos.created_at, tomorrowStart)
      )
    )
    .orderBy(desc(memos.created_at))
    .limit(50);

  // For photo/mixed memos, fetch the first photo attachment
  const photoMemoIds = rows
    .filter((m) => m.type === "photo")
    .map((m) => m.id);

  const attachments =
    photoMemoIds.length > 0
      ? await db
          .select({
            memo_id: memo_attachments.memo_id,
            storage_key: memo_attachments.storage_key,
          })
          .from(memo_attachments)
          .where(eq(memo_attachments.kind, "photo"))
      : [];

  const photoByMemoId = new Map(
    attachments
      .filter((a) => photoMemoIds.includes(a.memo_id))
      .map((a) => [a.memo_id, `/api/img/${a.storage_key}`])
  );

  const result = rows.map((m) => {
    const photoUrl = photoByMemoId.get(m.id) ?? null;
    // Derive display type: photo memo with non-empty body → "mixed"
    const displayType: "text" | "voice" | "photo" | "mixed" | "url" | "file" =
      m.type === "photo" && m.body.trim().length > 0 ? "mixed" : m.type;
    return {
      id: m.id,
      type: displayType,
      body: m.body,
      created_at: m.created_at.toISOString(),
      photo_url: photoUrl,
    };
  });

  return NextResponse.json({ memos: result });
}
