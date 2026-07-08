import { NextRequest, NextResponse } from "next/server";
import { auth, resolveUserId } from "@/lib/auth/session";
import { unauthorized, notFound, badRequest } from "@/lib/http";
import { db } from "@/lib/db/client";
import { domains } from "@/lib/db/schema";
import { eq, and } from "drizzle-orm";
import { z } from "zod";

const PatchDomainSchema = z.object({
  label: z.string().min(1).max(200).optional(),
  color: z.string().nullable().optional(),
  position: z.number().int().optional(),
});

// PATCH /api/domains/:id — rename + color change
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

  const parsed = PatchDomainSchema.safeParse(body);
  if (!parsed.success) {
    return badRequest(parsed.error.issues[0]?.message ?? "Validation error");
  }

  const input = parsed.data;
  if (Object.keys(input).length === 0) return badRequest("No fields to update");

  const updates: Partial<{ label: string; color: string | null; position: number }> = {};
  if (input.label !== undefined) updates.label = input.label;
  if (input.color !== undefined) updates.color = input.color;
  if (input.position !== undefined) updates.position = input.position;

  const [updated] = await db
    .update(domains)
    .set(updates)
    .where(and(eq(domains.id, id), eq(domains.user_id, userId)))
    .returning();

  if (!updated) return notFound();

  return NextResponse.json(updated);
}

// DELETE /api/domains/:id — remove domain
export async function DELETE(
  _req: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const { id } = await params;

  const [deleted] = await db
    .delete(domains)
    .where(and(eq(domains.id, id), eq(domains.user_id, userId)))
    .returning();

  if (!deleted) return notFound();

  return new NextResponse(null, { status: 204 });
}
