# ADR-0025: Native account-tag projection and truthful sync completion

- Status: Accepted (implemented in `DayPageKit` + Apple hosts; real
  login/devices/live backend acceptance remain parent-owned gates)
- Date: 2026-10-16
- Issue: #884 (native exact-tag reading + sync completion + Mac reading batch)
- Extends: [ADR-0023](ADR-0023-account-tag-imports.md) (import side),
  [ADR-0024](ADR-0024-account-origin-session-binding.md) (realm/session
  isolation), [ADR-0016] (revisioned attachment sync)

## Context

The account tag tables introduced by 0036 (`user_tags`, `memo_tag_links`,
`memo_tag_imports`) were import-side only: native clients could not READ exact
labels, body hashtags were silently treated as tag substitutes, and "已同步"
was claimed whenever the local outbox looked empty — even when metadata was
unverified, media obligations were still open, or the claim belonged to an
older session generation. The Mac Archive only listed raw file names and could
not open a note's body, tags or media at all.

Constraints that shaped this decision:

- Raw memo files and sync payloads must not grow a `tags` field; imported tags
  are account-scoped and must never rewrite canonical raw/YAML bytes.
- The receipt payload is HISTORICAL import metadata; it is not current truth
  and must never be downloaded as such.
- `memo_tag_imports.source_sha256` is not a commit-monotonic sequence: two
  paged marker scans alone can both miss a source inserted before an
  already-passed cursor.
- A previous real deadlock taught that notifications must not fire while
  storage locks/gates are held.

## Decision

### 1. `ExactTagLabel` — exact UTF-8 identity

Labels keep their original text verbatim (leading `#`, case, commas, slashes,
spaces, all Unicode). Equality, hashing and ordering are defined over the
exact UTF-8 bytes, so canonical-equivalent Swift `String` spellings remain
DISTINCT labels. Validation mirrors 0036: leading `#`, 2…1024 UTF-8 bytes, no
ASCII control (U+0000…U+001F) or U+007F. No trimming, normalization, case
folding, comma/slash splitting or invented parents. The stable UI identity is
the lowercase hex of the bytes — never the `String` value — so SwiftUI
selection/diffing cannot merge equivalent spellings.

### 2. Derived cache: `AccountTagProjectionStore`

- One rebuildable, realm-bound, versioned derived file:
  `vault/_agent/sync/account-tags-v1.json`, holding
  `schema_version + normalized_origin + owner_uuid + receipt_count +
  catalogue + links + opaque source/hash markers + fetched_at`.
- It is the ONLY write of a tag refresh. Raw/YAML, the durable outbox, account
  state and pull cursors are never mutated as a tag side effect.
- Reads return a complete validated snapshot or a typed unavailable/stale
  error (`missing`/`foreign`/`corrupt`/`staleVersion`) — never an
  empty-success that would hide real labels. Wrong-realm, corrupt and
  interrupted caches preserve the previous bytes.
- Cache paths reject metadata symlinks FAIL-CLOSED: `_agent`, `_agent/sync`
  and the cache file must be real entries. Any symlink at those positions is
  `foreign` — including a one-hop in-Vault alias that chains to the outside,
  a dangling target and a self-loop (one-hop resolution cannot prove those
  safe). Foundation's `resolvingSymlinksInPath` is not trusted here: it
  leaves missing leaves unresolved and rewrites `/private` prefixes.
- Install is atomic, requires a NON-OPTIONAL current session generation lease
  (the capability is never manufactured), and runs inside that lease gate
  plus the store lock; the update notification fires only AFTER both are
  released.

### 3. Reader + consistency boundary

- `SupabaseAccountTagsReader` reuses the same verified session
  (`session.tokens.verifiedToken` + `SyncSessionNetwork`); GET-only, no RPC
  writes, no Storage access, no second auth/config installer. EVERY request —
  the exact-count probe included — carries the same proven bearer. It is
  exposed as an optional `RemotePuller.accountTagsReader` capability (default
  `nil`), so the Auth/session installers stay untouched. `nil` means METADATA
  UNAVAILABLE — never a complete empty catalogue.
- Complete keyset reads at 500 rows/page over `user_tags`, `memo_tag_links`
  (composite `memo_id,label` cursor) and `memo_tag_imports` markers
  (`user_id,source_sha256,payload_hash,version` only — payload bodies are
  never fetched). Strict advancing/order/dedup/owner row validation; a full
  final page must be followed by the request that proves the end. Local page
  budgets yield typed `budgetExceeded` (incomplete) — never a silent
  truncation at the per-import RPC limits (20k/10k/50k), because cumulative
  sources can exceed them. No per-memo N+1 and no giant `uuid.in.` URLs.
- Query values are percent-encoded exactly once with unreserved-only UTF-8
  (`+` → `%2B`, `%` → `%25`, `#` → `%23`, `&` → `%26`, space → `%20`); nested
  `or=(…)` literals escape quotes/backslashes at the UNICODE SCALAR level
  (grapheme clustering can fuse an ASCII quote with a following combining
  mark) and are quoted, top-level `gt` cursors stay raw. Wire types are
  decoded strictly (`Decodable`, not NSNumber casts): `version: true` and
  `in_import_catalog: 1` fail the round instead of coercing.
- **Full read** wraps the complete markers/catalogue/links download between
  two INDEPENDENT owner-scoped exact receipt counts
  (`GET Range: 0-0` + `Prefer: count=exact`; an absent/estimated total is not
  proof). Only `C0 == C1 == marker cardinality` with every row/FK check passed
  may install; observed changes retry boundedly and otherwise leave the
  previous cache untouched.

