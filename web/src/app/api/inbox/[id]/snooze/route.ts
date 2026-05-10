import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { users, inbox_items } from "@/lib/db/schema";
import { eq, and } from "drizzle-orm";
import { z } from "zod";

function unauthorized() {
  return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
}

function notFound() {
  return NextResponse.json({ error: "Not found" }, { status: 404 });
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

const SnoozeSchema = z.object({
  until: z.string().datetime({ message: "until must be an ISO 8601 datetime" }),
});

type RouteContext = { params: Promise<{ id: string }> };

// POST /api/inbox/:id/snooze — snooze item until a given timestamp
// Snoozed items reappear in queries when current time > snooze_until
export async function POST(req: NextRequest, ctx: RouteContext) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const { id } = await ctx.params;

  const body: unknown = await req.json().catch(() => null);
  if (!body) return badRequest("Invalid JSON body");

  const parsed = SnoozeSchema.safeParse(body);
  if (!parsed.success) {
    return badRequest(parsed.error.issues[0]?.message ?? "Validation error");
  }

  const snoozeUntil = new Date(parsed.data.until);
  if (snoozeUntil <= new Date()) {
    return badRequest("snooze until must be in the future");
  }

  const [updated] = await db
    .update(inbox_items)
    .set({ status: "snoozed", snooze_until: snoozeUntil })
    .where(and(eq(inbox_items.id, id), eq(inbox_items.user_id, userId)))
    .returning();

  if (!updated) return notFound();
  return NextResponse.json(updated);
}
