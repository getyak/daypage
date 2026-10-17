// Read-only memo detail assembly: owned, non-tombstoned memo plus ALL of its
// attachments in position order (single query). No mutations, no legacy
// action wiring.

import type { MemoReadStore, MemoRow } from "./types";
import { toAttachmentView, type AttachmentView } from "./history";
import { importedMediaDisplayBody } from "./presentation";
import { fetchTagsForMemo } from "./tags";

export interface MemoDetail {
  memo: MemoRow;
  attachments: AttachmentView[];
  /** Exact metadata tag labels (leading `#`, original bytes) for this memo. */
  tags: string[];
  /**
   * Optional read-only display body, present ONLY when presentation actually
   * changed it (currently exactly the empty string: a validated generated
   * media-only placeholder body). `memo.body` always stays the original bytes.
   */
  presentationBody?: string;
}

export type MemoDetailResult =
  | { ok: true; detail: MemoDetail }
  | { ok: false; reason: "not-found" | "unavailable" };

export async function fetchMemoDetail(
  store: MemoReadStore,
  userId: string,
  memoId: string,
): Promise<MemoDetailResult> {
  const memo = await store.getMemo(userId, memoId);
  if (memo.error || memo.rows === null) {
    return { ok: false, reason: memo.error ? "unavailable" : "not-found" };
  }

  const attachments = await store.listAttachmentsForMemo(memoId);
  if (attachments.error || attachments.rows === null) {
    return { ok: false, reason: "unavailable" };
  }

  const tags = await fetchTagsForMemo(store, userId, memoId);
  if (tags.error || tags.rows === null) {
    // Failing loud beats silently dropping the memo's exact metadata tags.
    return { ok: false, reason: "unavailable" };
  }

  const attachmentRows = attachments.rows;
  // Read-only presentation is derived from the trusted AttachmentRows BEFORE
  // they become browser views (ADR-0026).
  const displayBody = importedMediaDisplayBody({
    body: memo.rows.body,
    attachments: attachmentRows,
    ownerUserId: userId,
    memoId,
  });
  const detail: MemoDetail = {
    memo: memo.rows,
    attachments: attachmentRows.map((a) => toAttachmentView(a, userId, memoId)),
    tags: tags.rows,
  };
  // ONLY when changed — `memo.body` above is always byte-identical.
  if (displayBody !== memo.rows.body) detail.presentationBody = displayBody;
  return { ok: true, detail };
}
