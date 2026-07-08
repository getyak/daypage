import "server-only";
import { NextRequest, NextResponse } from "next/server";
import { auth, resolveUserId } from "@/lib/auth/session";
import { unauthorized, badRequest } from "@/lib/http";
import { z } from "zod";
import { createTree, listTrees } from "@/lib/trees/repo";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

const CreateTreeSchema = z.object({
  title: z.string().min(1).max(200),
});

// GET /api/trees — list the user's task trees (newest first)
export async function GET() {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const items = await listTrees(userId);
  return NextResponse.json({ items });
}

// POST /api/trees — create a new task tree
export async function POST(req: NextRequest) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const body: unknown = await req.json().catch(() => null);
  if (!body) return badRequest("Invalid JSON body");
  const parsed = CreateTreeSchema.safeParse(body);
  if (!parsed.success) {
    return badRequest(parsed.error.issues[0]?.message ?? "Validation error");
  }

  const tree = await createTree({ user_id: userId, title: parsed.data.title });
  return NextResponse.json(tree, { status: 201 });
}