### 4. What the consistency claim is — and is not

- **Provable under current canonical writes**: RLS + explicit owner filters +
  per-row owner checks + the verified session/lease keep requests and cache in
  one (origin, user) realm; metadata is read COMPLETELY from the current
  `user_tags`/`memo_tag_links` (unused catalogue labels included).
- **Provable under the append-only receipt assumption**: with the 0036 import
  RPC as the only client write path (one transaction: OR-merge live tags,
  insert links, append one immutable receipt; authenticated roles hold
  SELECT-only grants and the update trigger rejects rewrites), an unchanged
  exact receipt count across the full download proves no NEW successful source
  import inside the interval.
- **NOT proven by paged-marker equality alone**: a source hash is not a commit
  order; a source committed after a cursor was passed can be missed by both
  paged scans. The exact-count wrap is what closes that window.
- **NOT an atomic raw+tags snapshot**: memo feed and tag SELECTs are separate
  requests; hard deletes cascade links without receipts. Views therefore
  intersect membership with current raw UUIDs at read/display time: deleted
  notes never resurrect from the cache and a conflict-copy UUID never inherits
  the original's memberships. No raw+tags single-snapshot claim is made.
- **Bounded eventual refresh, not strong live truth**: admin writes, receipt
  deletion/replacement or future tag writers can bypass markers. Periodic
  passes do a cheap count+marker probe and reuse a matched complete cache;
  `initial`/`manual` always force a full read; a decreasing count or rewritten
  markers keep the old cache and report inconsistency. Cross-writer linear
  consistency would require an extra atomic snapshot/revision API (not in this
  batch).

### 5. Sync refresh reasons and completion health

- `SyncRefreshReason` (`initial`/`manual`/`periodic`/`online`/`automatic`)
  rides every flush request. Busy/offline `manual`/`initial` demands are
  coalesced and replayed once — never swallowed by the busy early-return;
  routine triggers are covered by the running pass. A fresh session generation
  forces the first metadata read to be full; page-bound yields preserve the
  force-full demand for the follow-up pass.
- Order per pass is unchanged: push → raw pull (existing 250-page scheduling
  valve with yield/reschedule, no truncation) → account-tag metadata →
  completion. A metadata failure preserves raw/cursor progress and the
  previous cache: no rollback, no replayed operation IDs.
- `AttachmentTransferStore.progress(realm:)` is a throwing, realm-scoped,
  UNBOUNDED count of upload/download obligations grouped by status plus blocked
  upload-preparation records. There is no 50/200 cap and no `try?`-returns-zero
  path: foreign/unproven/corrupt sidecars report UNKNOWN health instead of a
  fake verified zero.
- `SyncCompletionPresentation` (shared Kit) is the single source for product
  copy: "已同步/Synced" only when the CURRENT generation recorded true
  completion — memo feed drained, metadata current, durable outbox empty and
  every verified media obligation finished. Unknown/failed/pending/paused/
  unsupported/blocked never claim synced. Session clear/install or any new
  local work voids the current proof; `lastSuccessAt` stays history and is
  never evidence for a new session. `recordSyncSuccess` is only reachable from
  the true-completion gate (plus the pristine legacy bridge).

### 6. Reading surfaces (iOS + Mac)

- Search runs the exact metadata membership filter BEFORE the 100-result cap
  in both file and index overloads; an empty keyword is valid with a tag
  filter; date rows never bypass an active tag filter; body hashtags/entities
  never substitute for metadata. The tag selector is compact, searchable and
  collapsible over the FULL catalogue (unused labels included, active counts
  over live raw UUIDs) and unavailable metadata is presented distinctly from
  zero matching notes.
- Detail shows original labels as exact chips; Today/detail re-render on raw,
  projection and media changes (projection/media notifications are read-only
  triggers).
- Mac Archive (existing `MacRootView`) selects natural days, lists the owning
  day's memos and opens a read-only detail: ORIGINAL full body
  selectable/copyable, exact tags, and media through
  `AttachmentFileInspector.safeLocalURL` with EXPLICIT user opening only —
  no traversal/foreign-symlink/remote URLs, no automatic playback or ASR.
  Routing is always `(memo UUID, owning day file)`; `created`/timezone never
  retarget the lookup, and deleted memos become unavailable. Row components
  are reused from `MacTodayView` (no new target files).

## Consequences

- A tag refresh is exactly one derived-file write; raw, outbox, account state
  and cursors are byte-stable across refresh, filter, detail and media reads.
- Offline, a previously installed matched-realm cache keeps reading with its
  fetch time shown as age; a missing/damaged cache degrades to "unavailable",
  never to "no tags".
- Accounts with huge cumulative tag history exceed local page budgets
  honestly: the pass stays incomplete and the previous cache remains, instead
  of installing a truncated projection.
- Full completion health needs the account-tag capability; pullers without it
  (`nil`) can never display synced (their metadata is unavailable). Test
  fakes must explicitly inject a complete empty account where that is the
  intended fixture.
- Live device/account verification (real login, multi-device, large-account
  timing) and backend/admin behavior remain parent-owned gates; this ADR
  claims only local synthetic acceptance (`T01…T20` fixtures under isolated
  test vaults).

## Compatibility

- Cache schema is versioned (`schema_version`, filename `account-tags-v1`); a
  future shape installs as a new version and old versions read as
  `staleVersion` (rebuild), never as empty success.
- No raw format, YAML, wire, SQL, dependency or configuration change ships
  with this ADR; `Memo`, YAML, wire/HTTP transport, outbox and PBX
  membership are untouched by the tag refresh path. SwiftPM discovers the new
  Kit sources automatically.
