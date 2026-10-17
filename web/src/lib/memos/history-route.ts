// GET /api/memos/history handler (the legacy /api/memos timestamp-cursor API
// stays untouched for its existing callers).
//
// Query surface: `q` text search, optional `type` and `from`/`to` created-time
// filters, stable descending (created_at, id) keyset `cursor`, bounded `limit`.
// All query fields are strictly validated before any PostgREST filter is
// composed; search literals use top-level imatch with PostgreSQL literal mode.

import { parseHistoryQuery } from "./query";
import { fetchMemoHistory, type AttachmentView, type MemoListItem } from "./history";
import type { MemoReadStore } from "./types";

export interface HistoryRouteContext {
  /** Verified auth uid (works even when the account has no email), or null. */
  userId: string | null;
  store: MemoReadStore;
}

export interface HistoryResponseBody {
  items: Array<
    MemoListItem & {
      attachments: AttachmentView[];
    }
  >;
  next_cursor: string | null;
  has_more: boolean;
  page_size: number;
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "private, no-store",
      "x-content-type-options": "nosniff",
    },
  });
}

export async function handleHistoryRequest(
  request: Request,
  ctx: HistoryRouteContext,
): Promise<Response> {
  if (!ctx.userId) return json(401, { error: "Unauthorized" });

  const url = new URL(request.url);
  const params: Record<string, string | string[] | undefined> = {};
  for (const key of new Set(url.searchParams.keys())) {
    const all = url.searchParams.getAll(key);
    params[key] = all.length > 1 ? all : all[0];
  }

  const parsed = parseHistoryQuery(params);
  if (!parsed.ok) {
    return json(400, { error: "Invalid query", details: parsed.errors });
  }

  const result = await fetchMemoHistory(ctx.store, ctx.userId, parsed.query);
  if (!result.ok) {
    // Generic, honest failure: never raw backend errors or SQL details.
    return json(503, { error: "History is unavailable right now. Please try again." });
  }

  return json(200, {
    items: result.items,
    next_cursor: result.nextCursor,
    has_more: result.hasMore,
    page_size: parsed.query.limit,
  } satisfies HistoryResponseBody);
}
