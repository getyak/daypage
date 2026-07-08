import "server-only";
import { NextResponse } from "next/server";
import { auth, resolveUserId } from "@/lib/auth/session";
import { unauthorized, notFound } from "@/lib/http";
import { getTreeWithDiff } from "@/lib/trees/repo";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

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
