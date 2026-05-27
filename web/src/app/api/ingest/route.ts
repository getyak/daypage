import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { users, memos, inbox_items, activities } from "@/lib/db/schema";
import { eq } from "drizzle-orm";
import { z } from "zod";
import { authenticateApiKey } from "@/lib/api-auth";
import { sendEvent } from "@/lib/inngest/client";

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

async function logActivity(
  userId: string,
  verb: string,
  subject: string,
  targetType: string,
  targetId: string
) {
  await db.insert(activities).values({
    user_id: userId,
    verb,
    subject,
    target_type: targetType,
    target_id: targetId,
  });
}

const IngestSchema = z.object({
  source: z.string().min(1),
  type: z.enum(["memo", "observation", "activity"]),
  payload: z.record(z.unknown()),
});

// POST /api/ingest — unified ingest endpoint (API key or session auth)
export async function POST(req: NextRequest) {
  // Try API key first, fall back to session
  let userId: string | null = null;

  const apiAuth = await authenticateApiKey(req);
  if (apiAuth) {
    userId = apiAuth.userId;
  } else {
    const session = await auth();
    if (session?.user?.email) {
      userId = await resolveUserId(session.user.email);
    }
  }

  if (!userId) return unauthorized();

  const body: unknown = await req.json().catch(() => null);
  if (!body) return badRequest("Invalid JSON body");

  const parsed = IngestSchema.safeParse(body);
  if (!parsed.success) {
    return badRequest(parsed.error.issues[0]?.message ?? "Validation error");
  }

  const { source, type, payload } = parsed.data;

  if (type === "memo") {
    const memoBody = typeof payload.body === "string" ? payload.body : JSON.stringify(payload);
    const [memo] = await db
      .insert(memos)
      .values({
        user_id: userId,
        type: "text",
        body: memoBody,
        origin: "api",
        source_url: typeof payload.source_url === "string" ? payload.source_url : null,
        device: source,
      })
      .returning();

    if (memo) {
      await sendEvent({ name: "memo/created", data: { memo_id: memo.id } });
      await logActivity(userId, "ingest", source, "memo", memo.id);
    }

    return NextResponse.json(memo, { status: 201 });
  }

  if (type === "observation") {
    const title = typeof payload.title === "string" ? payload.title : `Observation from ${source}`;
    const bodyText = typeof payload.body === "string" ? payload.body : undefined;
    const [item] = await db
      .insert(inbox_items)
      .values({
        user_id: userId,
        kind: "orphan",
        title,
        body: bodyText,
        payload,
      })
      .returning();

    if (item) {
      await logActivity(userId, "ingest", source, "inbox_item", item.id);
    }

    return NextResponse.json(item, { status: 201 });
  }

  if (type === "activity") {
    const verb = typeof payload.verb === "string" ? payload.verb : "ingest";
    const subject = typeof payload.subject === "string" ? payload.subject : source;
    const [activity] = await db
      .insert(activities)
      .values({
        user_id: userId,
        verb,
        subject,
        target_type: typeof payload.target_type === "string" ? payload.target_type : undefined,
        target_id: typeof payload.target_id === "string" ? payload.target_id : undefined,
      })
      .returning();

    return NextResponse.json(activity, { status: 201 });
  }

  return badRequest("Unsupported type");
}
