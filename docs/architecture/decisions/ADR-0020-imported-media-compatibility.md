# ADR-0020: Imported media compatibility (ADTS AAC and QuickTime MOV)

- **Status:** Accepted for the bounded media contract and server rollout after
  independent review; full product and per-platform acceptance remain separate.
- **Date:** 2026-10-16
- **Extends:** [ADR-0016](ADR-0016-revisioned-attachment-sync.md)
  (Accepted), which defines the v2 attachment-manifest and transfer contract.
- **Implementation issue:** [#884](https://github.com/getyak/daypage/issues/884)

## Context

Users have requested full import and same-account cross-platform sync of their
media. iOS capture and import already produce raw ADTS AAC audio (`.aac`) and
QuickTime MOV video (`.mov`) files, but the accepted ADR-0016 MIME set admits
only JPEG, PNG, HEIC/HEIF, M4A/MP4 audio, and PDF. Those two imported formats
therefore remain durable in the Vault but permanently "not cloud-synced", which
breaks the cross-platform promise for exactly the files users import.

ADR-0016 deliberately required "content-sniffing fixtures and a separate
review" before expanding the MIME set. This ADR is that review for the bounded
AAC/QuickTime slice. This bounded patch itself performs no remote writes,
database changes, releases, or real-data access. Backend selection, migration
application, cloud rollout, and deployment remain parent-owned and are tracked
by their own rollout receipts; this ADR makes no claim of completed deployment.

## Decision

Retain the original raw ADTS AAC and QuickTime MOV bytes unchanged through the
existing attachment-sync v2 contract. Bytes, object keys, canonical manifest
hash encoding, and raw Vault YAML are untouched; only the admitted type set and
its validation grow.

### 1. Settled kind/MIME/extension mapping

| kind | MIME type | extension | source |
| --- | --- | --- | --- |
| `photo` | `image/jpeg` | `jpg` | existing |
| `photo` | `image/png` | `png` | existing |
| `photo` | `image/heic` | `heic` | existing |
| `photo` | `image/heif` | `heif` | existing |
| `audio` | `audio/m4a` | `m4a` | existing |
| `audio` | `audio/mp4` | `mp4` | existing |
| `file` | `application/pdf` | `pdf` | existing |
| `audio` | `audio/aac` | `aac` | **new** |
| `file` | `video/quicktime` | `mov` | **new** |

AAC is always kind `audio` and QuickTime MOV is always kind `file`. MOV is
never a photo and AAC is never a file. The seven legacy mappings and all v1
behavior are preserved exactly. The v2 canonical manifest hash encoding and the
raw Vault YAML/Markdown contract are not modified.

### 2. Bounded content recognition, not extension matching

`AttachmentFileInspector` validates attachment bytes by content, not by trusting
the filename. For the two new types:

- **ADTS AAC (`audio/aac`):** within a bounded 64 KiB header window, the
  inspector walks ADTS frames and requires the 12-bit sync word, a zero layer,
  a sampling-frequency index in `0...12` (indexes 13 and 14 are reserved and
  15 is the escape value; all three are rejected, matching FFmpeg's ADTS
  header validation), frame lengths that are at least the header length and fit
  inside the real file size, consistent
  profile/sample-index/channel/protection headers across frames, and exact
  frame tiling for small files. Truncated files (declared frame length past
  EOF) and near-miss spoofs (for example a non-zero layer) fail closed.
- **QuickTime MOV (`video/quicktime`):** the leading ISO-BMFF box must be an
  `ftyp` box whose major brand is `qt  ` and whose compatible-brand entries
  explicitly include `qt  ` as required by Apple. Its atom length is checked uniformly
  across all three size forms: the effective atom size (the 32-bit size field,
  the 64-bit largesize when `size = 1`, or end-of-file when `size = 0`) must be
  at least the fixed field size (16 bytes for the standard and to-EOF forms,
  24 bytes for the largesize form), must not exceed the real file size, and
  must leave a multiple of 4 bytes after the fixed fields for the
  compatible-brand list (`(effective - fixed) % 4 == 0`). The 64-bit size is
  accumulated in `UInt64` before any `Int64` conversion. Unsupported brands
  such as `isom` fail closed.

**Explicit limitation:** these are signature and structure checks only. They
are deliberately *not* full codec decoding and make no claim that the audio or
video payload decodes correctly. Renamed files fail because the content check
for the mapped MIME type does not match the bytes, and wrong-kind submissions
fail before any byte is read.

### 3. One mapping across every surface

The settled mapping is expressed identically in:

- `packages/contracts/schemas/sync-push-v2.schema.json` — descriptor `oneOf`
  binds kind, MIME type, and object-key extension;
- `packages/contracts/schemas/attachment-upload-prepare-v2.schema.json` —
  preparation requests bind MIME type to canonical extension;
- `web/src/lib/schemas/attachment.ts` — the Web Zod `SignAttachmentSchema`
  binds kind to MIME type;
- Swift `AttachmentManifest.isStructurallyValid`, `AttachmentFileInspector`
  `mimeMapping`, and `validateMagic`;
- `public.daypage_attachment_extension` and the new database guard in
  `web/drizzle/migrations/0033_imported_media_compatibility.sql`.

The v2 pull page schema stays permissive on purpose: it serves historical rows
whose metadata predates any binding. Its descriptors are still bound by
`object_key` shape at write time.

### 4. Database compatibility (additive, in Drizzle history)

Migration `0033_imported_media_compatibility.sql` extends the repository-owned
backend functions in the Drizzle history after migration 0029. It is additive
and does not rewrite historical SQL:

1. `public.daypage_attachment_extension` gains `audio/aac -> aac` and
   `video/quicktime -> mov`; the seven legacy mappings are unchanged.
2. The private `memo-attachments` bucket's `allowed_mime_types` gains the two
   new types by append. The bucket's public flag, file size limit, RLS
   policies, grants, and existing upload reservations are untouched.
3. A small additive guard rejects wrong kind/MIME combinations for **newly
   verified** manifest rows: `memo_attachments_verified_kind_mime_check`, a
   `CHECK` constraint added `NOT VALID`. The v2 sync RPC validates kind and
   MIME independently today; the constraint rejects a wrong pairing at the
   verified-row insert (`daypage_apply_sync_operations_v2` records the
   rejection) while legacy unverified rows (`content_sha256 IS NULL`) remain
   fully compatible. A verified row with a NULL MIME type fails closed: the
   tuple comparison is `COALESCE`'d to `FALSE` so a NULL comparison result
   cannot slip past the CHECK. Being `NOT VALID`, it never scans, drops, or rewrites
   historical rows.

This slice does not create a parallel Supabase migration that would run before
0029 and later be overwritten; the repository's Drizzle history is the owning
migration path for these functions.

### 5. Staged rollout and rollback (both byte-preserving)

Rollout is staged and each stage is separately authorized and parent-owned:

1. **Contract and clients:** this patch (schemas, fixtures, Swift inspector,
   Web Zod, migration SQL, verification script, this ADR). No deployment.
2. **Migration:** apply `0033` on an isolated/staging database, run
   `web/scripts/verify-imported-media-compatibility.sql` (transaction-only),
   then production — all parent-authorized.
3. **Surfaces:** enable AAC/MOV import and sync per surface (Apple first, then
   web/Android as they land their media flows) so MIME compatibility is
   observable before it is relied on.

Rollback preserves every byte at every stage:

- Client rollback reverts accept-lists; Vault files and already-uploaded cloud
  objects stay intact and continue to sync as before for legacy types.
- Migration rollback deletes the two bucket MIME entries (append-only change),
  drops the `NOT VALID` constraint (which validated nothing), and optionally
  restores the previous function body. No row is rewritten or dropped, so raw
  bytes in Storage and the Vault survive rollback unchanged; at worst AAC/MOV
  return to the honest "media not cloud-synced" state of ADR-0016.

### 6. Read-only presentation of generated media-only placeholder bodies

The flomo importer emits a generated link body only when the original body was
empty: one line per attachment, in attachment order,
`[Photo attachment: ORIGINAL_FILENAME](raw/assets/flomo/SHA.ext)` (`Audio` for
kind `audio`, `File` for kind `file`). That body is internal plumbing — raw
asset paths alongside the rendered media rows — so read-only presentation
hides it, without touching any stored or wire representation:

- A pure Foundation helper (`MemoAttachmentPresentation.displayBody(for:)`)
  returns `memo.body` UNCHANGED unless the WHOLE trimmed body is exactly the
  generated placeholder set for ALL current attachments: same order, matching
  `Photo`/`Audio`/`File` label per kind, exact closing `](TARGET)` suffix with
  the strict original `raw/assets/flomo/<64 ASCII lowercase-hex>.<ext>` target
  (a supported importer extension for that kind), and a current
  `attachment.file` that is byte-identical to either that original target or
  to the production v2 download mapping
  `raw/assets/sync/<same SHA>-<String(name.prefix(255))>` — the deterministic
  `AttachmentTransferStore.localPath` shape, with 255 Swift-Character
  sanitization that is the identity on the accepted basename subset. All
  filename/path correspondence is UTF-8 byte equality (Swift canonical
  Unicode equivalence never equates two different filenames), and the hash is
  exactly 64 ASCII lowercase-hex bytes — grapheme look-alikes (for example
  `a`+U+FE0F) are not hashes. Only that exact case
  presents the empty display string. Prose, code/fences, wrong/missing/extra/
  duplicated/mismatched lines, wrong SHA/name/kind, loose hash prefixes,
  arbitrary suffixes, unsafe or non-canonical paths and any
  uncertainty preserve the body fully; there is no general Markdown stripping.
- It is wired only into read-only rendering (reading document source before
  transcript appending, detail read-only body, Mac row Markdown text). Editing,
  copy actions, exports, raw Vault YAML/Markdown and the sync wire format keep
  the original body byte-for-byte, and media rows always render.
- Search matching is untouched (raw body, fold, eligibility, order, caps). For
  output snippets only, `SearchIndex.MemoDocument` carries an optional
  presentation body (stored only when the presentation actually changed,
  `nil` = present the body) so neither search path prints generated paths; an
  empty placeholder snippet falls back to the existing localized type/badge
  copy in the UI.

## Consequences

- Imported AAC audio and QuickTime MOV video keep their original raw bytes end
  to end: Vault, upload, manifest, and cross-platform pull.
- Shared v2 schemas, Swift inspection, the Web validator and the server agree
  on kind/MIME/extension. Each platform still needs its own transfer and UI
  acceptance before claiming complete media sync.
- Spoofed, renamed, truncated, wrong-kind, and unsupported-brand inputs fail
  closed at inspection and at the contract layer.
- The compatibility claim is bounded to header structure validation rather
  than codec decoding. Environment deployment evidence and complete same-account
  import acceptance are tracked separately from this contract.
- Remaining work outside this slice: Android and web media flows, cloud
  rollout/ops, and host Swift integration testing are parent-owned.
- Presentation follow-up gates still unexecuted (parent-owned): full iOS/Mac
  SDK app builds and affected `DayPageTests`, Simulator/device UI verification
  of reading/detail/search/Settings flows on imported data, and VoiceOver
  passes. Local evidence for this slice is bounded to the hermetic Kit tests
  below plus syntax-only parsing; it is not an app build or UI acceptance.

## Verification (local, hermetic)

- `pnpm contracts:test` — schema/fixture conformance including the
  `imported-media-*` fixtures, manifest-hash binding, and the settled
  kind/MIME/extension matrix.
- `pnpm --filter daypage-web exec vitest run src/lib/schemas/__tests__/attachment.test.ts`
  — Web Zod binding, legacy mappings, and the unchanged 50 MB ceiling.
- `DayPageKit/Tests/DayPageStorageTests/AttachmentSyncTests.swift` — synthetic
  structurally consistent ADTS/QuickTime positives (including `size = 0` and
  `size = 1` QuickTime forms) plus spoofed, renamed, truncated, wrong-kind,
  unsupported-brand, reserved-sampling-index (13/14/15), and misaligned-atom
  negatives (run by the parent on
  the host; Swift package builds are outside the worker's authorization).
- `web/scripts/verify-imported-media-compatibility.sql` — transaction-only SQL
  verification of mapping, bucket invariants, grants/RLS, the `NOT VALID`
  guard, the settled matrix, wrong-kind and NULL-MIME rejection,
  legacy-row compatibility,
  and the unchanged canonical manifest hash. The parent runs this separately
  against an isolated database; the worker executes no DDL.

## References

- FFmpeg ADTS header parsing (sampling-frequency index validation):
  <https://www.ffmpeg.org/doxygen/8.1/adts__header_8c_source.html>
- FFmpeg MPEG-4 audio sample-rate table (indexes 0...12 are real rates):
  <https://www.ffmpeg.org/doxygen/8.1/mpeg4audio__sample__rates_8h_source.html>
- Apple QuickTime file type compatibility atom:
  <https://developer.apple.com/documentation/quicktime-file-format/file_type_compatibility_atom>
- Apple QuickTime atoms:
  <https://developer.apple.com/documentation/quicktime-file-format/atoms>
