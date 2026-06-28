import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/lib/auth/session";
import { db } from "@/lib/db/client";
import { annotations, pages, users } from "@/lib/db/schema";
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

const AnchorSchema = z.object({
  section_idx: z.number().int().min(0),
  char_start: z.number().int().min(0),
  char_end: z.number().int().min(0),
  text: z.string().min(1).max(2000),
});

const CreateAnnotationSchema = z.object({
  page_id: z.string().uuid(),
  anchor: AnchorSchema,
  tag: z.string().min(1).max(50),
  note: z.string().max(2000).optional(),
});

// POST /api/annotations
export async function POST(req: NextRequest) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const body: unknown = await req.json().catch(() => null);
  if (!body) return badRequest("Invalid JSON body");

  const parsed = CreateAnnotationSchema.safeParse(body);
  if (!parsed.success) {
    return badRequest(parsed.error.issues[0]?.message ?? "Validation error");
  }

  const { page_id, anchor, tag, note } = parsed.data;

  // Verify page belongs to user
  const pageRows = await db
    .select({ id: pages.id })
    .from(pages)
    .where(and(eq(pages.id, page_id), eq(pages.user_id, userId)))
    .limit(1);

  if (!pageRows.length) {
    return NextResponse.json({ error: "Page not found" }, { status: 404 });
  }

  const [annotation] = await db
    .insert(annotations)
    .values({
      user_id: userId,
      page_id,
      anchor,
      tag,
      note: note ?? null,
    })
    .returning();

  return NextResponse.json(annotation, { status: 201 });
}
