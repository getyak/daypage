// US-013: webhook config CRUD. Stores the outbound-webhook URL + signing secret
// as a `webhook` row in `ingest_sources` with the config blob encrypted via
// secret-crypto. The URL is non-secret and returned to the client for display;
// the secret is never echoed back (only a `has_secret` flag).

import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/lib/auth/session";
import { db } from "@/lib/db/client";
import { users, ingest_sources } from "@/lib/db/schema";
import { and, eq } from "drizzle-orm";
import { z } from "zod";
import { encryptConfig, decryptConfig } from "@/lib/secret-crypto";

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

const WEBHOOK_NAME = "Webhook";

const WebhookSchema = z.object({
  url: z.string().url().max(2048),
  // Optional on update: omitting it keeps the existing secret.
  secret: z.string().max(256).optional(),
  enabled: z.boolean().optional().default(true),
});

interface WebhookView {
  configured: boolean;
  id?: string;
  url?: string;
  has_secret?: boolean;
  enabled?: boolean;
}

async function loadWebhookRow(userId: string) {
  const rows = await db
    .select()
    .from(ingest_sources)
    .where(
      and(
        eq(ingest_sources.user_id, userId),
        eq(ingest_sources.source_type, "webhook")
      )
    )
    .limit(1);
  return rows[0] ?? null;
}

// GET /api/webhooks — current webhook config (secret never returned)
export async function GET() {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();
  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const row = await loadWebhookRow(userId);
  if (!row) {
    return NextResponse.json({ configured: false } satisfies WebhookView);
  }

  const cfg = decryptConfig(row.config);
  const view: WebhookView = {
    configured: true,
    id: row.id,
    url: typeof cfg.url === "string" ? cfg.url : "",
    has_secret: typeof cfg.secret === "string" && cfg.secret.length > 0,
    enabled: row.enabled,
  };
  return NextResponse.json(view);
}

// PUT /api/webhooks — create or replace the webhook config
export async function PUT(req: NextRequest) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();
  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const body: unknown = await req.json().catch(() => null);
  if (!body) return badRequest("Invalid JSON body");

  const parsed = WebhookSchema.safeParse(body);
  if (!parsed.success) {
    return badRequest(parsed.error.issues[0]?.message ?? "Validation error");
  }
  const input = parsed.data;

  const existing = await loadWebhookRow(userId);

  // Preserve the prior secret when the caller didn't supply a new one.
  let secret = input.secret ?? "";
  if (input.secret === undefined && existing) {
    const prevCfg = decryptConfig(existing.config);
    secret = typeof prevCfg.secret === "string" ? prevCfg.secret : "";
  }

  const config = encryptConfig({ url: input.url, secret });

  if (existing) {
    const [updated] = await db
      .update(ingest_sources)
      .set({ config, enabled: input.enabled, name: WEBHOOK_NAME })
      .where(
        and(eq(ingest_sources.id, existing.id), eq(ingest_sources.user_id, userId))
      )
      .returning();
    return NextResponse.json({
      configured: true,
      id: updated.id,
      url: input.url,
      has_secret: secret.length > 0,
      enabled: updated.enabled,
    } satisfies WebhookView);
  }

  const [created] = await db
    .insert(ingest_sources)
    .values({
      user_id: userId,
      name: WEBHOOK_NAME,
      source_type: "webhook",
      config,
      enabled: input.enabled,
    })
    .returning();

  return NextResponse.json(
    {
      configured: true,
      id: created.id,
      url: input.url,
      has_secret: secret.length > 0,
      enabled: created.enabled,
    } satisfies WebhookView,
    { status: 201 }
  );
}

// DELETE /api/webhooks — remove the webhook config
export async function DELETE() {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();
  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  await db
    .delete(ingest_sources)
    .where(
      and(
        eq(ingest_sources.user_id, userId),
        eq(ingest_sources.source_type, "webhook")
      )
    );

  return new NextResponse(null, { status: 204 });
}
