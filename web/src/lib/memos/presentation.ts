// Read-only presentation rules for memos whose body is ONLY the flomo
// importer's generated media placeholder set (ADR-0026).
//
// `scripts/import_flomo.py` emits one
// `[Photo attachment: NAME](raw/assets/flomo/<sha256>.<ext>)` style line per
// attachment, in attachment order, exactly when the original body was empty.
// That generated body renders as a raw asset path next to the real
// photo/audio/file rows, so this module hides it for display ONLY. It is pure
// and server-side: no queries, no persistence, no Markdown stripping. The raw
// body is returned byte-identical for EVERY uncertain case and stays the value
// for search, counting, export, copy and the wire.
//
// Everything is deliberately exact and fail-closed. A body is treated as the
// generated media-only placeholder set only when the WHOLE trimmed body is
// exactly one matching placeholder line per current attachment, in order,
// with the exact ASCII label/kind and the exact target correspondence below.
// Any prose, code/fence content, missing/wrong/extra/duplicated/mismatched
// line, unsafe or non-canonical path, or other uncertainty preserves the body
// unchanged.

import type { AttachmentRow } from "./types";

export interface ImportedMediaPresentationArgs {
  /** The ORIGINAL stored body (never modified). */
  body: string;
  /** All trusted attachment rows of this memo, in position order. */
  attachments: readonly AttachmentRow[];
  /** Verified owner user id (auth uid). */
  ownerUserId: string;
  /** Verified memo UUID. */
  memoId: string;
}

/** Labels used by the importer's generated link body (exact ASCII). */
const LABEL_BY_KIND = new Map<string, string>([
  ["photo", "Photo"],
  ["audio", "Audio"],
  ["file", "File"],
]);

/**
 * Importer-supported extensions per kind (`_EXT_KIND` in
 * `scripts/import_flomo.py`): png/jpeg/jpg are photos, m4a/aac audio, mov is
 * always a file — never a photo.
 */
const EXTENSIONS_BY_KIND = new Map<string, readonly string[]>([
  ["photo", ["png", "jpg", "jpeg"]],
  ["audio", ["m4a", "aac"]],
  ["file", ["mov"]],
]);

const TARGET_PREFIX = "raw/assets/flomo/";

/** Path separators plus Unicode Cc/Cf controls (and surrogate/line-separator
 *  uncertainty) are never accepted inside a basename. */
const UNSAFE_NAME_RE = /[/\\\p{Cc}\p{Cf}\p{Cs}\p{Zl}\p{Zp}]/u;

/** Exactly 64 ASCII UTF-8 hex bytes, lowercase only. Grapheme look-alikes
 *  (e.g. `a` + U+FE0F) fail because every character must be a hex digit. */
const SHA_RE = /^[0-9a-f]{64}$/;

/**
 * The read-only display body for a memo.
 *
 * Returns `body` UNCHANGED unless the whole trimmed body is exactly the
 * generated media-only placeholder set for ALL current attachments — only
 * that exact case yields the empty display string. Media rows are rendered by
 * their own views, so an empty display body never hides the attachments
 * themselves. The caller sets `presentationBody` ONLY when this differs from
 * the raw body.
 */
export function importedMediaDisplayBody(args: ImportedMediaPresentationArgs): string {
  const { body, attachments, ownerUserId, memoId } = args;
  if (attachments.length === 0) return body;
  const trimmed = body.trim();
  if (trimmed.length === 0) return body;
  const lines = trimmed.split("\n");
  if (lines.length !== attachments.length) return body;
  for (let index = 0; index < lines.length; index += 1) {
    if (!isGeneratedPlaceholderLine(lines[index], attachments[index], ownerUserId, memoId, index)) {
      return body;
    }
  }
  return "";
}

/**
 * One generated placeholder line for this exact trusted attachment row.
 *
 * Position must be exactly `index` (contiguous 0..N-1 in the given
 * position-ordered rows), `memo_id` the exact memo UUID, the parsed basename
 * byte-identical to `row.filename`, and the target the strict original
 * `raw/assets/flomo/<sha>.<ext>` whose SHA+canonical extension spell the
 * exact storage key `<owner>/<memo>/<sha>.<canonical ext>`. JPEG originals
 * (`jpg`/`jpeg`) are canonicalized to the cloud `.jpg` extension — nothing
 * else. Unknown/null/legacy/unsupported metadata never matches.
 */
