import "server-only";
import { NextResponse } from "next/server";
import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { users, task_suggestions } from "@/lib/db/schema";
import { eq, and } from "drizzle-orm";
import { selectSuggestion } from "@/lib/gateway/select-suggestion";

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

// POST /api/suggestions/:id/select — the user picked a suggestion in the web
// workbench. Verify ownership, then reuse the shared selectSuggestion flow
// (open → selected + enqueue the dispatch job). Idempotent: a re-tap on an
// already-acted suggestion returns its current state without double-dispatching.
export async function POST(_req: Request, ctx: RouteContext) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const { id } = await ctx.params;

  // Ownership guard: selectSuggestion does not scope by user (it serves the
  // Telegram webhook), so confirm the row belongs to this user before acting.
  const owned = await db
    .select({ id: task_suggestions.id })
    .from(task_suggestions)
    .where(and(eq(task_suggestions.id, id), eq(task_suggestions.user_id, userId)))
    .limit(1);
  if (!owned[0]) return notFound();

  const result = await selectSuggestion(id);
  if (result.status === "not_found") return notFound();

  return NextResponse.json({ status: result.status, suggestion: result.suggestion });
}
