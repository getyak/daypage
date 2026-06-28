import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/lib/auth/session";
import { db } from "@/lib/db/client";
import {
  users,
  memos,
  inbox_items,
  activities,
  tree_nodes,
  work_orders,
} from "@/lib/db/schema";
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
  // US-017: `channel` distinguishes sub-streams within a source. The
  // claude-code source uses channel='agent-return' for executor product
  // flow-back; absent/other values fall through to the normal ingest path.
  channel: z.string().min(1).optional(),
  type: z.enum(["memo", "observation", "activity"]),
  payload: z.record(z.string(), z.unknown()),
});

// US-017: an agent return carries the produced text plus a pointer back to the
// task tree. The tree node may be named directly or resolved from the
// originating work_order's `callback` ({ tree_node_id }).
const AgentReturnPayloadSchema = z.object({
  body: z.string().optional(),
  result: z.string().optional(),
  tree_node_id: z.string().min(1).optional(),
  work_order_id: z.string().min(1).optional(),
});

// Resolve the tree node a return should commit back to: an explicit
// tree_node_id wins; otherwise read it from the work_order's callback.
async function resolveReturnTreeNodeId(
  payload: z.infer<typeof AgentReturnPayloadSchema>
): Promise<string | null> {
  if (payload.tree_node_id) return payload.tree_node_id;
  if (!payload.work_order_id) return null;

  const rows = await db
    .select({ callback: work_orders.callback })
    .from(work_orders)
    .where(eq(work_orders.id, payload.work_order_id))
    .limit(1);

  const callback = rows[0]?.callback;
  if (callback && typeof callback === "object" && !Array.isArray(callback)) {
    const node = (callback as Record<string, unknown>).tree_node_id;
    if (typeof node === "string") return node;
  }
  return null;
}

// Append a memo id to the tree node's evidence list so the return is wired
// back into the Git-style task tree before compilation commits it.
async function linkMemoToTreeNode(treeNodeId: string, memoId: string) {
  const rows = await db
    .select({ evidence_memo_ids: tree_nodes.evidence_memo_ids })
    .from(tree_nodes)
    .where(eq(tree_nodes.id, treeNodeId))
    .limit(1);

  const current = rows[0]?.evidence_memo_ids;
  if (!rows[0]) return; // node no longer exists — nothing to link

  const existing = Array.isArray(current) ? (current as string[]) : [];
  if (existing.includes(memoId)) return;

  await db
    .update(tree_nodes)
    .set({ evidence_memo_ids: [...existing, memoId] })
    .where(eq(tree_nodes.id, treeNodeId));
}

// US-017: ingest an agent product flow-back. Creates a memo marked
// source='agent-return', links it to the originating tree node, and triggers
// the existing compile pipeline so the result commits back to the tree.
async function ingestAgentReturn(
  req: NextRequest,
  userId: string,
  source: string,
  payload: Record<string, unknown>
): Promise<NextResponse> {
  const parsed = AgentReturnPayloadSchema.safeParse(payload);
  if (!parsed.success) {
    return badRequest(req, parsed.error.issues[0]?.message ?? "Validation error");
  }

  const memoBody = parsed.data.body?.trim() || parsed.data.result?.trim();
  if (!memoBody) {
    return badRequest(req, "agent-return requires a non-empty body or result");
  }

  const [memo] = await db
    .insert(memos)
    .values({
      user_id: userId,
      type: "text",
      body: memoBody,
      origin: "api",
      source: "agent-return",
      device: source,
    })
    .returning();

  if (!memo) return badRequest(req, "Failed to create memo");

  const treeNodeId = await resolveReturnTreeNodeId(parsed.data);
  if (treeNodeId) {
    await linkMemoToTreeNode(treeNodeId, memo.id);
  }

  // Trigger the existing compile flow so the return commits back to the tree.
  await sendEvent({ name: "memo/created", data: { memo_id: memo.id } });
  await logActivity(userId, "agent-return", source, "memo", memo.id);

  return withCors(req, NextResponse.json(memo, { status: 201 }));
}

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

  const { source, channel, type, payload } = parsed.data;

  // US-017: agent product flow-back. claude-code's agent-return channel routes
  // to a dedicated handler that marks the memo and wires it back to the tree.
  if (source === "claude-code" && channel === "agent-return") {
    return ingestAgentReturn(req, userId, source, payload);
  }

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
