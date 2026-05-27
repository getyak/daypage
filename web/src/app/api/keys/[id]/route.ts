import { NextRequest, NextResponse } from "next/server";
import { and, eq } from "drizzle-orm";
import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { api_keys, users } from "@/lib/db/schema";

function unauthorized() {
  return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
}

// DELETE /api/keys/[id] — delete key (verify ownership)
export async function DELETE(
  _req: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userRows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, session.user.email))
    .limit(1);

  if (!userRows.length) return unauthorized();
  const userId = userRows[0].id;

  const { id } = await params;

  const deleted = await db
    .delete(api_keys)
    .where(and(eq(api_keys.id, id), eq(api_keys.user_id, userId)))
    .returning({ id: api_keys.id });

  if (!deleted.length) {
    return NextResponse.json({ error: "Not found" }, { status: 404 });
  }

  return new NextResponse(null, { status: 204 });
}
