// History read assembly: keyset page + ONE batched attachment query.
//
// Request-scoped only: results are computed per request against the verified
// user id; nothing here is cached across users or requests.

import type {
  AttachmentKind,
  AttachmentRow,
  MemoReadStore,
  MemoRow,
} from "./types";
import type { HistoryQuery } from "./query";
import { encodeCursor } from "./query";
import { classifyAttachment, isValidStorageKey, type AttachmentPreview } from "./media";
import { importedMediaDisplayBody } from "./presentation";
import { fetchTagsByMemoId } from "./tags";

export interface AttachmentView {
  id: string;
  kind: AttachmentKind;
  preview: AttachmentPreview;
  mime_type: string | null;
  filename: string | null;
  size_bytes: number | null;
  duration_sec: number | null;
  duration_ms: number | null;
  position: number | null;
  /** OCR text when present (legacy rows may have none) — used for alt text. */
  ocr_text: string | null;
  /** Same-origin authenticated route — never a public/signed URL. */
  url: string;
  /**
   * False when trusted metadata is legacy/unsafe to serve (e.g. storage key
   * outside the owner prefix). The reference stays visible with an honest
   * unavailable state; nothing is dropped and nothing is claimed verified.
   */
  available: boolean;
}

export interface MemoListItem {
  id: string;
  type: string;
  body: string;
  /**
   * Optional read-only display body, present ONLY when presentation actually
   * changed it (currently exactly the empty string: a validated generated
   * media-only placeholder body). `body` always stays the original bytes and
   * remains the value for search, counting, export and the wire.
   */
  presentationBody?: string;
  /** Original DB timestamp string — microseconds preserved. */
  created_at: string;
  attachments: AttachmentView[];
  /**
   * Exact metadata tag labels (leading `#`, original bytes) for this memo.
   * Never derived from body text and never normalized.
   */
  tags: string[];
}

export type HistoryFetchResult =
  | { ok: true; items: MemoListItem[]; hasMore: boolean; nextCursor: string | null }
  | { ok: false; reason: "unavailable" };

export function attachmentUrl(memoId: string, attachmentId: string): string {
  return `/api/memos/${encodeURIComponent(memoId)}/attachments/${encodeURIComponent(attachmentId)}`;
}

export function toAttachmentView(
  row: AttachmentRow,
  userId: string,
  memoId: string,
): AttachmentView {
  return {
    id: row.id,
    kind: row.kind,
    preview: classifyAttachment(row.kind, row.mime_type),
    mime_type: row.mime_type,
    filename: row.filename,
    size_bytes: row.size_bytes,
    duration_sec: row.duration_sec,
    duration_ms: row.duration_ms,
    position: row.position,
    ocr_text: row.ocr_text,
    url: attachmentUrl(memoId, row.id),
    available: isValidStorageKey(row.storage_key, userId),
  };
}

export async function fetchMemoHistory(
  store: MemoReadStore,
  userId: string,
  query: HistoryQuery,
): Promise<HistoryFetchResult> {
  const listed = await store.listMemos({
    userId,
    q: query.q,
    tag: query.tag,
    type: query.type,
    fromIso: query.fromIso,
    toIso: query.toIso,
    cursor: query.cursor,
    limit: query.limit + 1,
  });
  if (listed.error || listed.rows === null) return { ok: false, reason: "unavailable" };

  const hasMore = listed.rows.length > query.limit;
  const pageRows = hasMore ? listed.rows.slice(0, query.limit) : listed.rows;

  // Attachments for the whole page in ONE query — no per-memo lookups.
  const memoIds = pageRows.map((row) => row.id);
  const attachments =
    memoIds.length > 0 ? await store.listAttachmentsByMemoIds(memoIds) : { rows: [], error: null };
  if (attachments.error || attachments.rows === null) {
    // Failing loud beats silently dropping attachment references.
    return { ok: false, reason: "unavailable" };
  }

  const byMemo = new Map<string, AttachmentRow[]>();
  for (const row of attachments.rows) {
    const list = byMemo.get(row.memo_id);
    if (list) list.push(row);
    else byMemo.set(row.memo_id, [row]);
  }

  // Exact metadata labels for the whole page in ONE bounded batched traversal
  // (keyset-paged past 1000 rows) — never per-memo lookups.
  const tags = await fetchTagsByMemoId(store, userId, memoIds);
  if (tags.error || tags.rows === null) {
    // Failing loud beats silently rendering memos without their exact tags.
    return { ok: false, reason: "unavailable" };
  }
  const tagsByMemo = tags.rows;

  const items: MemoListItem[] = pageRows.map((row: MemoRow) => {
    const attachmentRows = byMemo.get(row.id) ?? [];
    // Read-only presentation is derived from the trusted AttachmentRows
    // BEFORE they become browser views (ADR-0026).
    const displayBody = importedMediaDisplayBody({
      body: row.body,
      attachments: attachmentRows,
      ownerUserId: userId,
      memoId: row.id,
    });
    const item: MemoListItem = {
      id: row.id,
      type: row.type,
      body: row.body,
      created_at: row.created_at,
      attachments: attachmentRows.map((a) => toAttachmentView(a, userId, row.id)),
      tags: tagsByMemo.get(row.id) ?? [],
    };
    // ONLY when changed — the raw body above is always byte-identical.
    if (displayBody !== row.body) item.presentationBody = displayBody;
    return item;
  });

  const last = pageRows[pageRows.length - 1];
  const nextCursor = hasMore && last ? encodeCursor({ createdAt: last.created_at, id: last.id }) : null;
  return { ok: true, items, hasMore, nextCursor };
}
