import "server-only";
import { NextResponse } from "next/server";
import { auth } from "@/lib/auth/session";
import { db } from "@/lib/db/client";
import { users, task_suggestions } from "@/lib/db/schema";
import { eq, and, desc } from "drizzle-orm";
import { classifyGate } from "@/lib/gateway/policy";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

function unauthorized() {
  return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
}

async function resolveUserId(email: string): Promise<string | null> {
  const rows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, email))
    .limit(1);
  return rows[0]?.id ?? null;
}

// GET /api/suggestions — list the current user's open task_suggestions for the
// agents workbench. Each row carries a predicted `gate` (computed the same way
// the work-order builder will, via classifyGate on the title) so the UI knows
// which selections need a second confirmation before dispatch (approve-first).
export async function GET() {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const rows = await db
    .select()
    .from(task_suggestions)
    .where(
      and(
        eq(task_suggestions.user_id, userId),
        eq(task_suggestions.status, "open")
      )
    )
    .orderBy(desc(task_suggestions.created_at));

  const items = rows.map((s) => ({
    id: s.id,
    title: s.title,
    rationale: s.rationale,
    estimate: s.estimate,
    suggested_target: s.suggested_target,
    gate: classifyGate(s.title),
    created_at: s.created_at.toISOString(),
  }));

  return NextResponse.json({ items });
}
