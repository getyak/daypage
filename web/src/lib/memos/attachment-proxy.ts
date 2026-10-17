// Authenticated streaming proxy for private memo attachments (ADR-0022).
//
// Boundary rules:
//   - authenticate FIRST (verified Supabase uid), then look up the owned,
//     non-tombstoned memo and its EXACT attachment id;
//   - object keys come only from trusted DB metadata and must be
//     owner-prefixed and traversal-free — the request never supplies a key,
//     URL or query target;
//   - bytes are streamed (never buffered) with the caller's abort signal
//     propagated to the upstream fetch, which must run with
//     `redirect: "manual"` so the Bearer token can never follow a redirect to
//     another host;
//   - only safe response headers are forwarded; cache is `private, no-store`
//     with `nosniff`; inline preview only for safe known image/audio/video
//     MIME, everything else downloads with a CRLF-safe RFC 5987 filename;
//   - wrong user / missing / tombstoned / unsafe key all return one uniform
//     404; upstream failures return a generic error with no tokens or object
//     paths.

import type { MemoReadStore } from "./types";
import {
  contentDisposition,
  isValidStorageKey,
  safeMimeOrOctetStream,
} from "./media";

export interface AttachmentProxyUser {
  id: string;
  accessToken: string;
}

export interface ObjectFetchArgs {
  method: "GET" | "HEAD";
  /** Validated owner-prefixed storage key from trusted DB metadata. */
  key: string;
  /** Validated single `bytes=` range value, or null. */
  range: string | null;
  /** Verified user's access token (stays server-side with the API key). */
  accessToken: string;
  /** Caller's abort signal — propagated so client disconnects cancel upstream. */
  signal: AbortSignal;
}

export interface AttachmentProxyContext {
  authenticate(): Promise<AttachmentProxyUser | null>;
  store: MemoReadStore;
  fetchObject(args: ObjectFetchArgs): Promise<Response>;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const CONTROL_RE = /[\u0000-\u001f\u007f]/;
const CONTENT_RANGE_RE = /^bytes (\d+)-(\d+)\/(\d+)$/;

export type ParsedRange =
  | { kind: "none" }
  | {
      kind: "single";
      headerValue: string;
      start: number | null;
      end: number | null;
      suffixLength: number | null;
    }
  | { kind: "invalid" };

function toSafeInt(digits: string): number | null {
  if (digits.length === 0 || digits.length > 15) return null;
  const value = Number(digits);
  return Number.isSafeInteger(value) ? value : null;
}

/**
 * Strict single-range parsing. Malformed values, multi-range lists and — when
 * the size is known — out-of-range requests are `invalid`; the caller answers
 * 416 for those. Valid ranges are forwarded verbatim to upstream.
 */
export function parseRangeHeader(
  header: string | null | undefined,
  sizeBytes: number | null,
): ParsedRange {
  if (header === null || header === undefined) return { kind: "none" };
  const value = header.trim();
  if (value === "") return { kind: "none" };
  const match = /^bytes=(.+)$/i.exec(value);
  if (!match) return { kind: "invalid" };
  const spec = match[1];
  if (spec.includes(",")) return { kind: "invalid" }; // multi-range rejected
  const parts = /^(\d*)-(\d*)$/.exec(spec);
  if (!parts) return { kind: "invalid" };
  const [, rawStart, rawEnd] = parts;
  if (rawStart === "" && rawEnd === "") return { kind: "invalid" };

  if (rawStart === "") {
    const suffixLength = toSafeInt(rawEnd);
    if (suffixLength === null || suffixLength === 0) return { kind: "invalid" };
    return { kind: "single", headerValue: value, start: null, end: null, suffixLength };
  }

  const start = toSafeInt(rawStart);
  if (start === null) return { kind: "invalid" };
  let end: number | null = null;
  if (rawEnd !== "") {
    end = toSafeInt(rawEnd);
    if (end === null || end < start) return { kind: "invalid" };
  }
  if (sizeBytes !== null && start >= sizeBytes) return { kind: "invalid" };
  return { kind: "single", headerValue: value, start, end, suffixLength: null };
}

function jsonError(status: number, message: string): Response {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "private, no-store",
      "x-content-type-options": "nosniff",
    },
  });
}

