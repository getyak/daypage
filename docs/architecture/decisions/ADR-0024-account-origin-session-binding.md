# ADR-0024: Account/origin/session binding for native Apple sync

- Status: Accepted (implemented for native Apple sync; live backend wiring is
  parent-owned and gated separately)
- Date: 2026-10-16
- Issue: #884 (bounded native realm-isolation batch)
- Supersedes: none (extends ADR-0016 revisioned attachment sync for the
  account/session layer)

## Context

Native Apple sync may soon target a newly authorized shared Supabase backend.
Before that connection is safe, one local Vault must be provably bound to one
**realm** — the pair (normalized HTTPS backend origin, user UUID) — and every
durable sync effect must be isolated from older sessions, older accounts and
older backends. The pre-existing state layer could not express this:

- `SyncAccountStateStore` bound a Vault by UUID alone; the same UUID on a
  different backend origin looked like the same account, so old cursors and
  obligations could leak into a new project.
- Generation checks ran only after awaited results; durable effects (transfer
  sidecar writes, media installs, raw apply, outbox ack, cursor advance) could
  commit for a session that had already been replaced.
- The transfer sidecar had no realm header at all; unproven legacy state could
  be silently re-attributed.
- A decoded JWT `sub` was accepted as identity for routing; a refreshed token
  could be sent to an older endpoint without any per-token server proof.
- Host installers (iOS `RootView`, macOS `MacCloudAuthService`) ran async
  proof/configure work without attempt identity, so a stale failure could
  clear a newer session.

## Decision

### 1. Realm identity and verified session context

- A realm is exactly `SyncRealmIdentity(normalized HTTPS origin, user UUID)`.
  Origin normalization (`SyncRealmOrigin`) rejects userinfo, ambiguous ports,
  non-root paths, queries, fragments, percent-encoded authorities and
  non-HTTPS schemes; the normalized form is `https://host[:port]` with the
  default port omitted. There is no DEBUG relaxation.
- URL and publishable key are selected as ONE complete pair from ONE
  configuration tier (`SyncConfigurationPair`); a tier overriding only one of
  the two fails closed instead of borrowing the missing half from another
  tier.
- `SyncSessionContext` is immutable (identity + configuration + server-verified
  user) and is shared unchanged by the uploader, puller and downloader.

### 2. Account sidecar compatibility and the recovery boundary

- The account sidecar keeps its historical filename `account-v1.json`; the
  content is explicitly versioned (`schema_version: 2`) and binds BOTH
  `origin` and `user_id` plus the monotonic `pull_cursor`. Renaming the file
  (or introducing a second name) is deliberately avoided so detection of
  pre-realm state can never be bypassed.
- Fail-closed compatibility (ADR-0016 style "preserve everything"): schema-v1
  (no origin), missing-origin, corrupt, unreadable or unknown-version state,
  and first claims over unproven legacy cloud obligations (transfer sidecar
  with unknown/corrupt shape, resumable state, partial downloads) all return
  bounded errors (`legacyRealmUnverified` / `invalidState`) and preserve the
  account file, cursor, raw YAML/Markdown, assets, outbox, transfers and
  partial files byte-for-byte.
- The transfer sidecar (`attachment-transfers-v1.json`, same historical
  filename) may carry a realm header (`realm_origin` + `realm_user_id`). Its
  shape is strictly validated (schema, array/record fields, all-or-nothing
  well-typed header); unknown schemas, malformed records, partial headers,
  unreadable state and unenumerable partial directories are held
  (`unproven`), never downgraded to "empty". Absence is only concluded from
  proven-absent state (lstat ENOENT), never from unreadability.
- No automatic UUID-based legacy rebind, clearing, reset or migration exists
  anywhere in the code. **Recovery of legacy/unverified Vault state is an
  explicit, parent-owned operation** (separate authorization and plan); the
  app storage root and raw formats are unchanged. A genuinely first,
  unclaimed Vault binds normally and keeps its offline outbox.

### 3. Generation lease and effect linearization

- Each installed session carries a fresh `SyncSessionLease`. Clear, reject,
  logout, identity/origin change and every newer install invalidate it.
- `withValidity` is a synchronous commit gate sharing one lock with
  `invalidate()`. Check + effect linearize together before every durable
  mutation: transfer obligations (create/delete/update), media install
  (staging create/copy/cleanup and final move), raw apply commit
  (`RawStorage.applyRemoteChanges(sessionLease:)` — the only sync-commit entry
  added there), outbox acknowledgement and cursor advance. No lock is held
  across `await`.
- Documented ordering: a commit that entered the gate BEFORE invalidation
  linearizes may finish to completion; invalidation returns only after it.
  Every later commit is refused outright. In-flight network sends may finish
  but their results are re-checked before any effect commits; old catch
  blocks cannot overwrite current session health.

### 4. Send-start linearization and constrained transport

- `SyncSessionNetwork` starts each real request synchronously (URLSession task
  creation + resume) INSIDE the lease gate; only the result is awaited. An
  invalidation that linearized before the start means zero request starts.
  This closes the window where a stale POST could start after a
  caller-side pre-await check.
- `SupabaseSyncTransport` is used only by sync components (the global
  `HTTPTransports.shared`/`HTTPTransport.swift` stay untouched for other
  services). It refuses redirects at the URLSession task delegate BEFORE the
  follow-up request exists, rejects cross-origin request URLs before any
  bearer is attached, and treats 3xx results from fakes as refusals.
