import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { users, ingest_sources } from "@/lib/db/schema";
import { eq, and } from "drizzle-orm";
import { z } from "zod";

function unauthorized() {
  return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
}

function badRequest(message: string) {
  return NextResponse.json({ error: message }, { status: 400 });
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

const UpdateIngestSourceSchema = z.object({
  name: z.string().min(1).max(100).optional(),
  source_type: z.enum(["telegram", "email", "rss", "webhook", "api_claude"]).optional(),
  config: z.record(z.unknown()).optional(),
  enabled: z.boolean().optional(),
});

// GET /api/ingest-sources/[id]
export async function GET(
  _req: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const { id } = await params;
  const rows = await db
    .select()
    .from(ingest_sources)
    .where(and(eq(ingest_sources.id, id), eq(ingest_sources.user_id, userId)))
    .limit(1);

  if (!rows[0]) return notFound();
  return NextResponse.json(rows[0]);
}

// PATCH /api/ingest-sources/[id]
export async function PATCH(
  req: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const { id } = await params;

  const body: unknown = await req.json().catch(() => null);
  if (!body) return badRequest("Invalid JSON body");

  const parsed = UpdateIngestSourceSchema.safeParse(body);
  if (!parsed.success) {
    return badRequest(parsed.error.issues[0]?.message ?? "Validation error");
  }

  const updates = parsed.data;
  if (Object.keys(updates).length === 0) {
    return badRequest("No fields to update");
  }

  const rows = await db
    .update(ingest_sources)
    .set(updates)
    .where(and(eq(ingest_sources.id, id), eq(ingest_sources.user_id, userId)))
    .returning();

  if (!rows[0]) return notFound();
  return NextResponse.json(rows[0]);
}

// DELETE /api/ingest-sources/[id]
export async function DELETE(
  _req: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const { id } = await params;

  const rows = await db
    .delete(ingest_sources)
    .where(and(eq(ingest_sources.id, id), eq(ingest_sources.user_id, userId)))
    .returning({ id: ingest_sources.id });

  if (!rows[0]) return notFound();
  return new NextResponse(null, { status: 204 });
}
