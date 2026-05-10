import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { users, inbox_items, domains, pages } from "@/lib/db/schema";
import { eq, and } from "drizzle-orm";
import { z } from "zod";

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

const ResolveSchema = z.object({
  action: z.string().min(1),
  payload: z.record(z.unknown()).optional(),
});

type RouteContext = { params: Promise<{ id: string }> };

// POST /api/inbox/:id/resolve
// Marks item resolved and optionally executes an action side-effect.
// Supported actions: keep_both, use_new, keep_mine, cold_archive, keep,
//   create_domain, not_yet, view_changes, dismiss (generic)
export async function POST(req: NextRequest, ctx: RouteContext) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const { id } = await ctx.params;

  const body: unknown = await req.json().catch(() => null);
  if (!body) return badRequest("Invalid JSON body");

  const parsed = ResolveSchema.safeParse(body);
  if (!parsed.success) {
    return badRequest(parsed.error.issues[0]?.message ?? "Validation error");
  }

  const { action, payload } = parsed.data;

  // Load item scoped to user
  const [item] = await db
    .select()
    .from(inbox_items)
    .where(and(eq(inbox_items.id, id), eq(inbox_items.user_id, userId)))
    .limit(1);

  if (!item) return notFound();

  // Execute action side-effects before marking resolved
  if (action === "create_domain" && item.kind === "schema") {
    const schemaPayload = (item.payload ?? {}) as {
      suggested_name?: string;
      suggested_color?: string;
    };
    const name = schemaPayload.suggested_name ?? "New Domain";
    const slug = name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
    await db
      .insert(domains)
      .values({
        user_id: userId,
        slug,
        label: name,
        color: schemaPayload.suggested_color ?? null,
        position: 0,
      })
      .onConflictDoNothing();
  }

  if (action === "cold_archive" && item.kind === "orphan") {
    const orphanPayload = (item.payload ?? {}) as { page_id?: string };
    if (orphanPayload.page_id) {
      await db
        .update(pages)
        .set({ status: "archived" })
        .where(and(eq(pages.id, orphanPayload.page_id), eq(pages.user_id, userId)));
    }
  }

  // Mark resolved
  const [updated] = await db
    .update(inbox_items)
    .set({
      status: "resolved",
      resolution: { action, payload: payload ?? null },
      resolved_at: new Date(),
    })
    .where(and(eq(inbox_items.id, id), eq(inbox_items.user_id, userId)))
    .returning();

  if (!updated) return notFound();
  return NextResponse.json(updated);
}
