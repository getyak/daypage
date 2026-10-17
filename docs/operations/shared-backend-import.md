# Shared backend private import (issue #884)

Operator runbook for `scripts/shared_backend_import.py`, the one-shot CLI that
imports a **prevalidated** native DayPage flomo operation export into the shared
Supabase backend, with private media and exact imported tags.

Architecture is settled by ADR0016 / ADR0020 / ADR0023 and issue #884. This
tool is deliberately narrow: it is not an SDK and adds no new product surface.

Owned files: `scripts/shared_backend_import.py`,
`scripts/tests/test_shared_backend_import.py`,
`docs/operations/shared-backend-import.md`. Python standard library only.

## Safety model

- **Offline dry-run is the default.** Without `--execute` the tool performs
  zero network requests, makes no session refresh, and only validates inputs,
  hashes the Vault media bytes, and writes a safe aggregate receipt. A dry-run
  validates session shape only; it does not certify a live authenticated
  session (JWT claim and server identity checks run in `--execute` before the
  first mutation).
- **`--execute` is an explicit operator action.** The delegated tooling never
  runs it; only the parent operator does, first against a public synthetic
  fixture and only later against the authorized private export.
- **Output discipline.** stdout is a single JSON line with aggregate
  counts/hashes or one static error code. Never note bodies, tag labels,
  filenames, user IDs, URLs, HTTP packets, credentials, or tracebacks. The
  checkpoint and receipt never contain passwords or access tokens.
- **Private media.** Attachments live only in the private `memo-attachments`
  bucket under `user_id/memo_id/sha256.ext`. Every object is byte-proven by a
  size-bounded buffered GET + SHA-256 before its memo commit and again in a
  full final readback. A saved checkpoint uploaded/verified flag never proves
  current bytes; proof is always the live GET. No signed public URLs are ever
  produced.
- **Exact tags.** Labels keep their leading `#`, Unicode, case, punctuation and
  slash/comma bytes exactly; nothing is split, normalized or deduplicated.

## Inputs

All paths below are placeholders. Files marked private must be mode `0600`.

| Flag | Contents |
| --- | --- |
| `--config` | private JSON `{project_id, url, publishable_key}`. `project_id` is exactly 20 lowercase ASCII letters; `url` must equal `https://<project_id>.supabase.co` exactly; `publishable_key` must be a modern `sb_publishable_…` key or a legacy JWT key whose decoded role is `anon` (decode-only gate, not signature proof); `sb_secret_` and service-role keys are refused. |
| `--owner` | JSON `{project_id, user_id, email, email_confirmed: true, profile_matches_auth: true}`. |
| `--session` | private GoTrue session JSON. Required keys: `access_token`, `refresh_token`, `user`, `expires_at`; safe extras (`expires_in`, `token_type`, `weak_password`) are accepted and preserved across refreshes. |
| `--operations` | operation export v1: `{version: 1, format: "daypage-private-import-operations", project_id, user_id, source_zip_sha256, records: [{operation, local_files, body_sha256}]}`. Operations are sent to the server verbatim; nothing is normalized, re-timed, re-revisioned or re-identified. |
| `--preflight-receipt` | the parent's independent preflight receipt. Core fields (`result: "passed"`, `export_sha256`, `memos`, `attachments`, `attachment_bytes`, `native_and_javascript_manifest_hashes_agree: true`, `all_operations_conform_to_current_v2_schema: true`) are verified and bound to the exact export bytes and counts; safe extra metadata is tolerated and never rewritten. |
| `--vault` | Vault root. Native `local_files` paths use `raw/assets/...` relative to the Vault; the raw-relative `assets/...` operator format is also accepted. Both resolve strictly inside `<vault>/raw`. |
| `--tags` | canonical tag import payload v1 (`{version: 1, catalog, memos}`). Its memo ID set must equal the import memo set exactly. |
| `--checkpoint` | private resumable state (created/updated by the tool, mode `0600`). |
| `--receipt` | safe aggregate report (created/updated by the tool). |
| `--execute` | perform the real import; absent means offline dry-run. |

