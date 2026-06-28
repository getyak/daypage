import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/lib/auth/session";
import { db } from "@/lib/db/client";
import { users, domains } from "@/lib/db/schema";
import { eq, and } from "drizzle-orm";
import { z } from "zod";

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

const CreateDomainSchema = z.object({
  slug: z.string().min(1).max(100),
  label: z.string().min(1).max(200),
  color: z.string().optional(),
  position: z.number().int().optional(),
});

// GET /api/domains — list user's domains ordered by position
export async function GET() {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const rows = await db
    .select()
    .from(domains)
    .where(eq(domains.user_id, userId))
    .orderBy(domains.position, domains.created_at);

  return NextResponse.json({ items: rows });
}

// POST /api/domains — create domain
export async function POST(req: NextRequest) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const body: unknown = await req.json().catch(() => null);
  if (!body) return badRequest("Invalid JSON body");

  const parsed = CreateDomainSchema.safeParse(body);
  if (!parsed.success) {
    return badRequest(parsed.error.issues[0]?.message ?? "Validation error");
  }

  const input = parsed.data;

  const [domain] = await db
    .insert(domains)
    .values({
      user_id: userId,
      slug: input.slug,
      label: input.label,
      color: input.color ?? null,
      position: input.position ?? 0,
    })
    .returning();

  return NextResponse.json(domain, { status: 201 });
}
