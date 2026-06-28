import { NextResponse } from "next/server";
import { auth } from "@/lib/auth/session";
import { db } from "@/lib/db/client";
import { users, user_settings } from "@/lib/db/schema";
import { eq } from "drizzle-orm";

// Draft stored in user_settings under key "add_draft"
interface AddDraft {
  text: string;
  mode: string;
  savedAt: string;
}

async function resolveUserId(email: string): Promise<string | null> {
  const rows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, email))
    .limit(1);
  return rows[0]?.id ?? null;
}

// GET /api/drafts/add — fetch the current user's saved /add draft
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
    .select({ settings: user_settings.settings })
    .from(user_settings)
    .where(eq(user_settings.user_id, userId))
    .limit(1);

  const settings = (rows[0]?.settings ?? {}) as Record<string, unknown>;
  const draft = (settings.add_draft ?? null) as AddDraft | null;

  return NextResponse.json({ draft });
}

// PUT /api/drafts/add — upsert the current user's /add draft
export async function PUT(req: Request) {
  const session = await auth();
  if (!session?.user?.email) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const userId = await resolveUserId(session.user.email);
  if (!userId) {
    return NextResponse.json({ error: "User not found" }, { status: 404 });
  }

  let body: Partial<AddDraft>;
  try {
    body = (await req.json()) as Partial<AddDraft>;
  } catch {
    return NextResponse.json({ error: "Invalid JSON" }, { status: 400 });
  }

  if (typeof body !== "object" || body === null) {
    return NextResponse.json({ error: "Body must be a JSON object" }, { status: 400 });
  }

  const draft: AddDraft = {
    text: typeof body.text === "string" ? body.text : "",
    mode: typeof body.mode === "string" ? body.mode : "text",
    savedAt: typeof body.savedAt === "string" ? body.savedAt : new Date().toISOString(),
  };

  // Fetch existing settings for merge
  const existing = await db
    .select({ settings: user_settings.settings })
    .from(user_settings)
    .where(eq(user_settings.user_id, userId))
    .limit(1);

  const current = (existing[0]?.settings ?? {}) as Record<string, unknown>;
  const merged = { ...current, add_draft: draft };

  await db
    .insert(user_settings)
    .values({ user_id: userId, settings: merged })
    .onConflictDoUpdate({
      target: [user_settings.user_id],
      set: { settings: merged, updated_at: new Date() },
    });

  return NextResponse.json({ draft });
}

// DELETE /api/drafts/add — clear the draft
export async function DELETE() {
  const session = await auth();
  if (!session?.user?.email) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const userId = await resolveUserId(session.user.email);
  if (!userId) {
    return NextResponse.json({ error: "User not found" }, { status: 404 });
  }

  const existing = await db
    .select({ settings: user_settings.settings })
    .from(user_settings)
    .where(eq(user_settings.user_id, userId))
    .limit(1);

  const current = (existing[0]?.settings ?? {}) as Record<string, unknown>;
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  const { add_draft: _removed, ...rest } = current;

  await db
    .insert(user_settings)
    .values({ user_id: userId, settings: rest })
    .onConflictDoUpdate({
      target: [user_settings.user_id],
      set: { settings: rest, updated_at: new Date() },
    });

  return NextResponse.json({ ok: true });
}