Input JSON must not contain duplicate object keys, and every input size is
bounded (fail closed). `--checkpoint` and `--receipt` must not alias any input
or each other (including via hardlinks) and must not be symlinks; the same
guard protects `--session`, which the tool may rewrite on refresh. A checkpoint
lock file enforces a single writer.

## Invocation

Offline dry-run (safe; no network, no `--execute`):

```sh
python3 scripts/shared_backend_import.py \
  --config /path/to/inputs/config.json \
  --owner /path/to/inputs/owner.json \
  --session /path/to/private/session.json \
  --operations /path/to/inputs/operations.json \
  --preflight-receipt /path/to/inputs/preflight-receipt.json \
  --vault /path/to/vault \
  --tags /path/to/inputs/tags.json \
  --checkpoint /path/to/private/checkpoint.json \
  --receipt /path/to/out/receipt.json
```

Real import (parent/operator only; add the flag):

```sh
python3 scripts/shared_backend_import.py \
  --config /path/to/inputs/config.json \
  --owner /path/to/inputs/owner.json \
  --session /path/to/private/session.json \
  --operations /path/to/inputs/operations.json \
  --preflight-receipt /path/to/inputs/preflight-receipt.json \
  --vault /path/to/vault \
  --tags /path/to/inputs/tags.json \
  --checkpoint /path/to/private/checkpoint.json \
  --receipt /path/to/out/receipt.json \
  --execute
```

Exit codes: `0` success (`dry_run` or `passed` report), `2` static error code
reported in stdout, `3` internal failure (also static code only).

## What `--execute` does

1. **Offline validation** (also done by dry-run): config/owner/session shapes,
   export schema and identity fields, unique operation/memo IDs,
   SHA fields, `body_sha256`, canonical attachment manifest hash (byte-exact
   port of `packages/contracts/manifest-hash.mjs`, pinned by independent JS
   goldens in tests), descriptor key format `user/memo/sha.ext` with the nine
   canonical MIME/extension pairs (AAC and MOV included), `local_files`
   count/order, and the actual bytes (SHA-256 + size) of every local file
   strictly inside `<vault>/raw` (no absolute/`..`/symlink escapes). Native
   Vault-relative `raw/` is removed only after the original segments pass
   validation; exported operations and local-file strings remain unchanged. The
   preflight receipt is bound to the exact export bytes and counts. JWT claims
   (`iss = <origin>/auth/v1`, `sub = owner`, `role = authenticated`, finite
   valid `exp`) are checked in `--execute` before any request.
2. **Identity proof.** `GET /auth/v1/user` must confirm the owner ID, email and
   confirmed email before the first mutation, and again after every refresh.
   JWT decoding alone is never treated as authentication. An expired token
   triggers one ordinary refresh (`POST /auth/v1/token?grant_type=refresh_token`)
   whose result is fully re-validated and saved atomically only to the same
   private session file.
3. **Media.** Per media memo: reserve via
   `/rest/v1/rpc/daypage_prepare_attachment_upload` (returned `object_key`,
   `reservation_id`, `expires_at`, `already_exists` are strictly verified),
   throttled to at most ~55 new reservations/minute and never reserving all
   objects at once. The reservation is re-prepared on every run (idempotently)
   so a resumed object always has a live/refreshed reservation before commit.
   Objects ≤ 6 MiB upload with
   `POST /storage/v1/object/memo-attachments/{key}` (`x-upsert: false`);
   conflicts/existing objects require real GET byte verification. Larger
   objects use TUS (`POST /storage/v1/upload/resumable/`, 6 MiB chunks,
   `Tus-Resumable: 1.0.0`, `Upload-Metadata` base64 `bucketName/objectName/
   contentType/cacheControl3600`, `x-upsert: false`). The `Location` header and
   any saved resume URL must be absolute same-origin under
   `/storage/v1/upload/resumable/` before a bearer token is sent. HEAD offsets
   are authoritative and `Upload-Length` must match exactly; an ambiguous PATCH
   is resolved by HEAD before any resend (with bounded Retry-After/backoff
   before a no-progress resend); unexpected offsets/lengths abort; 404/410
   restarts the upload safely.
