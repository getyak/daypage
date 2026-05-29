import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { pages, users, change_log } from "@/lib/db/schema";
import { eq, and } from "drizzle-orm";
import { z } from "zod";
import { dispatchPageWebhooks, type PageWebhookEvent } from "@/lib/webhooks/dispatch";

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

type RouteContext = { params: Promise<{ slug: string }> };

const PatchPageSchema = z.object({
  title: z.string().min(1).max(500).optional(),
  domain_id: z.string().uuid().nullable().optional(),
  status: z.enum(["draft", "live", "archived"]).optional(),
  body_md: z.string().optional(),
});

// GET /api/pages/:slug — single page (404 if not user's)
export async function GET(_req: NextRequest, ctx: RouteContext) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const { slug } = await ctx.params;

  const rows = await db
    .select()
    .from(pages)
    .where(and(eq(pages.slug, slug), eq(pages.user_id, userId)))
    .limit(1);

  if (!rows.length) return notFound();
  return NextResponse.json({ page: rows[0] });
}

// PATCH /api/pages/:slug — update title / domain_id / status
export async function PATCH(req: NextRequest, ctx: RouteContext) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const { slug } = await ctx.params;

  const body: unknown = await req.json().catch(() => null);
  if (!body) return badRequest("Invalid JSON body");

  const parsed = PatchPageSchema.safeParse(body);
  if (!parsed.success) {
    return badRequest(parsed.error.issues[0]?.message ?? "Validation error");
  }

  const input = parsed.data;
  const updateData: Record<string, unknown> = {};

  if (input.title !== undefined) updateData.title = input.title;
  if (input.domain_id !== undefined) updateData.domain_id = input.domain_id;
  if (input.status !== undefined) updateData.status = input.status;
  if (input.body_md !== undefined) updateData.body_md = input.body_md;

  if (Object.keys(updateData).length === 0) {
    return badRequest("No fields to update");
  }

  // Capture the prior status so we can detect a draft → live 晋升.
  const [prev] = await db
    .select({ id: pages.id, status: pages.status, title: pages.title })
    .from(pages)
    .where(and(eq(pages.slug, slug), eq(pages.user_id, userId)))
    .limit(1);

  const rows = await db
    .update(pages)
    .set(updateData)
    .where(and(eq(pages.slug, slug), eq(pages.user_id, userId)))
    .returning();

  if (!rows.length) return notFound();
  const updated = rows[0];

  // US-013: record the user edit in change_log and push it to webhook targets.
  // A draft → live transition is reported as `promote_page`; everything else
  // as `update_page`. Best-effort — never block the response.
  const promotedToLive = prev?.status === "draft" && updated.status === "live";
  const actionKind = promotedToLive ? "promote_page" : "update_page";
  const after: Record<string, unknown> = { title: updated.title, status: updated.status };

  try {
    await db.insert(change_log).values({
      user_id: userId,
      action_kind: "update_page",
      target_type: "page",
      target_id: updated.id,
      before: prev ? { status: prev.status, title: prev.title } : null,
      after,
      reason: promotedToLive ? "Promoted to live by user." : "Edited by user.",
      performed_by: "user",
      agent_action_id: null,
    });
  } catch (err) {
    console.warn(`[pages] change_log insert: non-fatal — ${String(err)}`);
  }

  const event: PageWebhookEvent = {
    action_kind: actionKind,
    target_type: "page",
    target_id: updated.id,
    before: prev ? { status: prev.status, title: prev.title } : null,
    after,
    reason: promotedToLive ? "Promoted to live by user." : "Edited by user.",
    performed_by: "user",
  };
  await dispatchPageWebhooks(userId, [event]);

  return NextResponse.json({ page: updated });
}

// DELETE /api/pages/:slug — soft-delete by setting status='archived'
export async function DELETE(_req: NextRequest, ctx: RouteContext) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const { slug } = await ctx.params;

  const rows = await db
    .update(pages)
    .set({ status: "archived" })
    .where(and(eq(pages.slug, slug), eq(pages.user_id, userId)))
    .returning({ id: pages.id });

  if (!rows.length) return notFound();
  return new NextResponse(null, { status: 204 });
}