- Saved and newly issued TUS URLs must pass
  `SyncResumableEndpoint.validated` (same origin + canonical
  `/storage/v1/upload/resumable/<id>` path, no userinfo/query/fragment/
  traversal) before any HEAD/PATCH. Retryable HEAD failures (401/403, 429,
  5xx, malformed responses) preserve saved URL/offset; only documented
  expired/not-found statuses (404/410) reset resumable progress — and only
  same-realm restarts may reset it, never deleting outbox intents or assets.

### 5. Exact-token proof boundary

- `SyncSessionTokenProver` is shared by uploader, puller and downloader
  (`session.tokens`). Any NEW token value needs local claim pre-checks
  (issuer `origin/auth/v1`, subject, role, expiry) AND a same-origin
  `/auth/v1/user` success with matching UUID before any durable preparation
  or mutation; the decoded JWT alone is never auth proof. The initial proof
  seeds only the exact token it proved; reuse is limited to that exact
  unexpired token in the live context (singleflight per exact value); cache
  writes after invalidation are discarded. Callers receive the narrow
  `SyncVerifiedAccessToken` capability so a raw provider string cannot skip
  proof. Tokens are never persisted or logged.

### 6. Host installation and legacy fallback

- `SyncSessionInstallCoordinator` (with `SyncInstallAttemptGate`) gives every
  async install attempt a monotonic token shared by success/catch/UI/health/
  flush actions; logout, nil sessions, rejections and every newer install
  invalidate older tokens, so stale proofs/failures/successes cause zero
  current mutations. Before iOS publishes a changed SDK auth snapshot,
  `authSessionWillChange` synchronously invalidates pending attempts and the
  prior lease. RootView observes access-token changes (including same-UUID
  refresh) plus onAppear restoration; exact duplicate snapshots are no-ops.
  macOS retains `rejectedConfiguration` on failure
  instead of `clearSession()`.
- The legacy uploader bridge only remains a candidate for a pristine,
  unclaimed Vault with legacy configuration; bound, unknown, legacy-unverified
  or rejected Vaults never fall back to legacy upload or report fake
  "synced" success. Diagnostic uploader injection is compiled out of
  production (`#if DEBUG`).
- Large accounts drain completely: `pullAllChanges` consumes every valid
  advancing page and reports synced only at `hasMore == false`; the per-pass
  page bound is a reschedule valve, not a truncation or a safety removal.

## Consequences

- Pairing an existing local Vault with a different backend origin (including
  the authorized new shared project) now fails closed until an explicit,
  parent-authorized recovery decision; data is preserved untouched.
- Token refreshes cost one same-origin `/auth/v1/user` proof per new exact
  token value per live session; unchanged tokens are free.
- Test seams (injected transports/starters, `#if DEBUG` uploader injection,
  the no-lease `applyRemoteChanges` recovery entry retained for
  interrupted-write recovery tests) are explicit; production paths all carry
  the lease and the verified-token capability.
- Token-cache reads and paired writes share the prover lock; finalization
  acquires the lease before the cache lock, while cached readers release the
  cache lock before checking the lease. Failed transient-file adoption also
  removes its newly created owner directory without touching Vault partials.
- Unexecuted gates remain with the parent: native iOS/macOS app builds,
  Simulator/runtime verification, and any live account/device sync.

## Final hardening (repair batch, same decision)

- **Typed sidecar compatibility.** Sidecar shape validation uses strict
  Codable decoding, not JSONSerialization key checks: JSON booleans (`1 is
  Bool` bridging), nulls, fractions, wrong UUID/enum/date/descriptor values
  and unknown schema versions are all corruption (`unproven`) even under a
  matching realm header. Valid empty schema-1 documents (with or without a
  matching header) remain first-claimable/provable, and real
  `AttachmentTransferStore`-encoded state restarts cleanly in-realm.
- **Synchronous install reservation.** Hosts call
  `SyncSessionInstallCoordinator.reserve()` on the synchronous auth event
  BEFORE scheduling any async work: the attempt generation starts and the
  previous session lease is invalidated at that boundary, so an older proof
  continuation resuming before the newer attempt's async installer starts is
  already stale. Completion additionally re-checks the live auth snapshot;
  logout/nil/rejection/invalid configuration invalidate attempts at the same
  synchronous boundary.
- **Transient download ownership.** `URLSession` download callbacks retain
  the bytes in a uniquely owned, permission-restricted transient copy before
  publishing a URL (the session's temporary file is only guaranteed for the
  callback's duration). Consumers discard owned copies on success, failure or
  stale lease; these copies are transient transport data, never Vault
  obligations, and durable staging stays under the lease gate.
- **Per-exact-token singleflight.** In-flight proofs are keyed by the exact
  token value; a flight's capability is delivered only to waiters that
  requested that value. Completion re-checks expiry at the current
  (injectable) clock and finalizes the cache write plus capability inside
  `lease.withValidity`; joined waiters are rechecked on delivery and cached
  hits obey current expiry.
- **Notifications after both gates.** `applyRemoteChanges` keeps all
  persistent writes and `afterWrite` callbacks inside the synchronous
  lease+writeQueue gates and returns the committed result plus the written
  day-key set; WidgetCenter/NotificationCenter publication happens only
  AFTER both locks are released, so a background raw commit can never
  deadlock a main-actor logout/invalidation. A commit that entered the gate
  before invalidation still publishes its cache invalidation even if session
  invalidation linearizes immediately after its durable commit.
