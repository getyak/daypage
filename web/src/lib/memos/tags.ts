// Exact imported tag reading (issue #884, canonical 0036).
//
// Labels are EXACT strings including their leading '#': no normalization, no
// comma splitting, no case folding, no LIKE wildcards and no invented parent
// membership for '/' hierarchies. `q` stays a separate literal body search.
//
// Reads are owner-scoped (explicit verified uid on every query, on top of RLS)
// and bounded: the catalogue and batched memo memberships are traversed with
// stable keyset pages whenever a set can exceed one 1000-row response. A page
// that does not advance is an error — sets are never silently truncated into a
// fake-complete answer.

import type { MemoReadStore, StoreResult } from "./types";

/** Upper bound of rows requested per bounded page (mirrors PostgREST paging). */
export const TAG_PAGE_SIZE = 1000;

const TAG_CONTROL_RE = /[\u0000-\u001f\u007f]/;
const MIN_TAG_BYTES = 2;
export const MAX_TAG_BYTES = 1024;

/**
 * Compare two exact labels the way canonical `text COLLATE "C"` does: by
 * UTF-8 BYTES, never by JavaScript UTF-16 code units. The two orders disagree
 * at the BMP/astral boundary — e.g. `#\uE000` (EE 80 80) sorts BEFORE `#😀`
 * (F0 9F 98 80) in C, while UTF-16 says the opposite — so every keyset
 * page-advance check must use this comparison to stay consistent with the
 * database's `gt`/`order` semantics. No localeCompare, no normalization.
 */
export function compareUtf8Bytes(a: string, b: string): number {
  return Buffer.compare(Buffer.from(a, "utf8"), Buffer.from(b, "utf8"));
}

/**
 * Validate one exact tag label against the canonical schema rules (the
 * deployed `daypage_tag_import_label_ok`): leading '#', non-empty suffix,
 * 2..1024 UTF-8 bytes, no ASCII control characters or DEL. Everything else —
 * UTF-8 text, case, whitespace, punctuation, commas, slashes — is preserved
 * byte-for-byte and never trimmed or normalized.
 *
 * Returns the exact label, or null when the raw value is empty (no filter) or
 * fails validation.
 */
export function validateTagLabel(raw: string): string | null {
  if (raw.length === 0) return null;
  if (!raw.startsWith("#") || raw.length < MIN_TAG_BYTES) return null;
  if (TAG_CONTROL_RE.test(raw)) return null;
  if (Buffer.byteLength(raw, "utf8") > MAX_TAG_BYTES) return null;
  return raw;
}

function failure(error: unknown): string {
  return error instanceof Error ? error.message : "Query failed";
}

/**
 * Fetch the COMPLETE exact tag catalogue for one owner (including catalogue
 * labels that no memo uses yet) via bounded keyset pages. Errors surface as a
 * failed result — an unavailable database/schema must never render as an empty
 * successful catalogue.
 */
export async function fetchTagCatalogue(
  store: MemoReadStore,
  userId: string,
): Promise<StoreResult<string[]>> {
  const labels: string[] = [];
  const seen = new Set<string>();
  let afterLabel: string | null = null;

  for (;;) {
    const page = await store.listTagCataloguePage({
      userId,
      afterLabel,
      limit: TAG_PAGE_SIZE,
    });
    if (page.error || page.rows === null) {
      return { rows: null, error: page.error ?? failure(new Error("Query failed")) };
    }
    let advanced = false;
    for (const row of page.rows) {
      // C-collation byte order (NOT UTF-16): the keyset must advance strictly.
      if (afterLabel !== null && !(compareUtf8Bytes(row.label, afterLabel) > 0)) {
        // Anything else risks an infinite loop or a silently incomplete
        // catalogue.
        return { rows: null, error: "Tag catalogue did not advance" };
      }
      if (!seen.has(row.label)) {
        seen.add(row.label);
        labels.push(row.label);
      }
      advanced = true;
    }
    if (page.rows.length < TAG_PAGE_SIZE) return { rows: labels, error: null };
    if (!advanced) return { rows: null, error: "Tag catalogue did not advance" };
    afterLabel = page.rows[page.rows.length - 1].label;
  }
}

/**
 * Fetch the EXACT metadata labels for a batch of displayed memos in bounded
 * keyset pages over (memo_id, label) — one batched traversal, never an N+1
 * per-memo fetch and never a capped "first 1000 then give up".
 */
export async function fetchTagsByMemoId(
  store: MemoReadStore,
  userId: string,
  memoIds: readonly string[],
): Promise<StoreResult<Map<string, string[]>>> {
  const byMemo = new Map<string, string[]>();
  if (memoIds.length === 0) return { rows: byMemo, error: null };

  let after: { memoId: string; label: string } | null = null;
  for (;;) {
    const page = await store.listMemoTagLinksPage({
      userId,
      memoIds,
      after,
      limit: TAG_PAGE_SIZE,
    });
    if (page.error || page.rows === null) {
      return { rows: null, error: page.error ?? failure(new Error("Query failed")) };
    }
    let advanced = false;
    for (const row of page.rows) {
      // Composite keyset in C-collation byte order (NOT UTF-16) — same order
      // the DB applies to (memo_id, label).
      const cmpMemo = after === null ? 1 : compareUtf8Bytes(row.memo_id, after.memoId);
      if (
        after !== null &&
        !(
          cmpMemo > 0 ||
          (cmpMemo === 0 && compareUtf8Bytes(row.label, after.label) > 0)
        )
      ) {
        return { rows: null, error: "Memo tag links did not advance" };
      }
      const list = byMemo.get(row.memo_id);
      if (list) {
        if (list[list.length - 1] !== row.label) list.push(row.label);
      } else {
        byMemo.set(row.memo_id, [row.label]);
      }
      advanced = true;
    }
    if (page.rows.length < TAG_PAGE_SIZE) return { rows: byMemo, error: null };
    if (!advanced) return { rows: null, error: "Memo tag links did not advance" };
    after = {
      memoId: page.rows[page.rows.length - 1].memo_id,
      label: page.rows[page.rows.length - 1].label,
    };
  }
}

/**
 * Exact labels for one memo (the detail view). Same bounded traversal as the
 * batched path — a memo with more than 1000 memberships is still complete.
 */
export async function fetchTagsForMemo(
  store: MemoReadStore,
  userId: string,
  memoId: string,
): Promise<StoreResult<string[]>> {
  const fetched = await fetchTagsByMemoId(store, userId, [memoId]);
  if (fetched.error || fetched.rows === null) {
    return { rows: null, error: fetched.error ?? failure(new Error("Query failed")) };
  }
  return { rows: fetched.rows.get(memoId) ?? [], error: null };
}
