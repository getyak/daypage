import "server-only";
import { NextResponse } from "next/server";
import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { users } from "@/lib/db/schema";
import { eq } from "drizzle-orm";
import { getTreeWithDiff } from "@/lib/trees/repo";

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

// GET /api/trees/:id — the tree, its nodes, and the past-7-day diff (newly
// added / changed nodes). User-scoped: a tree owned by another user is 404.
export async function GET(
  _req: Request,
  { params }: { params: Promise<{ id: string }> }
) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const { id } = await params;
  const detail = await getTreeWithDiff(userId, id);
  if (!detail) return notFound();

  return NextResponse.json(detail);
}
