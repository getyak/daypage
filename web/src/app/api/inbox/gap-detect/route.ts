import { NextResponse } from "next/server";
import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { users } from "@/lib/db/schema";
import { eq } from "drizzle-orm";
import { detectGapsForUser } from "@/lib/inngest/functions/gap-detect";

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

// POST /api/inbox/gap-detect
// On-demand structural-gap sweep for the signed-in user (US-041). The same
// analysis also runs nightly via the gap-detect inngest cron; this lets a user
// (or a verification harness) trigger it immediately and surface bridging
// questions in their inbox.
export async function POST() {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const result = await detectGapsForUser(userId);
  return NextResponse.json(result);
}
