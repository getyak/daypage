// ─── DayPage MCP server (read-only) ───────────────────────────────────────────
// Server-only. Implements a minimal Model Context Protocol server over JSON-RPC
// 2.0 so external agents (Claude Desktop, Cursor, …) can search and read the
// signed-in user's wiki as context.
//
// Transport lives in src/app/api/mcp/route.ts (Streamable HTTP). This module is
// transport-agnostic: it takes a parsed JSON-RPC request plus the authenticated
// user id and returns a JSON-RPC response object (or null for notifications).
//
// Read tools (require the "read" scope):
//   • search_wiki(query, top_k?) — semantic search via rag.ts retrievePages
//   • get_page(slug)             — fetch one wiki page by slug
//   • list_domains()             — list the user's domains
//
// Write tools (require the "write" scope):
//   • add_memo(text)             — save a raw memo and trigger AI compilation
//
// Every search result carries the page `slug` plus a `url` that links back into
// DayPage, so the calling agent can cite / deep-link the source.

import "server-only";
import { and, eq } from "drizzle-orm";
import { db } from "@/lib/db/client";
import { pages, domains, memos } from "@/lib/db/schema";
import { retrievePages } from "@/lib/ai/rag";
import { sendEvent } from "@/lib/inngest/client";
import { sanitizeMemoBody } from "@/lib/sanitize";
import { hasScope, type ApiAuthResult } from "@/lib/api-auth";

// MCP protocol revision we implement. Clients negotiate via `initialize`.
const PROTOCOL_VERSION = "2024-11-05";
const SERVER_NAME = "daypage-wiki";
const SERVER_VERSION = "0.1.0";

// ─── JSON-RPC 2.0 types ───────────────────────────────────────────────────────

export interface JsonRpcRequest {
  jsonrpc: "2.0";
  id?: string | number | null;
  method: string;
  params?: unknown;
}

interface JsonRpcSuccess {
  jsonrpc: "2.0";
  id: string | number | null;
  result: unknown;
}

interface JsonRpcError {
  jsonrpc: "2.0";
  id: string | number | null;
  error: { code: number; message: string; data?: unknown };
}

export type JsonRpcResponse = JsonRpcSuccess | JsonRpcError;

// Standard JSON-RPC error codes.
const PARSE_ERROR = -32700;
const INVALID_REQUEST = -32600;
const METHOD_NOT_FOUND = -32601;
const INVALID_PARAMS = -32602;
const INTERNAL_ERROR = -32603;

function ok(id: string | number | null, result: unknown): JsonRpcSuccess {
  return { jsonrpc: "2.0", id, result };
}

function err(
  id: string | number | null,
  code: number,
  message: string,
  data?: unknown
): JsonRpcError {
  return { jsonrpc: "2.0", id, error: { code, message, ...(data !== undefined ? { data } : {}) } };
}

// ─── Tool definitions (advertised via tools/list) ─────────────────────────────

const TOOLS = [
  {
    name: "search_wiki",
    description:
      "Semantic search across the user's DayPage wiki. Returns the most relevant pages with their slug, title, a content snippet, a similarity score, and a url that links back into DayPage.",
    inputSchema: {
      type: "object",
      properties: {
        query: {
          type: "string",
          description: "Natural-language search query.",
        },
        top_k: {
          type: "integer",
          description: "Maximum number of pages to return (1–20, default 8).",
          minimum: 1,
          maximum: 20,
        },
      },
      required: ["query"],
    },
  },
  {
    name: "get_page",
    description:
      "Fetch a single DayPage wiki page by its slug, returning the full Markdown body and metadata.",
    inputSchema: {
      type: "object",
      properties: {
        slug: {
          type: "string",
          description: "The page slug (as returned by search_wiki).",
        },
      },
      required: ["slug"],
    },
  },
  {
    name: "list_domains",
    description:
      "List the user's wiki domains (top-level knowledge areas), ordered by position.",
    inputSchema: {
      type: "object",
      properties: {},
    },
  },
  {
    name: "add_memo",
    description:
      "Save a new memo (note) back into the user's DayPage. The text is captured as raw input and runs through DayPage's normal AI compilation pipeline. Requires an API key with the 'write' scope.",
    inputSchema: {
      type: "object",
      properties: {
        text: {
          type: "string",
          description: "The memo text to save (plain text / Markdown).",
        },
      },
      required: ["text"],
    },
  },
] as const;

// ─── Link-back helper ─────────────────────────────────────────────────────────

