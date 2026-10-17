# ADR-0023: Account-scoped imported tag preservation

- **Status:** Accepted
- **Date:** 2026-10-16
- **Issue:** [#884](https://github.com/getyak/daypage/issues/884)
- **Extends:** [ADR-0016](ADR-0016-revisioned-attachment-sync.md) (receipt-gated import style)
- **Related:** [ADR-0010](ADR-0010-vault-derived-read-models.md)

## Context

Flomo imports carry a tag catalog and per-memo tag associations that must survive
under the authenticated DayPage account. Today tags only exist as hashtag text
inside memo bodies, which is wrong for three reasons: the body is the user's raw
content and must never be rewritten to "fix" tags, exact labels (nested
`#a/b/c`, comma-laden `#a, b`, arbitrary Unicode) can be destroyed by naive
normalization, and the full catalog includes labels unused by any memo that must
still be preserved. At the same time the import must be safe to repeat
(at-least-once transports), must never merge a changed payload into an existing
receipt, and must not turn imported tags into AI entities.

## Decision

### Exact persistence shape (additive; migration `0036_account_tag_imports.sql`)

```text
user_tags(user_id uuid -> users(id) ON DELETE cascade,
          label text COLLATE "C",
          in_import_catalog boolean NOT NULL DEFAULT false,
          PRIMARY KEY(user_id, label))

memo_tag_links(user_id uuid,
               memo_id uuid,
               label text COLLATE "C",
               PRIMARY KEY(user_id, memo_id, label),
               FK(user_id) -> users(id) ON DELETE cascade,
               FK(user_id, memo_id) -> memos(user_id, id) ON DELETE cascade,
               FK(user_id, label) -> user_tags(user_id, label) ON DELETE cascade,
               INDEX(user_id, label, memo_id))

memo_tag_imports(user_id uuid -> users(id) ON DELETE cascade,
                 source_sha256 text CHECK ~ '^[0-9a-f]{64}$',
                 payload_hash text CHECK ~ '^[0-9a-f]{64}$',
                 payload jsonb NOT NULL CHECK jsonb_typeof = 'object',
                 version integer NOT NULL DEFAULT 1 CHECK(version = 1),
                 created_at timestamptz NOT NULL DEFAULT now(),
                 PRIMARY KEY(user_id, source_sha256))
```

- `memos(user_id, id)` gains a unique index when absent so the composite
  ownership FK can reference it.
- Labels are **exact input**: original leading `#`, Unicode, case, punctuation,
  and `/` hierarchy are preserved byte-for-byte (`COLLATE "C"` keeps equality
  and ordering byte-exact). There is NO normalization, NO splitting on comma or
  slash, and NO invented parent labels. A label is `#` plus a non-empty suffix,
  at most 1024 UTF-8 bytes, with no ASCII controls/DEL (U+0000 can never reach
  a function through jsonb). Nothing else is restricted.
- Owner FKs cascade only with actual owner deletion; a hard-deleted memo
  cascades only its own links, and a soft-deleted memo keeps everything intact.
- `memo_tag_imports` rows are immutable: UPDATE is blocked by trigger for every
  role (including owners); only the RPC writes rows; owners have SELECT only.

### Immutable version-1 snapshot

`payload` is canonical metadata: `{version:1, catalog:[label...],
memos:[{memo_id, tags:[label...]}...]}`. It contains **no note body and no auth
state** (the strict schema makes other keys unrepresentable), preserves the full
input catalog including unused labels and the complete memo map including empty
tag arrays, and preserves array order. Duplicate label tokens inside one memo
may appear in the raw snapshot; they denote one association.

`payload_hash` is the server-side immutable-import fingerprint
`encode(sha256(convert_to(payload::text,'UTF8')),'hex')` over **PostgreSQL
`jsonb::text`**, stored as lowerhex text. It is deliberately NOT a portable wire
JSON digest: snapshot consumers store and compare it as opaque metadata and
must not guess a Swift/JS JSON serialization hash. Future cross-client
acceptance compares the full logical labels and per-memo associations against
the source manifest.

The row is read with the existing auth-scoped PostgREST path
`memo_tag_imports?select=version,source_sha256,payload_hash,payload,created_at`
(RLS: own rows only). The `version` column (CHECK = 1) matches the
`tag-import-snapshot-v1` contract schema directly; clients never guess or map a
version. `created_at` uses PostgREST's native timestamp output; the contract
schema accepts offsets and up to microsecond fractions without JS millisecond
truncation.

**Counts are historical.** Receipt counts and the snapshot describe that import
only; later tombstones never edit the payload or its counts, and a direct
snapshot SELECT does not hide deleted internal memo entries. Future active tag
display/filter/counts must separately join live memos.

### Import RPC `daypage_import_tags_v1(p_source_sha256 text, p_payload jsonb)`

Order of operations:

1. `auth.uid()` verified; missing uid fails closed (`42501 authentication
   required`). All failures are static generic strings - never raw labels or
   other-owner details.
2. Full read-only validation before any mutation: strict root/item keys and
   types, `version = 1`, UUIDs, label rules, duplicates (catalog entries and
   memo IDs), and limits: max 8 MiB canonical `jsonb::text`, 20000 catalog
   labels, 10000 memos, 200 labels per memo, 50000 total distinct
   (memo, label) links. (`22023 invalid tag import payload`.)
3. `payload_hash` computed server-side (never caller-provided).
4. Per-**account** transaction advisory lock
   (`pg_advisory_xact_lock(hashtextextended('daypage-tag-import:' || uid, 884))`)
   serializes first-time imports per account, so two sources sharing labels can
   never take row locks in reverse order.
5. Existing source receipt: identical payload replays the historical receipt
   (`status: replayed`) **before** any live-memo requirement; a changed payload
   is `23505 source payload conflict` with zero writes and is never silently
   absorbed.
6. First import: lock every referenced memo in sorted UUID order with
   `FOR SHARE` (FK key-share alone does not protect `deleted_at`), then require
   exact cardinality over owned + live (`deleted_at IS NULL`) rows atomically
   (`22023 import references unavailable memos` covers wrong-owner, tombstoned,
   missing, and mixed-ownership payloads). Then set-based writes only
   (jsonb expansion + `ON CONFLICT`), no per-label row lookups.
7. Writes: `user_tags` upserts with `in_import_catalog` OR-merging `true`
   (never downgrades; outside-catalog labels land `false`; unused catalog labels
   are retained); `memo_tag_links` inserts distinct associations with
   `ON CONFLICT DO NOTHING`; the receipt row stores the payload verbatim.
   Existing tags and links are never deleted by an import.

Result (version 1): `{version:1, source_sha256, status: imported|replayed, catalog_labels,
distinct_labels, memos, memberships}` where `catalog_labels` counts catalog
entries, `distinct_labels` counts distinct labels across catalog ∪ per-memo tags (including unused catalog labels; at most 70000), `memos`
counts memo map entries (including empty tag arrays), and `memberships` counts
distinct (memo_id, label) associations.

Replay is idempotent even after the user later tombstones or deletes a memo:
the historical receipt is returned and nothing is recreated or deleted. Tag
import writes only the three tag tables: memo body, `created_at`, and
`sync_revision` never change and no memo trigger fires. Imported tags NEVER
become AI entities - no entity derivation trigger or hook is attached to these
tables.

### Security posture

All three tables have RLS enabled with `FOR SELECT TO authenticated` own-row
policies; there are no write policies and no write grants, so clients cannot
INSERT/UPDATE/DELETE rows (RPC only). Default privileges are explicitly revoked
from `PUBLIC, anon, authenticated` on tables and functions before granting
authenticated SELECT / RPC EXECUTE (fresh Supabase projects grant function
EXECUTE by default). The RPC is `SECURITY DEFINER` (justified: atomic
multi-table integrity under a single transaction) owned by postgres with fixed
`search_path = pg_catalog`, no dynamic SQL, and explicit uid predicates on every
path. The label validator helper and the immutability trigger function are
revoked from every client role. Contract schemas/fixtures/tests live in
`packages/contracts` (`tag-import-*`) and are strict (closed objects, exact
types) with invalid fixtures for controls/DEL, unknown keys, wrong types,
oversize label/tags/catalog, UUIDs, duplicates, and snapshot timestamp forms.

## Backward compatibility

Additive only. Raw memo YAML/Markdown is untouched, existing hashtag body text
stays byte-for-byte identical, sync v2 payload schemas are unchanged, and no
existing table columns or behaviors change beyond the additive
`memos(user_id, id)` unique index. Snapshots are extra metadata rows; clients
that ignore them see no difference. Historical SQL migrations are untouched;
journal registration for `0036` is parent-owned alongside the additive
`0033-0035` integration this ADR does not modify. Existing native clients do
NOT read these snapshots yet - that is explicitly future work.

## Outstanding hooks (not claimed done here)

- Native snapshot download/apply: DELIVERED as a read-only derived projection
  in the native exact-tag batch — see
  [ADR-0025](ADR-0025-native-tag-projection-and-sync-completion.md). The
  native reader consumes only `user_tags`/`memo_tag_links` as current truth
  and `memo_tag_imports` source/hash rows as discovery markers; receipt
  payload bodies are never used as current truth. Local synthetic acceptance
  only; real-account/device/live verification remains a parent gate.
- Web exact-filter tag integration: delivered in the earlier Web reading
  batch (see the Web account-scoped reading ADR); any further Web history
  work is out of scope here.
- Active tag display/filter/counts joining live memos: DELIVERED natively
  (ADR-0025): membership is intersected with current raw UUIDs at read/display
  time, so unused catalogue labels persist while deleted notes never
  resurrect. Synthetic acceptance only; device/live gates stay parent-owned.

## Rollout and verification

1. Parent integrates `0036_account_tag_imports.sql` and registers it in the
   Drizzle journal (worker must not edit the journal).
2. `web/scripts/verify-account-tag-imports.sql` runs as BEGIN/ROLLBACK with two
   synthetic auth users and owned memos. It proves: complete catalog and
   association preservation (nested/comma/Unicode/unused/outside-catalog/
   zero-tags), stable memo body/created_at/sync_revision, replay idempotence and
   conflict rollback, wrong-owner/deleted/invalid/mixed-ownership memo rejection
   with no partial writes, direct row writes denied, owner read isolation, anon
   denial, function/default-privilege posture, fixed `search_path`, snapshot
   immutability, and historical counts surviving tombstones/hard deletes.
3. `packages/contracts/test/tag-import-contracts.test.mjs` runs standalone with
   the existing Ajv (no new dependencies).
4. **Not proven locally and left as parent gates:** the SQL script must run on
   staging (the worker must not run SQL remotely or against real data), and a
   two-connection rehearsal must exercise concurrent first-time imports;
   single-connection BEGIN/ROLLBACK cannot prove parallel advisory-lock
   behavior. If the two-connection rehearsal is not run, that gate stays
   unrun rather than passed.

## Rollback

Default rollback reverts the application read hooks and, if required, suspends
new import calls while preserving the three tables, snapshots, and composite
memo index. Tags are user data: unused catalog labels and body-external labels
may exist only in these tables and cannot be recovered from memo Markdown.

A schema removal requires a separately reviewed migration after exporting the
complete snapshots, catalog, and links to a private location, verifying their
hashes and row counts, and testing restoration. Removing these tables without
that recoverable export would destroy source metadata even though memo bodies
remain unchanged. No destructive rollback runs as part of this rollout.

## Rejected alternatives

- **Storing tags in memo bodies / YAML front matter:** rewrites raw user
  content, destroys exact labels, and violates the Vault-first invariant.
- **Normalizing or splitting labels** (comma/slash): loses the source meaning of
  `#a, b` and `#a/b/c`; exact labels plus optional future derived indexes are
  strictly safer.
- **Caller-provided payload hash:** unverifiable; the fingerprint must be a
  server-side computation over a server-known canonical form.
- **Per-source locking only:** two sources importing shared labels could take
  row locks in reverse order and deadlock; per-account serialization is the
  cheap fix for the current dataset size (~5000 memos / ~2300 links per
  account).
- **A privileged read view for snapshots:** the `version` column makes a plain
  RLS-scoped PostgREST SELECT match the contract schema with no privileged
  object and no client-side version guessing.
