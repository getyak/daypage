import { NextResponse } from "next/server";
import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { users, user_settings } from "@/lib/db/schema";
import { eq } from "drizzle-orm";

async function resolveUserId(email: string): Promise<string | null> {
  const rows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, email))
    .limit(1);
  return rows[0]?.id ?? null;
}

// GET /api/settings — return current user's cloud-synced settings
export async function GET() {
  const session = await auth();
  if (!session?.user?.email) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const userId = await resolveUserId(session.user.email);
  if (!userId) {
    return NextResponse.json({ error: "User not found" }, { status: 404 });
  }

  const rows = await db
    .select({ settings: user_settings.settings, updated_at: user_settings.updated_at })
    .from(user_settings)
    .where(eq(user_settings.user_id, userId))
    .limit(1);

  const row = rows[0];
  return NextResponse.json({
    settings: row?.settings ?? {},
    updated_at: row?.updated_at ?? null,
  });
}

// PUT /api/settings — merge-upsert settings
export async function PUT(req: Request) {
  const session = await auth();
  if (!session?.user?.email) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const userId = await resolveUserId(session.user.email);
  if (!userId) {
    return NextResponse.json({ error: "User not found" }, { status: 404 });
  }

  let body: Record<string, unknown>;
  try {
    body = (await req.json()) as Record<string, unknown>;
  } catch {
    return NextResponse.json({ error: "Invalid JSON" }, { status: 400 });
  }

  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return NextResponse.json({ error: "Body must be a JSON object" }, { status: 400 });
  }

  // Fetch existing settings for merge
  const existing = await db
    .select({ settings: user_settings.settings })
    .from(user_settings)
    .where(eq(user_settings.user_id, userId))
    .limit(1);

  const current = (existing[0]?.settings ?? {}) as Record<string, unknown>;
  const merged = { ...current, ...body };

  const [updated] = await db
    .insert(user_settings)
    .values({ user_id: userId, settings: merged })
    .onConflictDoUpdate({
      target: [user_settings.user_id],
      set: { settings: merged, updated_at: new Date() },
    })
    .returning({ updated_at: user_settings.updated_at });

  return NextResponse.json({ settings: merged, updated_at: updated?.updated_at ?? null });
}