function uniformNotFound(): Response {
  // Wrong user, missing memo, tombstone, malformed id and unsafe stored key
  // are indistinguishable by design.
  return jsonError(404, "Not found");
}

function headerSafe(value: string | null | undefined, maxLength = 256): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (trimmed === "" || trimmed.length > maxLength || CONTROL_RE.test(trimmed)) return null;
  return trimmed;
}

function sizeFromBytes(value: unknown): number | null {
  return typeof value === "number" && Number.isSafeInteger(value) && value > 0 ? value : null;
}

function buildResponseHeaders(args: {
  mime: string | null;
  upstream: Response;
  disposition: string;
  sizeBytes: number | null;
  contentRange: string | null;
}): Headers {
  const headers = new Headers();
  headers.set("content-type", safeMimeOrOctetStream(args.mime));
  headers.set("content-disposition", args.disposition);
  headers.set("cache-control", "private, no-store");
  headers.set("x-content-type-options", "nosniff");
  headers.set("content-security-policy", "sandbox");
  headers.set("referrer-policy", "no-referrer");
  headers.set("accept-ranges", "bytes");
  if (args.contentRange) headers.set("content-range", args.contentRange);

  const upstreamLength = headerSafe(args.upstream.headers.get("content-length"));
  if (upstreamLength && /^\d+$/.test(upstreamLength) && Number.isSafeInteger(Number(upstreamLength))) {
    headers.set("content-length", upstreamLength);
  }
  const etag = headerSafe(args.upstream.headers.get("etag"));
  if (etag) headers.set("etag", etag);
  const lastModified = headerSafe(args.upstream.headers.get("last-modified"));
  if (lastModified) headers.set("last-modified", lastModified);
  return headers;
}

async function discard(upstream: Response): Promise<void> {
  try { await upstream.body?.cancel(); } catch { /* Already aborted/closed. */ }
}

function validPartial(
  range: ParsedRange,
  upstream: Response,
  sizeBytes: number | null,
): string | null {
  if (range.kind !== "single") return null;
  const encoding = upstream.headers.get("content-encoding");
  if (encoding && encoding !== "identity") return null;
  const raw = headerSafe(upstream.headers.get("content-range"), 128);
  const match = raw ? CONTENT_RANGE_RE.exec(raw) : null;
  if (!match) return null;
  const start = toSafeInt(match[1]), end = toSafeInt(match[2]), total = toSafeInt(match[3]);
  if (start === null || end === null || total === null || total <= 0 ||
      start > end || end >= total || (sizeBytes !== null && total !== sizeBytes)) return null;
  const expectedStart = range.start ?? Math.max(0, total - range.suffixLength!);
  const expectedEnd = range.end === null ? total - 1 : Math.min(range.end, total - 1);
  if (start !== expectedStart || end !== expectedEnd) return null;
  const length = upstream.headers.get("content-length");
  if (length !== null && (!/^\d+$/.test(length) || Number(length) !== end - start + 1)) return null;
  return `bytes ${start}-${end}/${total}`;
}

