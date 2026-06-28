import "server-only";
import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/lib/auth/session";
import { db } from "@/lib/db/client";
import { users, agents, domains } from "@/lib/db/schema";
import { eq, and, desc } from "drizzle-orm";
import { z } from "zod";
import { DEFAULT_AGENT_MODEL, isValidAgentModel } from "@/lib/ai/agent-models";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

function unauthorized() {
  return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
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

const CreateAgentSchema = z.object({
  name: z.string().min(1).max(80),
  persona_prompt: z.string().min(1).max(8_000),
  model: z
    .string()
    .max(80)
    .optional()
    .refine((m) => m === undefined || isValidAgentModel(m), "Unknown model"),
  domain_id: z.string().uuid().nullable().optional(),
  top_k: z.number().int().min(1).max(20).optional(),
});

// GET /api/agents — list the user's agents (newest first)
export async function GET() {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const rows = await db
    .select()
    .from(agents)
    .where(eq(agents.user_id, userId))
    .orderBy(desc(agents.created_at));

  return NextResponse.json({ items: rows });
}

// POST /api/agents — create a new agent
export async function POST(req: NextRequest) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const body: unknown = await req.json().catch(() => null);
  if (!body) return badRequest("Invalid JSON body");
  const parsed = CreateAgentSchema.safeParse(body);
  if (!parsed.success) {
    return badRequest(parsed.error.issues[0]?.message ?? "Validation error");
  }
  const { name, persona_prompt, model, domain_id, top_k } = parsed.data;

  // If a domain scope is supplied, verify it belongs to this user.
  if (domain_id) {
    const [d] = await db
      .select({ id: domains.id })
      .from(domains)
      .where(and(eq(domains.id, domain_id), eq(domains.user_id, userId)))
      .limit(1);
    if (!d) return badRequest("Unknown domain");
  }

  const [agent] = await db
    .insert(agents)
    .values({
      user_id: userId,
      name: name.trim(),
      persona_prompt: persona_prompt.trim(),
      model: model ?? DEFAULT_AGENT_MODEL,
      domain_id: domain_id ?? null,
      top_k: top_k ?? 8,
    })
    .returning();

  return NextResponse.json(agent, { status: 201 });
}
