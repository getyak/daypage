import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { users, memos, inbox_items, activities } from "@/lib/db/schema";
import { eq } from "drizzle-orm";
import { z } from "zod";
import { authenticateApiKey, hasScope } from "@/lib/api-auth";
import { sendEvent } from "@/lib/inngest/client";

// CORS — the browser-clip bookmarklet (US-021) runs on arbitrary origins and
// POSTs here with a Bearer header, which triggers a preflight. Reflect the
// caller's origin so the cross-origin fetch succeeds. Auth is enforced via the
// API key (not the origin), so a permissive CORS policy is safe here.
function corsHeaders(req: NextRequest): Record<string, string> {
  const origin = req.headers.get("Origin") ?? "*";
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Authorization, Content-Type",
    "Access-Control-Max-Age": "86400",
    Vary: "Origin",
  };
}

function withCors(req: NextRequest, res: NextResponse): NextResponse {
  for (const [k, v] of Object.entries(corsHeaders(req))) res.headers.set(k, v);
  return res;
}

// OPTIONS /api/ingest — CORS preflight for the clip bookmarklet.
export function OPTIONS(req: NextRequest) {
  return new NextResponse(null, { status: 204, headers: corsHeaders(req) });
}

function unauthorized(req: NextRequest) {
  return withCors(req, NextResponse.json({ error: "Unauthorized" }, { status: 401 }));
}

function forbidden(req: NextRequest, message: string) {
  return withCors(req, NextResponse.json({ error: message }, { status: 403 }));
}

function badRequest(req: NextRequest, message: string) {
  return withCors(req, NextResponse.json({ error: message }, { status: 400 }));
}

// z.string().url() accepts javascript:/data: URIs, which become stored XSS when
// rendered as <a href>. Only allow http(s) for user-supplied source URLs.
function sanitizeSourceUrl(value: unknown): string | null {
  if (typeof value !== "string") return null;
  try {
    const u = new URL(value);
    return u.protocol === "http:" || u.protocol === "https:" ? value : null;
  } catch {
    return null;
  }
}

async function resolveUserId(email: string): Promise<string | null> {
  const rows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, email))
    .limit(1);
  return rows[0]?.id ?? null;
}

async function logActivity(
  userId: string,
  verb: string,
  subject: string,
  targetType: string,
  targetId: string
) {
  await db.insert(activities).values({
    user_id: userId,
    verb,
    subject,
    target_type: targetType,
    target_id: targetId,
  });
}

const IngestSchema = z.object({
  source: z.string().min(1),
  type: z.enum(["memo", "observation", "activity"]),
  payload: z.record(z.string(), z.unknown()),
});

// US-021: build a memo body from a browser clip. A clip carries a page title,
// the source URL, and optionally a selected text snippet (when only part of the
// page is clipped). If an explicit `body` is given it wins. Otherwise we
// assemble a readable Markdown memo: title heading + selection + source link.
function buildMemoBody(payload: Record<string, unknown>): string {
  if (typeof payload.body === "string" && payload.body.trim()) {
    return payload.body;
  }

  const title = typeof payload.title === "string" ? payload.title.trim() : "";
  const selection =
    typeof payload.selection === "string" ? payload.selection.trim() : "";
  const url = sanitizeSourceUrl(payload.source_url);

  const parts: string[] = [];
  if (title) parts.push(`# ${title}`);
  if (selection) parts.push(`> ${selection.split("\n").join("\n> ")}`);
  if (url) parts.push(`[${title || url}](${url})`);

  const assembled = parts.join("\n\n").trim();
  // Never persist an empty memo — fall back to the raw payload as a last resort.
  return assembled || JSON.stringify(payload);
}

// POST /api/ingest — unified ingest endpoint (API key or session auth)
export async function POST(req: NextRequest) {
  // Try API key first, fall back to session
  let userId: string | null = null;

  const apiAuth = await authenticateApiKey(req);
  if (apiAuth) {
    // /api/ingest only performs writes — require the "write" scope.
    if (!hasScope(apiAuth, "write")) {
      return forbidden(req, "API key lacks 'write' scope");
    }
    userId = apiAuth.userId;
  } else {
    const session = await auth();
    if (session?.user?.email) {
      userId = await resolveUserId(session.user.email);
    }
  }

  if (!userId) return unauthorized(req);

  const body: unknown = await req.json().catch(() => null);
  if (!body) return badRequest(req, "Invalid JSON body");

  const parsed = IngestSchema.safeParse(body);
  if (!parsed.success) {
    return badRequest(req, parsed.error.issues[0]?.message ?? "Validation error");
  }

  const { source, type, payload } = parsed.data;

  if (type === "memo") {
    const memoBody = buildMemoBody(payload);
    const [memo] = await db
      .insert(memos)
      .values({
        user_id: userId,
        type: "text",
        body: memoBody,
        origin: "api",
        source_url: sanitizeSourceUrl(payload.source_url),
        device: source,
      })
      .returning();

    if (memo) {
      await sendEvent({ name: "memo/created", data: { memo_id: memo.id } });
      await logActivity(userId, "ingest", source, "memo", memo.id);
    }

    return withCors(req, NextResponse.json(memo, { status: 201 }));
  }

  if (type === "observation") {
    const title = typeof payload.title === "string" ? payload.title : `Observation from ${source}`;
    const bodyText = typeof payload.body === "string" ? payload.body : undefined;
    const [item] = await db
      .insert(inbox_items)
      .values({
        user_id: userId,
        kind: "orphan",
        title,
        body: bodyText,
        payload,
      })
      .returning();

    if (item) {
      await logActivity(userId, "ingest", source, "inbox_item", item.id);
    }

    return withCors(req, NextResponse.json(item, { status: 201 }));
  }

  if (type === "activity") {
    const verb = typeof payload.verb === "string" ? payload.verb : "ingest";
    const subject = typeof payload.subject === "string" ? payload.subject : source;
    const [activity] = await db
      .insert(activities)
      .values({
        user_id: userId,
        verb,
        subject,
        target_type: typeof payload.target_type === "string" ? payload.target_type : undefined,
        target_id: typeof payload.target_id === "string" ? payload.target_id : undefined,
      })
      .returning();

    return withCors(req, NextResponse.json(activity, { status: 201 }));
  }

  return badRequest(req, "Unsupported type");
}