export async function handleAttachmentRequest(
  request: Request,
  params: { memoId: string; attachmentId: string },
  ctx: AttachmentProxyContext,
): Promise<Response> {
  const method = request.method.toUpperCase();
  if (method !== "GET" && method !== "HEAD") {
    return new Response(null, { status: 405, headers: { allow: "GET, HEAD" } });
  }

  // 1. Authenticate first — nothing is resolved before the verified uid.
  let user: AttachmentProxyUser | null;
  try { user = await ctx.authenticate(); }
  catch { return jsonError(502, "Attachment unavailable"); }
  if (!user) return jsonError(401, "Unauthorized");

  // 2. Strict id validation (uniform not-found, no existence oracle).
  if (!UUID_RE.test(params.memoId) || !UUID_RE.test(params.attachmentId)) {
    return uniformNotFound();
  }

  // 3. Owned, non-tombstoned memo + exact attachment id (same memo/uid).
  let lookup;
  try {
    lookup = await ctx.store.getAttachmentForMemo({
      userId: user.id,
      memoId: params.memoId,
      attachmentId: params.attachmentId,
    });
  } catch { return jsonError(502, "Attachment unavailable"); }
  if (lookup.error) return jsonError(502, "Attachment unavailable");
  const attachment = lookup.rows;
  if (!attachment) return uniformNotFound();

  // 4. Owner-prefixed safe storage key from trusted DB metadata only.
  if (!isValidStorageKey(attachment.storage_key, user.id)) return uniformNotFound();

  const sizeBytes = sizeFromBytes(attachment.size_bytes);
  const range = parseRangeHeader(request.headers.get("range"), sizeBytes);
  if (range.kind === "invalid") {
    const headers = new Headers({
      "cache-control": "private, no-store",
      "x-content-type-options": "nosniff",
      "accept-ranges": "bytes",
    });
    if (sizeBytes !== null) headers.set("content-range", `bytes */${sizeBytes}`);
    return new Response(JSON.stringify({ error: "Requested range is not satisfiable" }), {
      status: 416,
      headers,
    });
  }

  // 5. Stream from the same configured project's private Storage. The route
  //    layer owns the URL/credentials and MUST use `redirect: "manual"`.
  let upstream: Response;
  try {
    upstream = await ctx.fetchObject({
      method,
      key: attachment.storage_key,
      range: range.kind === "single" ? range.headerValue : null,
      accessToken: user.accessToken,
      signal: request.signal,
    });
  } catch {
    return jsonError(502, "Attachment unavailable");
  }

  const fallbackName = `attachment-${attachment.id}`;
  const disposition = contentDisposition(attachment.mime_type, attachment.filename, fallbackName);

  if (upstream.status === 206) {
    const contentRange = validPartial(range, upstream, sizeBytes);
    if (!contentRange || (method === "GET" && !upstream.body)) {
      // Incomplete/foreign partial responses must fail closed, never stream.
      await discard(upstream);
      return jsonError(502, "Attachment unavailable");
    }
    if (method === "HEAD") await discard(upstream);
    return new Response(method === "HEAD" ? null : upstream.body, {
      status: 206,
      headers: buildResponseHeaders({
        mime: attachment.mime_type,
        upstream,
        disposition,
        sizeBytes,
        contentRange,
      }),
    });
  }

  if (upstream.status === 200) {
    if (method !== "HEAD" && !upstream.body) return jsonError(502, "Attachment unavailable");
    if (method === "HEAD") await discard(upstream);
    return new Response(method === "HEAD" ? null : upstream.body, {
      status: 200,
      headers: buildResponseHeaders({
        mime: attachment.mime_type,
        upstream,
        disposition,
        sizeBytes,
        contentRange: null,
      }),
    });
  }

  if (upstream.status === 416) {
    await discard(upstream);
    const headers = new Headers({
      "cache-control": "private, no-store",
      "x-content-type-options": "nosniff",
      "accept-ranges": "bytes",
    });
    if (sizeBytes !== null) headers.set("content-range", `bytes */${sizeBytes}`);
    return new Response(JSON.stringify({ error: "Requested range is not satisfiable" }), {
      status: 416,
      headers,
    });
  }

  // Redirects (3xx) and all other upstream states fail closed with a generic
  // message: no upstream bodies, tokens or object paths leak to the client.
  await discard(upstream);
  return jsonError(502, "Attachment unavailable");
}
