// Cookie-bound owner-scoped read repository over the Supabase/PostgREST client.
//
// Identity is always the VERIFIED `auth.getUser().id` (never email). Every read
// carries an explicit `user_id` predicate on top of RLS, and memos are always
// tombstone-filtered (`deleted_at is null`). `created_at` values are read as
// raw database strings so cursor precision is preserved.

import type {
  AttachmentRow,
  ListMemosArgs,
  MemoReadStore,
  MemoRow,
  MemoTagLinkRow,
  StoreResult,
  UserTagRow,
} from "./types";
import { buildKeysetOr, buildLiteralSearch, quoteFilterLiteral } from "./postgrest";
export interface QueryResultLike {
  data: unknown;
  error: { message: string } | null;
}

export interface QueryBuilderLike extends PromiseLike<QueryResultLike> {
  select(columns: string): QueryBuilderLike;
  eq(column: string, value: unknown): QueryBuilderLike;
  is(column: string, value: null): QueryBuilderLike;
  in(column: string, values: readonly string[]): QueryBuilderLike;
  or(filters: string): QueryBuilderLike;
  gte(column: string, value: string): QueryBuilderLike;
  gt(column: string, value: string): QueryBuilderLike;
  lt(column: string, value: string): QueryBuilderLike;
  filter(column: string, operator: string, value: string): QueryBuilderLike;
  order(column: string, options?: { ascending?: boolean; nullsFirst?: boolean }): QueryBuilderLike;
  limit(count: number): QueryBuilderLike;
  maybeSingle(): PromiseLike<QueryResultLike>;
}

export interface PostgrestLike {
  from(table: string): QueryBuilderLike;
}

const MEMO_COLUMNS =
  "id,user_id,type,body,created_at,location,weather,device,source_url,ingest_mode,compile_status,origin,vault_path";
// Qualified inner relation via the composite (user_id, memo_id) FK: the tag
// membership filter runs in the DATABASE, before keyset/limit — never a
// "fetch link ids then .in()" pre-pass and never a page-local client filter.
const TAG_FILTER_EMBED = "memo_tag_links!inner(label)";
const ATTACHMENT_COLUMNS =
  "id,memo_id,kind,storage_key,filename,mime_type,size_bytes,duration_sec,duration_ms,position,ocr_text,transcript";

function failure(error: unknown): string {
  return error instanceof Error ? error.message : "Query failed";
}

function asRows<T>(result: QueryResultLike): StoreResult<T[]> {
  if (result.error) return { rows: null, error: failure(result.error) };
  return { rows: (result.data ?? []) as T[], error: null };
}

function asRow<T>(result: QueryResultLike): StoreResult<T | null> {
  if (result.error) return { rows: null, error: failure(result.error) };
  return { rows: (result.data ?? null) as T | null, error: null };
}

function normalizeAttachment(row: AttachmentRow): AttachmentRow {
  return {
    ...row,
    size_bytes: typeof row.size_bytes === "number" ? row.size_bytes : null,
    duration_sec: typeof row.duration_sec === "number" ? row.duration_sec : null,
    duration_ms: typeof row.duration_ms === "number" ? row.duration_ms : null,
    position: typeof row.position === "number" ? row.position : null,
    filename: row.filename ?? null,
    mime_type: row.mime_type ?? null,
    ocr_text: row.ocr_text ?? null,
    transcript: row.transcript ?? null,
  };
}

function orderAttachments(rows: AttachmentRow[]): AttachmentRow[] {
  // Position order first (legacy rows may have no position — they sort first,
  // then fall back to id for a stable total order).
  return [...rows].map(normalizeAttachment).sort((a, b) => {
    if (a.position === null && b.position !== null) return -1;
    if (a.position !== null && b.position === null) return 1;
    if (a.position !== null && b.position !== null && a.position !== b.position) {
      return a.position - b.position;
    }
    return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
  });
}

