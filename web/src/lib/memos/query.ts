// Strict parsing/validation for the /memos history query surface.
//
// Every field is validated BEFORE any PostgREST filter is composed. The cursor
// carries the ORIGINAL database timestamp string so microsecond precision
// survives paging (never `Date.toISOString()`).

import type { MemoType } from "./types";
import { validateTagLabel } from "./tags";

export interface HistoryCursor {
  /** Original DB timestamptz string, microseconds preserved. */
  createdAt: string;
  /** UUID of the last row on the previous page. */
  id: string;
}

export const DEFAULT_PAGE_SIZE = 20;
export const MAX_PAGE_SIZE = 50;
export const MAX_QUERY_LENGTH = 200;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const TSTAMP_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?(Z|[+-]\d{2}:\d{2})$/;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const CONTROL_RE = /[\u0000-\u001f\u007f]/;
const MEMO_TYPES: readonly MemoType[] = ["text", "url", "voice", "photo", "file"];

export function isUuid(value: string): boolean {
  return UUID_RE.test(value);
}

export function isDbTimestamp(value: string): boolean {
  if (!TSTAMP_RE.test(value) || !shanghaiDayStartIso(value.slice(0, 10))) return false;
  const hour = Number(value.slice(11, 13));
  const minute = Number(value.slice(14, 16));
  const second = Number(value.slice(17, 19));
  if (hour > 23 || minute > 59 || second > 59) return false;
  const zone = value.endsWith("Z") ? null : value.slice(-6);
  return !zone || (Number(zone.slice(1, 3)) <= 15 && Number(zone.slice(4)) <= 59);
}

export function encodeCursor(cursor: HistoryCursor): string {
  return Buffer.from(
    JSON.stringify({ c: cursor.createdAt, i: cursor.id }),
    "utf8",
  ).toString("base64url");
}

export function decodeCursor(raw: string): HistoryCursor | null {
  if (raw.length > 256) return null;
  let parsed: unknown;
  try {
    const json = Buffer.from(raw, "base64url").toString("utf8");
    // Reject non-canonical base64url (Buffer is lenient).
    if (Buffer.from(json, "utf8").toString("base64url") !== raw) return null;
    parsed = JSON.parse(json);
  } catch {
    return null;
  }
  if (typeof parsed !== "object" || parsed === null) return null;
  const record = parsed as Record<string, unknown>;
  const keys = Object.keys(record);
  if (keys.length !== 2 || !("c" in record) || !("i" in record)) return null;
  const createdAt = record.c;
  const id = record.i;
  if (typeof createdAt !== "string" || !isDbTimestamp(createdAt)) return null;
  if (typeof id !== "string" || !isUuid(id)) return null;
  return { createdAt, id };
}

export interface HistoryQuery {
  q: string | null;
  type: MemoType | null;
  /**
   * Exact metadata tag label (leading `#`, bytes preserved) or null. This is
   * INDEPENDENT of `q`: `q` stays a literal body search, `tag` is exact
   * membership metadata. No normalization, comma splitting or wildcards.
   */
  tag: string | null;
  /** Inclusive created-at lower bound (Asia/Shanghai day start), or null. */
  fromIso: string | null;
  /** Exclusive created-at upper bound (Asia/Shanghai day after `to`), or null. */
  toIso: string | null;
  cursor: HistoryCursor | null;
  limit: number;
}

export type HistoryQueryParse =
  | { ok: true; query: HistoryQuery; }
  | { ok: false; errors: string[] };

/**
 * Convert a strict `YYYY-MM-DD` calendar date to the instant of its 00:00 in
 * Asia/Shanghai (fixed UTC+8; the zone has had no DST since 1991). Returns
 * null for dates that parse syntactically but do not exist (e.g. 2026-02-30).
 */
export function shanghaiDayStartIso(date: string): string | null {
  if (!DATE_RE.test(date)) return null;
  const [y, m, d] = date.split("-").map(Number);
  if (y < 1) return null;
  const roundTrip = new Date(0);
  roundTrip.setUTCFullYear(y, m - 1, d);
  if (
    roundTrip.getUTCFullYear() !== y ||
    roundTrip.getUTCMonth() !== m - 1 ||
    roundTrip.getUTCDate() !== d
  ) {
    return null;
  }
  return `${date}T00:00:00+08:00`;
}