function appBaseUrl(): string {
  // Prefer an explicit public URL; fall back to NEXTAUTH_URL, then localhost.
  const base =
    process.env.NEXT_PUBLIC_APP_URL ||
    process.env.NEXTAUTH_URL ||
    "http://localhost:3000";
  return base.replace(/\/$/, "");
}

function pageUrl(slug: string): string {
  return `${appBaseUrl()}/wiki/${encodeURIComponent(slug)}`;
}

// ─── MCP content helper ───────────────────────────────────────────────────────
// MCP tool results wrap data in a `content` array. We return a human-readable
// text block plus a `structuredContent` object for programmatic consumers.

function toolResult(text: string, structured: unknown) {
  return {
    content: [{ type: "text", text }],
    structuredContent: structured,
  };
}

// ─── Tool implementations ─────────────────────────────────────────────────────

function snippet(body: string | null, max = 280): string {
  if (!body) return "";
  const trimmed = body.trim();
  return trimmed.length > max ? `${trimmed.slice(0, max)}…` : trimmed;
}

async function runSearchWiki(userId: string, args: Record<string, unknown>) {
  const query = typeof args.query === "string" ? args.query.trim() : "";
  if (!query) {
    throw { code: INVALID_PARAMS, message: "search_wiki requires a non-empty 'query' string" };
  }

  let topK = 8;
  if (args.top_k !== undefined) {
    const n = Number(args.top_k);
    if (!Number.isFinite(n) || n < 1) {
      throw { code: INVALID_PARAMS, message: "'top_k' must be an integer >= 1" };
    }
    topK = Math.min(20, Math.floor(n));
  }

  const hits = await retrievePages(userId, query, { topK });

  const results = hits.map((p) => ({
    slug: p.slug,
    title: p.title,
    type: p.type,
    score: Number(p.score.toFixed(4)),
    snippet: snippet(p.body_md),
    url: pageUrl(p.slug),
  }));

  const text =
    results.length === 0
      ? `No wiki pages matched "${query}".`
      : results
          .map(
            (r, i) =>
              `${i + 1}. ${r.title} (slug: ${r.slug}, score: ${r.score})\n   ${r.snippet}\n   ${r.url}`
          )
          .join("\n\n");

  return toolResult(text, { query, results });
}

async function runGetPage(userId: string, args: Record<string, unknown>) {
  const slug = typeof args.slug === "string" ? args.slug.trim() : "";
  if (!slug) {
    throw { code: INVALID_PARAMS, message: "get_page requires a non-empty 'slug' string" };
  }

  const rows = await db
    .select({
      slug: pages.slug,
      title: pages.title,
      type: pages.type,
      status: pages.status,
      body_md: pages.body_md,
      domain_id: pages.domain_id,
      updated_at: pages.updated_at,
    })
    .from(pages)
    .where(and(eq(pages.slug, slug), eq(pages.user_id, userId)))
    .limit(1);

  const page = rows[0];
  if (!page) {
    throw { code: INVALID_PARAMS, message: `No page found with slug "${slug}"` };
  }

  const structured = {
    slug: page.slug,
    title: page.title,
    type: page.type,
    status: page.status,
    domain_id: page.domain_id,
    body_md: page.body_md ?? "",
    url: pageUrl(page.slug),
    updated_at:
      page.updated_at instanceof Date ? page.updated_at.toISOString() : page.updated_at,
  };

  const text = `# ${page.title}\n(slug: ${page.slug}, ${structured.url})\n\n${page.body_md ?? ""}`;

  return toolResult(text, structured);
}

async function runListDomains(userId: string) {
  const rows = await db
    .select({
      slug: domains.slug,
      label: domains.label,
      color: domains.color,
      position: domains.position,
    })
    .from(domains)
    .where(eq(domains.user_id, userId))
    .orderBy(domains.position, domains.created_at);

  const text =
    rows.length === 0
      ? "No domains defined yet."
      : rows.map((d) => `• ${d.label} (slug: ${d.slug})`).join("\n");

  return toolResult(text, { domains: rows });
}