4. **Byte proof before commit.** Every descriptor of a media memo — including
   resumed checkpoint entries and pre-existing objects — is fetched via
   `GET /storage/v1/object/authenticated/memo-attachments/{key}` with
   `Accept-Encoding: identity` into a size-bounded buffer and hashed
   (length + SHA-256) before that memo is committed. This re-verifies, not
   trusts, any earlier upload state.
5. **Commit.** `POST /rest/v1/rpc/daypage_apply_sync_operations_v2` in small
   batches (~20 text-only operations; one media memo promptly). Every operation
   must return an exact accepted receipt (`status: "applied"`, matching
   `operation_id`, `memo_id`, `revision`, `attachment_manifest_hash`, and a
   `remote_revision` that does not indicate conflict). Any rejected/stale/
   missing/duplicate/extra receipt aborts. Re-sending the same `operation_id`
   after an ambiguous network failure is idempotent.
6. **Tags.** After all memos are acknowledged:
   `POST /rest/v1/rpc/daypage_import_tags_v1` with
   `p_source_sha256 = operations.source_zip_sha256` and `p_payload` = the exact
   `--tags` JSON. The result counts (catalog, distinct labels including unused,
   memos, distinct memberships) must match local computation exactly; status
   must be `imported` or `replayed`. The snapshot
   `GET /rest/v1/memo_tag_imports?select=version,source_sha256,payload_hash,payload,created_at&source_sha256=eq.<sha>`
   must contain the exact payload; `payload_hash` is checked as an opaque
   64-hex fingerprint only (it is not a portable digest).
7. **Full readback.** `POST /rest/v1/rpc/daypage_pull_sync_changes_v2` from
   `p_after_sequence: 0` with strict cursor progression (duplicate IDs or
   sequences, unsorted or oversized pages, and non-canonical/jumped/backward
   cursors abort). Every imported memo must be
   present, not tombstoned, and match body SHA, exact `created_at` instant
   (timezone-normalized integer microseconds), `type`,
   `content_hash`, revision, manifest hash and the full ordered attachment
   descriptors. Additional pre-existing owner memos are allowed and preserved.
   Then **all** attachments are downloaded and hashed again as the final
   independent byte proof, and only then is the exact tag snapshot re-checked.

Only after the complete readback does the receipt get `result: "passed"`.

## Resumability and idempotency

The checkpoint binds `project_id`, owner user UUID, export SHA-256, tag payload
SHA-256 and source ZIP SHA-256; any mismatch refuses to run. It records
per-object upload state, in-flight TUS URL+offset, and acknowledged
`operation_id`s (never tokens or user content). Updates are durable atomic
replaces with fsync. On rerun, checkpointed uploads are only upload skip hints:
the reservation is re-prepared and every object's bytes are re-proven by GET
before its memo commits (a missing object is re-uploaded under the same
immutable key; corrupt bytes abort). Acknowledged operations are not re-sent,
while the full readback, final media hash proof and tag snapshot verification
always re-run — the checkpoint alone is never trusted for final success. A
completed receipt for a different export is never overwritten; a completed
receipt for the same export is reverified before being rewritten. The export
and the Vault are never mutated; there is no destructive cleanup and no account
rebinding. Mutable outputs (`--session`, `--checkpoint`, its lock, `--receipt`)
must live outside the Vault and must not path- or hardlink-alias any validated
input asset; violations refuse before any write, lock or network access.

## Network policy

- Exactly `https://<project_id>.supabase.co`; userinfo, explicit ports, path
  escapes, query/fragment mismatches and redirects are refused.