function nextShanghaiDayIso(date: string): string | null {
  const start = shanghaiDayStartIso(date);
  if (!start) return null;
  const [y, m, d] = date.split("-").map(Number);
  const next = new Date(0);
  next.setUTCFullYear(y, m - 1, d + 1);
  const iso = `${String(next.getUTCFullYear()).padStart(4, "0")}-${String(next.getUTCMonth() + 1).padStart(2, "0")}-${String(
    next.getUTCDate(),
  ).padStart(2, "0")}`;
  return `${iso}T00:00:00+08:00`;
}

/**
 * Parse the URL-driven history query. Repeated parameters (arrays), malformed
 * cursors, invalid dates and out-of-range limits are rejected with explicit
 * errors — never silently coerced.
 */
export function parseHistoryQuery(
  params: Record<string, string | string[] | undefined>,
): HistoryQueryParse {
  const errors: string[] = [];

  function single(name: string): string | null {
    const raw = params[name];
    if (raw === undefined) return null;
    if (Array.isArray(raw)) {
      errors.push(`Parameter "${name}" must appear at most once.`);
      return null;
    }
    return raw;
  }

  const rawQ = single("q");
  const rawType = single("type");
  const rawTag = single("tag");
  const rawFrom = single("from");
  const rawTo = single("to");
  const rawCursor = single("cursor");
  const rawLimit = single("limit");

  let q: string | null = null;
  if (rawQ !== null) {
    const trimmed = rawQ.trim();
    if (trimmed.length > 0) {
      if (trimmed.length > MAX_QUERY_LENGTH) {
        errors.push(`Search text must be at most ${MAX_QUERY_LENGTH} characters.`);
      } else if (CONTROL_RE.test(trimmed)) {
        errors.push("Search text must not contain control characters.");
      } else {
        q = trimmed;
      }
    }
  }

  let type: MemoType | null = null;
  if (rawType !== null && rawType !== "") {
    if ((MEMO_TYPES as readonly string[]).includes(rawType)) {
      type = rawType as MemoType;
    } else {
      errors.push(`Type must be one of: ${MEMO_TYPES.join(", ")}.`);
    }
  }

  // Exact label validation — never trimmed or normalized. An empty `tag=`
  // clears the filter (like an empty `type=`); anything else must satisfy the
  // canonical label rules exactly as stored.
  let tag: string | null = null;
  if (rawTag !== null && rawTag !== "") {
    tag = validateTagLabel(rawTag);
    if (tag === null) {
      errors.push(
        "Tag must start with \"#\", have a non-empty label, and contain no control characters.",
      );
    }
  }

  let fromIso: string | null = null;
  if (rawFrom !== null && rawFrom !== "") {
    fromIso = shanghaiDayStartIso(rawFrom);
    if (!fromIso) errors.push(`"from" must be a real calendar date (YYYY-MM-DD).`);
  }

  let toIso: string | null = null;
  if (rawTo !== null && rawTo !== "") {
    toIso = nextShanghaiDayIso(rawTo);
    if (!toIso) errors.push(`"to" must be a real calendar date (YYYY-MM-DD).`);
  }

  if (fromIso && toIso && rawFrom !== null && rawTo !== null && rawFrom > rawTo) {
    errors.push(`"from" must not be after "to".`);
  }

  let cursor: HistoryCursor | null = null;
  if (rawCursor !== null && rawCursor !== "") {
    cursor = decodeCursor(rawCursor);
    if (!cursor) errors.push("Pagination cursor is not valid.");
  }

  let limit = DEFAULT_PAGE_SIZE;
  if (rawLimit !== null && rawLimit !== "") {
    if (!/^\d{1,3}$/.test(rawLimit)) {
      errors.push("Page size must be a whole number.");
    } else {
      const parsedLimit = Number(rawLimit);
      if (parsedLimit < 1 || parsedLimit > MAX_PAGE_SIZE) {
        errors.push(`Page size must be between 1 and ${MAX_PAGE_SIZE}.`);
      } else {
        limit = parsedLimit;
      }
    }
  }

  if (errors.length > 0) return { ok: false, errors };
  return { ok: true, query: { q, type, tag, fromIso, toIso, cursor, limit } };
}
