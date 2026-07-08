// US-013: outbound webhooks — push wiki page lifecycle events to a user-configured
// endpoint so external agent workflows can react to create / update / 晋升-live.
//
// The event source is `change_log`: lifecycle sites that write a change_log row
// also call `dispatchPageWebhooks` with the same shape. Delivery is best-effort
// and fire-and-forget — it must NEVER break the compile / promote pipeline, so
// every path is wrapped and failures are only logged.
//
// Config lives in `ingest_sources` (source_type = 'webhook'). The encrypted
// config blob carries { url, secret }. Each delivered payload is signed with
// HMAC-SHA256 over the raw JSON body using the user's secret, so the receiver
// can verify authenticity (header `X-DayPage-Signature: sha256=<hex>`).

import { createHmac } from "crypto";
import { db } from "@/lib/db/client";
import { ingest_sources } from "@/lib/db/schema";
import { and, eq } from "drizzle-orm";
import { decryptConfig } from "@/lib/secret-crypto";
import { assertUrlAllowed, UrlNotAllowedError } from "@/lib/sandbox/browser";

export const WEBHOOK_SIGNATURE_HEADER = "X-DayPage-Signature";
export const WEBHOOK_EVENT_HEADER = "X-DayPage-Event";

/** One lifecycle event, mirroring the change_log row that produced it. */
export interface PageWebhookEvent {
  /** e.g. 'create_page' | 'update_page' | 'promote_page' */
  action_kind: string;
  target_type: string; // 'page' | 'page_link'
  target_id: string;
  before?: unknown;
  after?: unknown;
  reason?: string | null;
  performed_by?: string; // 'user' | 'agent'
}

interface WebhookTarget {
  id: string;
  url: string;
  secret: string;
}

/** Build the canonical hex HMAC-SHA256 signature for a raw JSON body. */
export function signWebhookBody(body: string, secret: string): string {
  return "sha256=" + createHmac("sha256", secret).update(body, "utf8").digest("hex");
}

/** Load enabled webhook targets for a user, decrypting url + secret. */
async function loadWebhookTargets(userId: string): Promise<WebhookTarget[]> {
  const rows = await db
    .select()
    .from(ingest_sources)
    .where(
      and(
        eq(ingest_sources.user_id, userId),
        eq(ingest_sources.source_type, "webhook"),
        eq(ingest_sources.enabled, true)
      )
    );

  const targets: WebhookTarget[] = [];
  for (const row of rows) {
    const cfg = decryptConfig(row.config);
    const url = typeof cfg.url === "string" ? cfg.url.trim() : "";
    const secret = typeof cfg.secret === "string" ? cfg.secret : "";
    if (!url) continue;
    targets.push({ id: row.id, url, secret });
  }
  return targets;
}

/** POST a single signed payload to one target. Best-effort. */
async function deliver(target: WebhookTarget, event: PageWebhookEvent): Promise<void> {
  // SSRF guard: the target URL is user-supplied. Reject non-http(s) schemes and
  // private / loopback / link-local hosts before fetching, so a webhook config
  // cannot be used to probe internal services (169.254.x, 10.x, localhost, …).
  try {
    assertUrlAllowed(target.url);
  } catch (err) {
    if (err instanceof UrlNotAllowedError) {
      console.warn(`[webhooks] target ${target.id} URL rejected by SSRF policy: ${err.message}`);
      return;
    }
    throw err;
  }

  const payload = {
    type: "page.changed",
    action: event.action_kind,
    target_type: event.target_type,
    target_id: event.target_id,
    before: event.before ?? null,
    after: event.after ?? null,
    reason: event.reason ?? null,
    performed_by: event.performed_by ?? "agent",
  };
  const body = JSON.stringify(payload);

  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    "User-Agent": "DayPage-Webhook/1",
    [WEBHOOK_EVENT_HEADER]: event.action_kind,
  };
  // Only sign when a secret is configured; an empty secret means "no verification".
  if (target.secret) {
    headers[WEBHOOK_SIGNATURE_HEADER] = signWebhookBody(body, target.secret);
  }

  // Bound delivery so a slow endpoint can't wedge the pipeline.
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 8000);
  try {
    const res = await fetch(target.url, {
      method: "POST",
      headers,
      body,
      signal: controller.signal,
    });
    if (!res.ok) {
      console.warn(
        `[webhooks] delivery to ${target.id} returned ${res.status} for ${event.action_kind}`
      );
    }
  } catch (err) {
    console.warn(`[webhooks] delivery to ${target.id} failed: ${String(err)}`);
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Dispatch lifecycle events to all of the user's enabled webhook targets.
 * Never throws — callers fire-and-forget after writing change_log.
 */
export async function dispatchPageWebhooks(
  userId: string,
  events: PageWebhookEvent[]
): Promise<void> {
  try {
    const list = events.filter(Boolean);
    if (list.length === 0) return;

    const targets = await loadWebhookTargets(userId);
    if (targets.length === 0) return;

    await Promise.allSettled(
      targets.flatMap((t) => list.map((e) => deliver(t, e)))
    );
  } catch (err) {
    console.warn(`[webhooks] dispatchPageWebhooks: non-fatal — ${String(err)}`);
  }
}
