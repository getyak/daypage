import { NextRequest, NextResponse } from "next/server";
import { auth, resolveUserId } from "@/lib/auth/session";
import { unauthorized, badRequest } from "@/lib/http";
import { db } from "@/lib/db/client";
import { inbox_items } from "@/lib/db/schema";
import { eq, and, desc, lt } from "drizzle-orm";
import { z } from "zod";

const ListInboxQuerySchema = z.object({
  kind: z
    .enum(["contradiction", "schema", "orphan", "compiled", "gap"])
    .optional(),
  status: z
    .enum(["open", "resolved", "dismissed", "snoozed"])
    .optional()
    .default("open"),
  cursor: z.string().optional(),
  limit: z.coerce.number().int().min(1).max(100).optional().default(20),
});

// GET /api/inbox — list inbox items with optional kind/status filter + cursor pagination
export async function GET(req: NextRequest) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const params = Object.fromEntries(req.nextUrl.searchParams.entries());
  const parsed = ListInboxQuerySchema.safeParse(params);
  if (!parsed.success) {
    return badRequest(parsed.error.issues[0]?.message ?? "Invalid query");
  }

  const { kind, status, cursor, limit } = parsed.data;

  const conditions = [
    eq(inbox_items.user_id, userId),
    eq(inbox_items.status, status),
  ];

  if (kind) {
    conditions.push(eq(inbox_items.kind, kind));
  }

  if (cursor) {
    conditions.push(lt(inbox_items.created_at, new Date(cursor)));
  }

  const rows = await db
    .select()
    .from(inbox_items)
    .where(and(...conditions))
    .orderBy(desc(inbox_items.created_at))
    .limit(limit + 1);

  const hasMore = rows.length > limit;
  const items = hasMore ? rows.slice(0, limit) : rows;
  const nextCursor =
    hasMore ? items[items.length - 1].created_at.toISOString() : null;

  return NextResponse.json({ items, next_cursor: nextCursor, has_more: hasMore });
}
