# Web upload ownership index (local uploads)

Status: implemented for the local `uploads/` storage used by `POST /api/upload`;
live auth/API/security verification remains parent-owned. This document
describes the minimal private owner index that makes
`GET /uploads/[filename]` safe. Design provenance:
`reports/ios-experience-20261002/evidence/source27-web-upload-serving-design-review.md`
(user approval: private ownership index, unchanged image bytes/URL, legacy
files without owner metadata are denied).

## Problem

`POST /api/upload` writes blobs to `uploads/<randomUUID><ext>` and returns
`/uploads/<filename>` in its five-field response, but nothing recorded who
uploaded each file. Serving those files without owner metadata would either
expose private content to any authenticated account that learns a filename, or
require inferring ownership from `memo_attachments.storage_key` — which callers
can forge (the memos API accepts caller-supplied `storage_key` values), so a
memo join cannot prove upload ownership.

## Design: private v1 sidecar index

No database schema, migration, or dependency is added. Ownership is persisted
as private JSON sidecars next to the blobs:

```
uploads/<uuid><safe-ext>                  # blob, exact original bytes
uploads/.owners/<uuid><safe-ext>.json     # ownership record, never routable
```

Record format (version 1):

```json
{
  "version": 1,
  "filename": "0b7f...-....png",
  "owner_id": "<internal users.id UUID>",
  "size": 12345,
  "sha256": "<hex digest of the blob bytes>",
  "content_type": "image/png"
}
```

- `owner_id` is the internal `users.id` resolved server-side from the
  authenticated session email through `resolveUserId`. Request fields such as
  `owner_id`, `user_id`, `storage_key`, or `memo_id` are never trusted.
- `content_type` is the client-declared MIME, lowercased and stripped of
  parameters; control characters and malformed values collapse to
  `application/octet-stream`. It is recorded for audit only — delivery
  decisions are made from magic bytes, never from this value, the claimed MIME,
  or the file extension.

## Write path (`web/src/app/api/upload/route.ts`)

Existing POST behavior (auth gate, MIME allow-list, 10 MB limit, response shape
with `url`, `filename`, `original_filename`, `size`, `mime_type`) is preserved.
The filename is still a server-generated `randomUUID()` plus a safe extension
(`.<alnum 1-16>` from the client name; anything else is dropped).

`createOwnedUpload` in `web/src/lib/local-uploads.ts`:

1. Validates the owner UUID and enforces the 10 MB limit again.
2. Creates the blob exclusively (`O_CREAT | O_EXCL | O_NOFOLLOW`, mode `0600`),
   writes the exact bytes, and fsyncs the descriptor.
3. Creates the sidecar exclusively in `uploads/.owners/` (mode `0600`) and
   fsyncs it, then fsyncs both directories.
4. Only then does the route answer `201`. Any partial or crash failure fails
   closed (generic `500`) and attempts cleanup only when device/inode, size and SHA256 still prove that the path contains this call’s complete bytes. Partial or unproven files are retained and remain unreadable without a valid index.
   Older, unowned, or colliding paths are never deleted or rewritten
   (`O_EXCL` collisions leave the existing file untouched).
5. The uploads root and `uploads/.owners` must be real directories — symlinked
   roots and ancestor aliases are rejected before child creation. Directory creation is non-recursive, with canonical parent/root identity checks.

## Read path (`web/src/app/uploads/[filename]/route.ts`)

The GET route uses the same server-side auth and `resolveUserId` flow:

- Unauthenticated requests get `401`. Everything else — unknown profile, no
  ownership record, tampered record/bytes, symlink/hardlink/non-regular files,
  path mismatch, and legacy ownerless files — gets one uniform `404`, so
  filenames cannot be probed.
- The filename must match the strict canonical generated shape
  (`randomUUID()` basename + `.<alnum 1-16>`); traversal, dotfiles,
  `uploads/.owners` paths, and any other form are rejected before filesystem
  access. The ownership index is never exposed by any route.
- Reads open the sidecar and blob through file descriptors with `O_NOFOLLOW`,
  require regular files with a single link, enforce bounded sizes (sidecar
  ≤ 4 KiB, blob ≤ 10 MB), and verify the indexed size and SHA256 against the
  actual bytes read. The canonical parent, uploads root and ownership directory device/inode identities are captured and rechecked before critical opens and after reads. `O_NONBLOCK` ensures a FIFO cannot block before its non-regular type is rejected.
- Ownership comparison is against the trusted `users.id` only. Memo attachment
  `storage_key` values and joins are never consulted, so forging an attachment
  reference cannot grant access.
- There is no cached owner map; every request reads the disk index, so a
  process restart cannot serve stale ownership.

### Response hardening

The ordered `next.config.ts` `/uploads/:path*` header rule applies `Content-Security-Policy: sandbox` after the global page CSP, including raster and denial responses. This prevents the full Next HTTP pipeline from overwriting the attachment route’s sandbox policy. The rest of the site keeps its page policy.

Every response sets `Cache-Control: private, no-store`, `Vary: Cookie`, and
`X-Content-Type-Options: nosniff`. Bytes are classified by magic number only:

- Raster JPEG (`FF D8 FF`) and PNG (`89 50 4E 47 0D 0A 1A 0A`) are served
  inline as `image/jpeg` / `image/png`.
- Everything else — including SVG, HTML, text, other image formats, and any
  content whose bytes do not match a raster signature — is served as
  `application/octet-stream` with
  `Content-Disposition: attachment; filename="<generated canonical filename>"`
  and `Content-Security-Policy: sandbox`.

## Testing

- `web/src/lib/__tests__/local-uploads.test.ts` — real temporary-filesystem
  tests (under `TMPDIR`): byte-equality round trips, wrong owner, legacy
  ownerless files, exclusive blob/sidecar collisions, deterministically injected commit failure cleanup, actual changed-file/root preservation, FIFO denial,
  traversal/dotfile/index names, symlinked roots and blobs, hardlinks,
  non-regular files, digest/size/schema tampering, restart-style reload from
  disk, and magic-byte delivery classification.
- `web/src/app/api/upload/__tests__/route.test.ts` — mocked-auth POST tests for
  the preserved five-field contract, resolved-owner binding with forged
  ownership/attachment fields, and fail-closed storage errors without sensitive
  logging.
- `web/src/app/uploads/[filename]/__tests__/route.test.ts` — mocked-auth GET
  tests for 401/404 uniformity, forged-attachment non-ownership (with a DB
  mock that fails if consulted), traversal/index-path denial, and the inline
  vs forced-attachment response headers.

## Explicit limitations

- The sidecar is trusted server-side metadata, protected by directory/file
  permissions (`0700`/`0600`). An attacker who can already write inside
  `uploads/.owners/` is outside this threat model; content tampering is still
  detected via size/SHA256 binding.
- Cleanup uses pathname unlink after conservative identity/content checks, not atomic unlink-by-inode. Hostile concurrent filesystem writers are outside this guarantee; the canonical store and its ancestors must stay private to trusted server processes. No background orphan deletion is introduced.
- JPEG/PNG signature classification is not full image decoding; truncated signature fixtures test headers only. Live tests must use actual valid JPEG bytes.
- Files uploaded before this index existed have no owner record and are denied
  (`404`). No migration or ownership claim is performed.
- `/api/img/[memo_id]`, native v2 media sync, and hosted-environment behavior
  are out of scope. Actual local auth/API smoke tests, security review, and
  restart verification against a running server are parent-owned.