async function runAddMemo(auth: ApiAuthResult, args: Record<string, unknown>) {
  // Authorization: writing back requires the "write" scope (admin implies all).
  if (!hasScope(auth, "write")) {
    throw {
      code: INVALID_REQUEST,
      message:
        "Permission denied: this API key lacks the 'write' scope required to add memos",
    };
  }

  const text = typeof args.text === "string" ? args.text.trim() : "";
  if (!text) {
    throw { code: INVALID_PARAMS, message: "add_memo requires a non-empty 'text' string" };
  }

  const body = sanitizeMemoBody(text);

  // Mirror the POST /api/memos insert. Defaults appropriate for an external
  // agent writing through the API: the default "text" memo type, origin "api"
  // (this came in via the API), source "api", and the light ingest mode the
  // POST route defaults to. `compile_status` falls back to its column default
  // ("pending"), which the compilation pipeline picks up.
  const [memo] = await db
    .insert(memos)
    .values({
      user_id: auth.userId,
      type: "text",
      body,
      source: "api",
      origin: "api",
      ingest_mode: "light",
      word_count: body.split(/\s+/).filter(Boolean).length,
    })
    .returning();

  if (!memo) {
    throw { code: INTERNAL_ERROR, message: "Failed to save memo" };
  }

  // Trigger the normal compilation pipeline, exactly like POST /api/memos.
  await sendEvent({ name: "memo/created", data: { memo_id: memo.id } });

  const text_out = `Saved memo ${memo.id}. It will be compiled shortly.`;
  return toolResult(text_out, { memo_id: memo.id, status: "saved" });
}

async function dispatchTool(
  auth: ApiAuthResult,
  name: string,
  args: Record<string, unknown>
): Promise<unknown> {
  switch (name) {
    case "search_wiki":
      return runSearchWiki(auth.userId, args);
    case "get_page":
      return runGetPage(auth.userId, args);
    case "list_domains":
      return runListDomains(auth.userId);
    case "add_memo":
      return runAddMemo(auth, args);
    default:
      throw { code: INVALID_PARAMS, message: `Unknown tool: ${name}` };
  }
}

// ─── JSON-RPC method router ───────────────────────────────────────────────────

/**
 * Handle a single parsed JSON-RPC message for an authenticated caller.
 *
 * The full auth result (user id + scopes) is threaded through so per-tool
 * authorization (e.g. add_memo requiring the "write" scope) can be enforced.
 *
 * @returns a JSON-RPC response object, or `null` when the message is a
 *   notification (no `id`) that requires no reply (e.g. `notifications/*`).
 */
export async function handleMcpMessage(
  auth: ApiAuthResult,
  message: JsonRpcRequest
): Promise<JsonRpcResponse | null> {
  // Basic envelope validation.
  if (!message || message.jsonrpc !== "2.0" || typeof message.method !== "string") {
    return err(message?.id ?? null, INVALID_REQUEST, "Invalid JSON-RPC 2.0 request");
  }

  const id = message.id ?? null;
  const isNotification = message.id === undefined || message.id === null;

  switch (message.method) {
    case "initialize":
      return ok(id, {
        protocolVersion: PROTOCOL_VERSION,
        serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
        capabilities: { tools: {} },
        instructions:
          "DayPage wiki. Use search_wiki to find relevant pages, get_page to read one, and list_domains to browse top-level areas; every result includes a slug and url linking back to DayPage. Use add_memo to save a new note back into DayPage (requires the 'write' scope).",
      });

    case "ping":
      return ok(id, {});

    case "tools/list":
      return ok(id, { tools: TOOLS });

    case "tools/call": {
      const params = (message.params ?? {}) as { name?: unknown; arguments?: unknown };
      const name = typeof params.name === "string" ? params.name : "";
      const args =
        params.arguments && typeof params.arguments === "object"
          ? (params.arguments as Record<string, unknown>)
          : {};

      if (!name) {
        return err(id, INVALID_PARAMS, "tools/call requires a 'name'");
      }

      try {
        const result = await dispatchTool(auth, name, args);
        return ok(id, result);
      } catch (e) {
        // Tool-level errors surface as a JSON-RPC error with the tool's code,
        // or as an internal error for anything unexpected.
        if (e && typeof e === "object" && "code" in e && "message" in e) {
          const { code, message: msg } = e as { code: number; message: string };
          return err(id, code, msg);
        }
        console.error("[mcp] tool execution failed", e);
        return err(id, INTERNAL_ERROR, "Tool execution failed");
      }
    }

    default:
      // Notifications (e.g. notifications/initialized) get no response.
      if (isNotification) return null;
      return err(id, METHOD_NOT_FOUND, `Method not found: ${message.method}`);
  }
}

export const MCP_ERROR_CODES = {
  PARSE_ERROR,
  INVALID_REQUEST,
  METHOD_NOT_FOUND,
  INVALID_PARAMS,
  INTERNAL_ERROR,
};

export { TOOLS as MCP_TOOLS };
