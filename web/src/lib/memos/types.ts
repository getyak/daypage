// Account-scoped, read-only web memo reading (ADR-0022).
//
// Row shapes mirror the Supabase/Postgres tables but intentionally keep
// `created_at` as the ORIGINAL database timestamp string: cursor pagination and
// display must never round-trip through `Date` (which truncates microseconds).

export type MemoType = "text" | "url" | "voice" | "photo" | "file";
export type AttachmentKind = "audio" | "photo" | "file";

export interface MemoRow {
  id: string;
  user_id: string;
  type: MemoType;
  body: string;
  /** Original timestamptz text from PostgREST, e.g. `2026-01-01T08:00:00.123456+00:00`. */
  created_at: string;
  location: unknown;
  weather: unknown;
  device: string | null;
  source_url: string | null;
  ingest_mode: string | null;
  compile_status: string | null;
  origin: string | null;
  vault_path: string | null;
}

export interface AttachmentRow {
  id: string;
  memo_id: string;
  kind: AttachmentKind;
  /** Trusted DB metadata only; never taken from the request. */
  storage_key: string;
  filename: string | null;
  mime_type: string | null;
  size_bytes: number | null;
  duration_sec: number | null;
  duration_ms: number | null;
  position: number | null;
  ocr_text: string | null;
  transcript: string | null;
}

export type StoreResult<T> = { rows: T; error: null } | { rows: null; error: string };

/** Exact account tag label catalogue row (canonical 0036 `user_tags`). */
export interface UserTagRow {
  /** Original label including its leading `#` — bytes never normalized. */
  label: string;
  in_import_catalog: boolean;
}

/** Exact per-memo tag association row (canonical 0036 `memo_tag_links`). */
export interface MemoTagLinkRow {
  memo_id: string;
  /** Original label including its leading `#` — bytes never normalized. */
  label: string;
}

export interface ListMemosArgs {
  userId: string;
  /** Text search literal (already validated); applied as a literal imatch value. */
  q: string | null;
  /** Exact metadata tag label (already validated), applied as owner-scoped relation
   *  filtering in the DB BEFORE keyset/limit — never a body search or page filter. */
  tag: string | null;
  type: MemoType | null;
  /** Inclusive lower bound as a validated timestamp string, or null. */
  fromIso: string | null;
  /** Exclusive upper bound as a validated timestamp string, or null. */
  toIso: string | null;
  /** Keyset cursor: strictly older than (created_at, id). */
  cursor: { createdAt: string; id: string } | null;
  /** Maximum number of rows to return (the caller adds +1 for has_more). */
  limit: number;
}

/**
 * Narrow read port used by history, detail and the attachment proxy. The
 * Supabase implementation enforces RLS plus explicit `user_id` predicates and
 * tombstone exclusion; tests substitute an in-memory PostgREST double.
 */
export interface MemoReadStore {
  listMemos(args: ListMemosArgs): Promise<StoreResult<MemoRow[]>>;
  /** One batched query for all memos of a page — never per-memo lookups. */
  listAttachmentsByMemoIds(memoIds: string[]): Promise<StoreResult<AttachmentRow[]>>;
  getMemo(userId: string, memoId: string): Promise<StoreResult<MemoRow | null>>;
  listAttachmentsForMemo(memoId: string): Promise<StoreResult<AttachmentRow[]>>;
  /**
   * Resolves an attachment only when its memo is owned by `userId` and not a
   * tombstone. Returns a null row otherwise (uniform not-found upstream).
   */
  getAttachmentForMemo(args: {
    userId: string;
    memoId: string;
    attachmentId: string;
  }): Promise<StoreResult<AttachmentRow | null>>;
  /**
   * One bounded page of the owner's exact tag catalogue (including labels with
   * no memo membership yet), keyset-paged by `label` (byte order) so >1000
   * labels are traversed completely — a single default 1000-row response is
   * never assumed to be the whole set.
   */
  listTagCataloguePage(args: {
    userId: string;
    /** Exclusive keyset: return labels strictly after this exact label. */
    afterLabel: string | null;
    limit: number;
  }): Promise<StoreResult<UserTagRow[]>>;
  /**
   * One bounded page of exact tag memberships for a BATCH of memo ids — never
   * per-memo lookups. Keyset-paged by (memo_id, label) so a single label with
   * more than 1000 associations is traversed completely.
   */
  listMemoTagLinksPage(args: {
    userId: string;
    memoIds: readonly string[];
    /** Exclusive keyset: links strictly after (memo_id, label). */
    after: { memoId: string; label: string } | null;
    limit: number;
  }): Promise<StoreResult<MemoTagLinkRow[]>>;
}
