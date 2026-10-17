# ADR-0026: Web imported-media placeholder presentation

- **Status:** Accepted
- **Date:** 2026-10-17
- **Extends:** [ADR-0022](ADR-0022-account-scoped-web-memo-reading.md)

## Context

The flomo importer (`scripts/import_flomo.py`) generates a memo body when the
original flomo memo had no text: one
`[Photo attachment: NAME](raw/assets/flomo/<sha256>.<ext>)` style line per
attachment, in attachment order (labels `Photo`/`Audio`/`File`; photo
`png/jpg/jpeg`, audio `m4a/aac`, file `mov`). On the web history and detail
pages that generated body rendered as duplication: a raw asset path line next
to the real attachment thumbnail and chips that already render from the
attachment rows.

The imported body is persisted data and must never be rewritten. The same
problem was already solved for the native surface by the shared read-only
helper `MemoAttachmentPresentation` (DayPageKit); the web needs the same
narrow, fail-closed display rule against the cloud attachment rows.

## Decision

### Narrow read-only presentation (display only)

A pure, server-side helper (`web/src/lib/memos/presentation.ts`) computes a
read-only display body from the raw body plus the memo's trusted, position
ordered `AttachmentRow`s and the verified owner user id and memo UUID. It
returns the **original body byte-identical for every uncertain case** and the
empty display body only when the WHOLE trimmed body is exactly one importer
placeholder line per ALL attachment rows, in order. There is no general
Markdown stripping, no persistence, and no query/schema/auth/storage change.

An `optional presentationBody` is added to the server `MemoListItem` and
`MemoDetail` DTOs **only when the presentation actually changed**. The raw
`body`/`memo.body` fields keep their exact bytes and remain the values for
search, counting, ordering, tags, keyset pagination, timestamps, attachment
serving and export. `storage_key` stays trusted server metadata and is never
exposed in a browser DTO.

### Exact, fail-closed matching

A line matches its row only when all of the following hold:

- exact ASCII label per trusted kind (`Photo`/`Audio`/`File`) and an
  importer-supported extension for that kind;
- strict target `raw/assets/flomo/<64 ASCII lowercase-hex>.<ext>` — the exact
  shape rejects variation-selector glyph hashes, alias spellings, traversal,
  query strings and remote/absolute targets;
- basename is nonempty with no path separators, no Unicode Cc/Cf controls and
  no edge whitespace, never normalized (canonical-equivalent byte-distinct
  spellings do not match), and conservatively preserved when above 255 UTF-8
  bytes — the web deliberately does not emulate the Swift grapheme truncation
  with a JS slice;
- the trusted row matches exactly: `filename` to the basename, `memo_id` to
  the memo UUID, contiguous `position` 0..N-1 in order, and `storage_key` to
  `<owner>/<memo>/<same sha>.<canonical ext>` — a JPEG original (`jpg` or
  `jpeg`) canonicalizes to the cloud `jpg` extension, nothing else;
- unknown, null, legacy or unsupported metadata always preserves the raw body.

### Rendering

- History renders `presentationBody ?? body`; the validated generated-only
  case shows a short "Media" fallback beside the existing thumbnail/chips
  instead of the hidden placeholder text.
- Detail skips the `MemoBody` block **only** for that validated hidden case —
  no "No content" filler is added there. Ordinary empty/prose/Markdown/code
  bodies render exactly as before.

## Consequences

- Imported media memos no longer show duplicated placeholder lines on web
  history/detail, while copy, export and the wire keep the original bytes.
- Any future placeholder format or attachment mapping change fails closed to
  the raw body until this rule is extended on purpose.
- The rule is presentation-only: read paths, RLS, storage, serving and the
  sync protocol are untouched. It uses existing account-scoped server metadata,
  introduces no private fixtures or absolute personal filesystem paths, and
  does not expose `storage_key` in browser DTOs.
