import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/lib/auth/session";
import { db } from "@/lib/db/client";
import { users, activities } from "@/lib/db/schema";
import { eq, and, lt, desc } from "drizzle-orm";
import { z } from "zod";

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

const ListActivitiesQuerySchema = z.object({
  cursor: z.string().optional(),
  limit: z.coerce.number().int().min(1).max(100).optional().default(20),
});

// GET /api/activities — cursor-paginated activity list, default 20
export async function GET(req: NextRequest) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const params = Object.fromEntries(req.nextUrl.searchParams.entries());
  const parsed = ListActivitiesQuerySchema.safeParse(params);
  if (!parsed.success) {
    return badRequest(parsed.error.issues[0]?.message ?? "Invalid query");
  }

  const { cursor, limit } = parsed.data;

  const conditions = [eq(activities.user_id, userId)];

  if (cursor) {
    conditions.push(lt(activities.created_at, new Date(cursor)));
  }

  const rows = await db
    .select()
    .from(activities)
    .where(and(...conditions))
    .orderBy(desc(activities.created_at))
    .limit(limit + 1);

  const hasMore = rows.length > limit;
  const items = hasMore ? rows.slice(0, limit) : rows;
  const nextCursor =
    hasMore ? items[items.length - 1].created_at.toISOString() : null;

  return NextResponse.json({ items, next_cursor: nextCursor, has_more: hasMore });
}
