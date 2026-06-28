import "server-only";
import { NextResponse } from "next/server";
import { auth } from "@/lib/auth/session";
import { db } from "@/lib/db/client";
import { users, task_suggestions } from "@/lib/db/schema";
import { eq, and } from "drizzle-orm";
import { dismissSuggestion } from "@/lib/gateway/select-suggestion";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

function unauthorized() {
  return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
}

function notFound() {
  return NextResponse.json({ error: "Not found" }, { status: 404 });
}

async function resolveUserId(email: string): Promise<string | null> {
  const rows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, email))
    .limit(1);
  return rows[0]?.id ?? null;
}

type RouteContext = { params: Promise<{ id: string }> };

// POST /api/suggestions/:id/dismiss — the user declined a suggestion. Verify
// ownership, then flip open → dismissed (no dispatch is enqueued). Idempotent.
export async function POST(_req: Request, ctx: RouteContext) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const { id } = await ctx.params;

  const owned = await db
    .select({ id: task_suggestions.id })
    .from(task_suggestions)
    .where(and(eq(task_suggestions.id, id), eq(task_suggestions.user_id, userId)))
    .limit(1);
  if (!owned[0]) return notFound();

  const result = await dismissSuggestion(id);
  if (result.status === "not_found") return notFound();

  return NextResponse.json({ status: result.status, suggestion: result.suggestion });
}
