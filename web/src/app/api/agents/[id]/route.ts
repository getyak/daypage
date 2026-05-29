import "server-only";
import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { users, agents, domains } from "@/lib/db/schema";
import { eq, and } from "drizzle-orm";
import { z } from "zod";
import { isValidAgentModel } from "@/lib/ai/agent-models";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

function unauthorized() {
  return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
}
function notFound() {
  return NextResponse.json({ error: "Not found" }, { status: 404 });
}
function badRequest(message: string) {
  return NextResponse.json({ error: message }, { status: 400 });
}

async function resolveUserId(email: string): Promise<string | null> {
  const rows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, email))
    .limit(1);
  return rows[0]?.id ?? null;
}

const UpdateAgentSchema = z.object({
  name: z.string().min(1).max(80).optional(),
  persona_prompt: z.string().min(1).max(8_000).optional(),
  model: z
    .string()
    .max(80)
    .optional()
    .refine((m) => m === undefined || isValidAgentModel(m), "Unknown model"),
  domain_id: z.string().uuid().nullable().optional(),
  top_k: z.number().int().min(1).max(20).optional(),
});

// GET /api/agents/:id
export async function GET(
  _req: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();
  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const { id } = await params;
  const [agent] = await db
    .select()
    .from(agents)
    .where(and(eq(agents.id, id), eq(agents.user_id, userId)))
    .limit(1);
  if (!agent) return notFound();
  return NextResponse.json(agent);
}

// PATCH /api/agents/:id
export async function PATCH(
  req: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();
  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const { id } = await params;
  const [existing] = await db
    .select({ id: agents.id })
    .from(agents)
    .where(and(eq(agents.id, id), eq(agents.user_id, userId)))
    .limit(1);
  if (!existing) return notFound();

  const body: unknown = await req.json().catch(() => null);
  if (!body) return badRequest("Invalid JSON body");
  const parsed = UpdateAgentSchema.safeParse(body);
  if (!parsed.success) {
    return badRequest(parsed.error.issues[0]?.message ?? "Validation error");
  }
  const patch = parsed.data;

  if (patch.domain_id) {
    const [d] = await db
      .select({ id: domains.id })
      .from(domains)
      .where(and(eq(domains.id, patch.domain_id), eq(domains.user_id, userId)))
      .limit(1);
    if (!d) return badRequest("Unknown domain");
  }

  const updates: Record<string, unknown> = {};
  if (patch.name !== undefined) updates.name = patch.name.trim();
  if (patch.persona_prompt !== undefined)
    updates.persona_prompt = patch.persona_prompt.trim();
  if (patch.model !== undefined) updates.model = patch.model;
  if (patch.domain_id !== undefined) updates.domain_id = patch.domain_id;
  if (patch.top_k !== undefined) updates.top_k = patch.top_k;

  if (Object.keys(updates).length === 0) return badRequest("No fields to update");

  const [updated] = await db
    .update(agents)
    .set(updates)
    .where(and(eq(agents.id, id), eq(agents.user_id, userId)))
    .returning();

  return NextResponse.json(updated);
}

// DELETE /api/agents/:id
export async function DELETE(
  _req: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();
  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const { id } = await params;
  const deleted = await db
    .delete(agents)
    .where(and(eq(agents.id, id), eq(agents.user_id, userId)))
    .returning({ id: agents.id });

  if (deleted.length === 0) return notFound();
  return new NextResponse(null, { status: 204 });
}