export function supabaseMemoStore(postgrest: PostgrestLike): MemoReadStore {
  async function getMemo(userId: string, memoId: string): Promise<StoreResult<MemoRow | null>> {
    const result = await postgrest
      .from("memos")
      .select(MEMO_COLUMNS)
      .eq("id", memoId)
      .eq("user_id", userId)
      .is("deleted_at", null)
      .maybeSingle();
    return asRow<MemoRow>(result);
  }

  return {
    async listMemos(args: ListMemosArgs): Promise<StoreResult<MemoRow[]>> {
      let builder = postgrest
        .from("memos")
        .select(args.tag ? `${MEMO_COLUMNS},${TAG_FILTER_EMBED}` : MEMO_COLUMNS)
        .eq("user_id", args.userId)
        .is("deleted_at", null);
      if (args.tag) builder = builder.eq("memo_tag_links.label", args.tag);
      if (args.type) builder = builder.eq("type", args.type);
      if (args.fromIso) builder = builder.gte("created_at", args.fromIso);
      if (args.toIso) builder = builder.lt("created_at", args.toIso);
      if (args.q) builder = builder.filter("body", "imatch", buildLiteralSearch(args.q));
      if (args.cursor) builder = builder.or(buildKeysetOr(args.cursor));
      const result = await builder
        .order("created_at", { ascending: false })
        .order("id", { ascending: false })
        .limit(args.limit);
      return asRows<MemoRow>(result);
    },

    async listAttachmentsByMemoIds(memoIds: string[]): Promise<StoreResult<AttachmentRow[]>> {
      if (memoIds.length === 0) return { rows: [], error: null };
      const result = await postgrest
        .from("memo_attachments")
        .select(ATTACHMENT_COLUMNS)
        .in("memo_id", memoIds)
        .order("position", { ascending: true, nullsFirst: true })
        .order("id", { ascending: true });
      const rows = asRows<AttachmentRow>(result);
      if (rows.rows === null) return rows;
      return { rows: orderAttachments(rows.rows), error: null };
    },

    getMemo,

    async listAttachmentsForMemo(memoId: string): Promise<StoreResult<AttachmentRow[]>> {
      const result = await postgrest
        .from("memo_attachments")
        .select(ATTACHMENT_COLUMNS)
        .eq("memo_id", memoId)
        .order("position", { ascending: true, nullsFirst: true })
        .order("id", { ascending: true });
      const rows = asRows<AttachmentRow>(result);
      if (rows.rows === null) return rows;
      return { rows: orderAttachments(rows.rows), error: null };
    },

    async getAttachmentForMemo({
      userId,
      memoId,
      attachmentId,
    }): Promise<StoreResult<AttachmentRow | null>> {
      // Ownership + tombstone first: the attachment is only reachable through
      // a live memo owned by the verified user.
      const memo = await getMemo(userId, memoId);
      if (memo.error) return { rows: null, error: memo.error };
      if (memo.rows === null) return { rows: null, error: null };
      const result = await postgrest
        .from("memo_attachments")
        .select(ATTACHMENT_COLUMNS)
        .eq("id", attachmentId)
        .eq("memo_id", memoId)
        .maybeSingle();
      const attachment = asRow<AttachmentRow>(result);
      if (attachment.rows === null) return attachment;
      return { rows: normalizeAttachment(attachment.rows), error: null };
    },

    async listTagCataloguePage({ userId, afterLabel, limit }): Promise<StoreResult<UserTagRow[]>> {
      // Exact label keyset (byte order) — no LIKE, no normalization, and
      // unused catalogue labels are included by construction.
      let builder = postgrest
        .from("user_tags")
        .select("label,in_import_catalog")
        .eq("user_id", userId);
      if (afterLabel !== null) builder = builder.gt("label", afterLabel);
      const result = await builder
        .order("label", { ascending: true, nullsFirst: false })
        .limit(limit);
      return asRows<UserTagRow>(result);
    },

    async listMemoTagLinksPage({ userId, memoIds, after, limit }): Promise<StoreResult<MemoTagLinkRow[]>> {
      if (memoIds.length === 0) return { rows: [], error: null };
      let builder = postgrest
        .from("memo_tag_links")
        .select("memo_id,label")
        .eq("user_id", userId)
        .in("memo_id", memoIds);
      if (after) {
        // Composite (memo_id, label) keyset so one label with >1000 member
        // memos traverses completely, still batched — never N+1.
        const memo = quoteFilterLiteral(after.memoId);
        const label = quoteFilterLiteral(after.label);
        builder = builder.or(`memo_id.gt.${memo},and(memo_id.eq.${memo},label.gt.${label})`);
      }
      const result = await builder
        .order("memo_id", { ascending: true, nullsFirst: false })
        .order("label", { ascending: true, nullsFirst: false })
        .limit(limit);
      return asRows<MemoTagLinkRow>(result);
    },
  };
}
