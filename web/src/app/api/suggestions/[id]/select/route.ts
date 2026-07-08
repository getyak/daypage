import "server-only";
import { NextResponse } from "next/server";
import { auth } from "@/lib/auth/session";
import { db } from "@/lib/db/client";
import { users } from "@/lib/db/schema";
import { eq } from "drizzle-orm";
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

  // selectSuggestion scopes to userId, so a suggestion owned by someone else
  // (or a nonexistent id) comes back as not_found — no separate ownership
  // pre-check needed.
  const result = await selectSuggestion(id, userId);
  if (result.status === "not_found") return notFound();

  return NextResponse.json({ status: result.status, suggestion: result.suggestion });
}
