import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { users, ingest_sources } from "@/lib/db/schema";
import { eq, and, desc } from "drizzle-orm";
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

const CreateIngestSourceSchema = z.object({
  name: z.string().min(1).max(100),
  source_type: z.enum(["telegram", "email", "rss", "webhook", "api_claude"]),
  config: z.record(z.unknown()).optional().default({}),
  enabled: z.boolean().optional().default(true),
});

// GET /api/ingest-sources — list all sources for the current user
export async function GET(_req: NextRequest) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const rows = await db
    .select()
    .from(ingest_sources)
    .where(eq(ingest_sources.user_id, userId))
    .orderBy(desc(ingest_sources.created_at));

  return NextResponse.json(rows);
}

// POST /api/ingest-sources — create a new ingest source
export async function POST(req: NextRequest) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const body: unknown = await req.json().catch(() => null);
  if (!body) return badRequest("Invalid JSON body");

  const parsed = CreateIngestSourceSchema.safeParse(body);
  if (!parsed.success) {
    return badRequest(parsed.error.issues[0]?.message ?? "Validation error");
  }

  const input = parsed.data;
  const [source] = await db
    .insert(ingest_sources)
    .values({
      user_id: userId,
      name: input.name,
      source_type: input.source_type,
      config: input.config,
      enabled: input.enabled,
    })
    .returning();

  return NextResponse.json(source, { status: 201 });
}
