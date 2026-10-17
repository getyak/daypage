// Attachment presentation/protocol helpers.
//
// Kind/MIME preview decisions are bound to the nine supported pairs only
// (seven legacy pairs plus parent-reviewed `audio/aac` and `video/quicktime`).
// Anything else — unknown MIME, missing legacy metadata, mismatched kind —
// stays visible but unpreviewed with an honest unavailable/download state.
// This module never invents "verified" status.

import type { AttachmentKind } from "./types";

export type AttachmentPreview = "image" | "audio" | "video" | "file" | "unknown";

/** The nine supported (kind, mime) pairs. */
export const KIND_MIME_PAIRS: ReadonlyArray<readonly [AttachmentKind, string]> = [
  ["photo", "image/jpeg"],
  ["photo", "image/png"],
  ["photo", "image/heic"],
  ["photo", "image/heif"],
  ["audio", "audio/m4a"],
  ["audio", "audio/mp4"],
  ["audio", "audio/aac"],
  ["file", "application/pdf"],
  ["file", "video/quicktime"],
];

const PREVIEW_BY_MIME: Readonly<Record<string, AttachmentPreview>> = {
  "image/jpeg": "image",
  "image/png": "image",
  "image/heic": "image",
  "image/heif": "image",
  "audio/m4a": "audio",
  "audio/mp4": "audio",
  "audio/aac": "audio",
  "video/quicktime": "video",
  "application/pdf": "file",
};

/** Safe known image/audio/video MIME types that may be served inline. */
const INLINE_MIME_TYPES = new Set([
  "image/jpeg",
  "image/png",
  "image/heic",
  "image/heif",
  "audio/m4a",
  "audio/mp4",
  "audio/aac",
  "video/quicktime",
]);

const MIME_TOKEN_RE = /^[a-z0-9!#$&^_.+-]+\/[a-z0-9!#$&^_.+-]+$/;

export function classifyAttachment(
  kind: AttachmentKind,
  mimeType: string | null | undefined,
): AttachmentPreview {
  if (!mimeType) return "unknown";
  const pair = KIND_MIME_PAIRS.find(([k, m]) => k === kind && m === mimeType);
  return pair ? PREVIEW_BY_MIME[pair[1]] : "unknown";
}

/** Inline only for safe known image/audio/video MIME; everything else downloads. */
export function isInlinePreviewMime(mimeType: string | null | undefined): boolean {
  return typeof mimeType === "string" && INLINE_MIME_TYPES.has(mimeType);
}

/** Header-safe MIME or the opaque fallback. */
export function safeMimeOrOctetStream(mimeType: string | null | undefined): string {
  if (typeof mimeType === "string" && MIME_TOKEN_RE.test(mimeType)) return mimeType;
  return "application/octet-stream";
}

const CONTROL_RE = /[\u0000-\u001f\u007f]/;
const KEY_MAX_LENGTH = 512;

/**
 * Validate a trusted-DB storage key before it is used as an object path:
 *   - must be prefixed with the verified owner uid (matches the bucket's
 *     storage RLS on `(storage.foldername(name))[1]`);
 *   - no traversal (`.` / `..` segments), control characters, backslashes,
 *     query/fragment characters, or URL schemes;
 *   - bounded length.
 * Legacy rows that fail this check are rendered as honest "unavailable" —
 * they are never fetched and never rewritten.
 */
export function isValidStorageKey(key: string | null | undefined, userId: string): boolean {
  if (typeof key !== "string" || key.length === 0 || key.length > KEY_MAX_LENGTH) return false;
  if (!key.startsWith(`${userId}/`)) return false;
  if (CONTROL_RE.test(key)) return false;
  if (key.includes("\\") || key.includes("://") || key.includes("?") || key.includes("#")) return false;
  if (key.includes("%")) return false;
  const segments = key.split("/");
  if (segments.length < 2) return false;
  return segments.every((segment) => segment.length > 0 && segment !== "." && segment !== "..");
}

/** Percent-encode a validated storage key one path segment at a time. */
export function encodeStorageKeyPath(key: string): string {
  return key.split("/").map(encodeURIComponent).join("/");
}

/** Header-safe filename fallback (ASCII, no quotes/control chars). */
export function asciiFallbackFilename(
  filename: string | null | undefined,
  fallback: string,
): string {
  const source = (filename ?? "").replace(/[\r\n\u0000-\u001f\u007f]/g, "");
  const ascii = source
    .replace(/[\u0080-\uffff]/g, "_")
    .replace(/["\\]/g, "_")
    .trim();
  return ascii.length > 0 ? ascii.slice(0, 120) : fallback;
}

/** RFC 5987 `filename*` value: percent-encoded UTF-8, attr-char safe. */
export function rfc5987Filename(filename: string | null | undefined, fallback: string): string {
  const source = (filename ?? "").replace(/[\r\n\u0000-\u001f\u007f]/g, "").trim();
  const value = source.length > 0 ? source : fallback;
  return encodeURIComponent(value).replace(
    /['()!*]/g,
    (ch) => `%${ch.charCodeAt(0).toString(16).toUpperCase()}`,
  );
}

/**
 * Content-Disposition value: `inline` only for safe known image/audio/video
 * MIME; everything else downloads. Filenames are CRLF-safe in both the ASCII
 * fallback and the RFC 5987 form.
 */
export function contentDisposition(
  mimeType: string | null | undefined,
  filename: string | null | undefined,
  fallbackName: string,
): string {
  const disposition = isInlinePreviewMime(mimeType) ? "inline" : "attachment";
  const ascii = asciiFallbackFilename(filename, fallbackName);
  const extended = rfc5987Filename(filename, fallbackName);
  return `${disposition}; filename="${ascii}"; filename*=UTF-8''${extended}`;
}