- Bounded retries for transient network errors, 408/429/5xx with bounded
  `Retry-After` (≤ 60 s); 401 gets one refresh then one retry; any
  non-transient policy/validation rejection aborts without success.
- Request/response sizes are bounded; no admin or service key is accepted.

## Output

stdout (and the receipt) carries aggregate data only, for example:

```json
{"result":"passed","project_id":"<project>","export_sha256":"<sha256>","source_zip_sha256":"<sha256>","tag_payload_sha256":"<sha256>","memos":0,"attachments":0,"attachment_bytes":0,"tag_catalog_labels":0,"tag_distinct_labels":0,"tag_memos":0,"tag_memberships":0,"imported_memos":0,"imported_attachments":0,"imported_attachment_bytes":0,"tag_status":"imported","manifest_hash_verified":true,"media_reverified":true,"tag_snapshot_verified":true,"readback_verified":true}
```

Failures print `{"result":"failed","error_code":"E_<CODE>"}` with a static code.
Codes cover input shape/mode/size (`E_INPUT_*`, `E_JSON*`, `E_*_SHAPE`),
binding (`E_PREFLIGHT_BIND`, `E_CHECKPOINT_BIND`, `E_BODY_HASH`,
`E_MANIFEST_HASH`, `E_FILE_HASH`), path safety (`E_FILE_PATH`, `E_FILE_SYMLINK`,
`E_FILE_ESCAPE`, `E_OUTPUT_ALIAS`), identity (`E_AUTH_JWT`, `E_AUTH_IDENTITY`,
`E_AUTH_UNCONFIRMED`, `E_AUTH_REFRESH`), transport (`E_ORIGIN`, `E_REDIRECT`,
`E_TUS_LOCATION`, `E_TUS_OFFSET`, `E_TUS_STATE`, `E_NETWORK`,
`E_RETRY_EXHAUSTED`), execution receipts (`E_RESERVATION`, `E_UPLOAD_FAILED`,
`E_MEDIA_HASH`, `E_COMMIT_RECEIPT`, `E_COMMIT_CONFLICT`, `E_PULL_*`,
`E_TAG_*`) and `E_RECEIPT_CONFLICT` / `E_INTERNAL`. Static codes are the
contract with the parent's acceptance harness; treat the list as closed.

## Tests

```sh
python3 -m unittest discover -s scripts/tests -p 'test_shared_backend_import.py'
```

Fully synthetic and offline: a scripted fake transport covers the happy path
(including AAC/MOV media and TUS), dry-run-without-network, JWT/identity
mismatches, tampered export/assets, traversal, symlinks, FIFO substitution,
hardlink temp regressions, output aliasing (Vault/nested/hardlink/asset
destinations), checkpoint binding, preflight
malformation/staleness, idempotent reruns, 429 throttling, bounded retries,
safe TUS resume (zero/intermediate offsets)/ambiguous PATCH/host-escape
rejection, TUS `Upload-Length` contract and Retry-After pacing, precommit
GET-before-commit ordering (fresh, resumed and corrupt-object cases), malformed/
missing/stale/duplicate/extra commit acknowledgements, exact
`created_at` microsecond comparison, publishable-key policy, non-finite
NaN/Infinity numerics, strict project refs, pull cursor canonical binding and
readback mismatches, and tag unused/comma/Unicode fidelity. All four JSON RPC
families and the refresh packet are revalidated with real urllib request
preprocessing (explicit `application/json`) and binary media/TUS content types
are pinned. Manifest-hash correctness is asserted against independent
JavaScript goldens generated from `packages/contracts/manifest-hash.mjs` (never
a mirrored Python algorithm). Clock, sleeper and transport are injected, so the
suite is deterministic and fast.

## Known limitations

- The optional paginated catalog/links readback (beyond the exact snapshot) is
  not implemented; the exact snapshot plus import result counts are verified.
- Client-side JWT signature verification is impossible by design (no key); the
  mandatory server identity check plus claim binding is the compensating
  control.