function isGeneratedPlaceholderLine(
  line: string,
  row: AttachmentRow,
  ownerUserId: string,
  memoId: string,
  index: number,
): boolean {
  if (row.position !== index) return false;
  if (row.memo_id !== memoId) return false;
  const label = LABEL_BY_KIND.get(row.kind);
  const extensions = EXTENSIONS_BY_KIND.get(row.kind);
  if (!label || !extensions) return false;
  const parsed = parseGeneratedPlaceholderLine(line, label, extensions);
  if (!parsed) return false;
  // Exact bytes, no normalization: canonical-equivalent spellings differ.
  if (typeof row.filename !== "string" || row.filename !== parsed.name) return false;
  const canonicalExt = parsed.ext === "jpeg" ? "jpg" : parsed.ext;
  if (typeof row.storage_key !== "string") return false;
  return row.storage_key === `${ownerUserId}/${memoId}/${parsed.sha}.${canonicalExt}`;
}

interface GeneratedPlaceholderLine {
  /** Validated original basename (accepted bounded subset). */
  name: string;
  /** Exactly 64 ASCII lowercase hex characters. */
  sha: string;
  /** Original lowercase extension from the strict target. */
  ext: string;
}

/**
 * Parses one whole generated placeholder line: `[LABEL attachment: NAME](TARGET)`
 * with `TARGET` the strict original `raw/assets/flomo/<sha>.<ext>`. `null` for
 * anything uncertain: wrong label prefix, empty or unbounded basename,
 * non-canonical target, alias spellings, trailing text.
 */
function parseGeneratedPlaceholderLine(
  line: string,
  label: string,
  extensions: readonly string[],
): GeneratedPlaceholderLine | null {
  const prefix = `[${label} attachment: `;
  // Closing ")" plus at least one name character and one target character.
  if (line.length <= prefix.length + 2) return null;
  if (!line.startsWith(prefix)) return null;
  if (!line.endsWith(")")) return null;

  // The separator `](` is the LAST one in the line: the canonical target
  // after it contains no `](`, so a name may legitimately contain brackets.
  const separator = line.lastIndexOf("](");
  if (separator < prefix.length) return null;

  const name = line.slice(prefix.length, separator);
  const target = line.slice(separator + 2, line.length - 1);
  const parsedTarget = canonicalFlomoTarget(target, extensions);
  if (!parsedTarget) return null;
  if (!isBoundedOriginalFilename(name)) return null;
  return { name, sha: parsedTarget.sha, ext: parsedTarget.ext };
}

/**
 * Strict original target: `raw/assets/flomo/<64 ASCII lowercase-hex>.<ext>`
 * with an importer-supported extension for this exact kind. The exact shape
 * rejects traversal, absolute, remote, query-string, percent-decoded alias and
 * sync-mapped forms outright.
 */
function canonicalFlomoTarget(
  target: string,
  extensions: readonly string[],
): { sha: string; ext: string } | null {
  if (!target.startsWith(TARGET_PREFIX)) return null;
  const rest = target.slice(TARGET_PREFIX.length);
  // 64 hash characters plus "." plus at least one extension character.
  if (rest.length < 66) return null;
  const sha = rest.slice(0, 64);
  if (!SHA_RE.test(sha)) return null;
  if (rest[64] !== ".") return null;
  const ext = rest.slice(65);
  if (!extensions.includes(ext)) return null;
  return { sha, ext };
}

/**
 * Bounded acceptance for the original filename the importer preserved as link
 * text: a plain basename. Spaces, Unicode, parentheses and brackets are
 * legitimate filename characters and must match; path separators, Unicode
 * Cc/Cf controls and edge whitespace make the line uncertain. Names above 255
 * UTF-8 bytes are conservatively preserved: the web must not emulate the
 * Swift grapheme truncation with a JS slice. No normalization ever happens —
 * the returned check is on the exact input spelling.
 */
function isBoundedOriginalFilename(name: string): boolean {
  if (name.length === 0) return false;
  if (UNSAFE_NAME_RE.test(name)) return false;
  // Edge whitespace is rejected without canonical-equivalence leniency.
  if (name.trim() !== name) return false;
  return utf8ByteLength(name) <= 255;
}

/** Exact UTF-8 byte length (no normalization, no slicing). */
function utf8ByteLength(value: string): number {
  let bytes = 0;
  for (const character of value) {
    const codePoint = character.codePointAt(0) ?? 0;
    if (codePoint <= 0x7f) bytes += 1;
    else if (codePoint <= 0x7ff) bytes += 2;
    else if (codePoint <= 0xffff) bytes += 3;
    else bytes += 4;
  }
  return bytes;
}
