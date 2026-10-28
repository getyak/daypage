# ADR-0026: Drained local compilation commits

- **Status:** Accepted for issue #824 remediation
- **Date:** 2026-10-28
- **Issue:** [#824](https://github.com/getyak/daypage/issues/824)

## Context

Daily compilation saves currently inherit the main actor and synchronously write entity,
daily, raw, hot-cache and log files. A real coordinated daily replacement prevented a
main-actor heartbeat in an isolated regression. Moving these operations to a detached
task would allow a late result to recreate a cleared Vault or publish into a new scope.

## Decision

`LocalCompilationCommitScope` in DayPageStorage owns a generation, active commit IDs
and outstanding transitions. Its lock protects only these small in-memory values. No
filesystem access, notification delivery, user callback or suspension runs under it.

1. `capture(vaultRoot:)` produces an immutable generation/root token while open. Compile
   captures it before source loading or provider work; closing invalidates queued results.
2. `beginCommit(token)` atomically admits a current token and returns a finish handle.
   One shared compilation persistence actor serializes actual saves. Before its first
   write it checks cancellation, live consent, current root and current raw source hash.
3. `close(kind:)` synchronously invalidates old tokens and refuses new admission. It returns
   a transition whose `waitForDrain()` suspends until admitted commits finish. `finish()`
   reopens only after all overlapping transitions finish. Writer generation is global,
   but request currency is independent for AI preference, locator replacement, reset,
   and session operations. Only a newer request of the same kind supersedes a mutation;
   an unrelated auth event must not swallow a requested revoke or Vault switch.
4. An admitted commit may finish using its captured root. Its index rebuild is part of
   the same synchronous worker operation; no trailing untracked rebuild may recreate it.
   The main actor only publishes current results after the awaited worker returns.
5. Raw compilation backfill returns a receipt without UI notification or sync scheduling.
   Main-actor publication happens after disk work, checks the current root/generation,
   and carries the captured root. Closing invalidates publication as well as queued saves.
   Ordinary explicit-root mutations retain their existing metadata notification contract;
   only deferred compilation receipts suppress stale notification delivery. Their async
   sync-queue effects still verify the captured root.

## Integration calls

- `VaultInitializer.replaceShared(with:) -> Task<Bool, Never>` closes synchronously;
  callers await its task before announcing the switch or starting new-root observers.
  Existing direct setter compatibility applies immediately only while drained; otherwise
  it schedules the same safe replacement. Actual app callers use the awaitable API.
- `LocalDataResetPolicy.beginReset(contextProvider:mutation:) -> Task<Decision, Never>`
  closes synchronously, awaits drain, then revalidates live policy and the exact root
  before mutation. Settings awaits this result. The old synchronous helper refuses a
  reset if commits are active, preserving existing policy tests without a blocking wait.
- `AppSettings.setAIFeaturesEnabled(_:in:) -> Task<Void, Never>` closes synchronously,
  writes false immediately to refuse every new outbound authorization, then awaits
  drain. True applies only after drain and only for the latest preference request.
  The Settings toggle and onboarding entry use it; screenshot revocation remains
  connected after disable. Existing provider cancellation is unchanged.
- `SyncQueueObserver.clearSession` closes local compilation admission and returns a
  drain task while retaining its existing synchronous sync-session invalidation.
  Native auth listeners/sign-out await the local drain and recheck the SDK's exact
  current token before publishing their new session snapshot. Session installation
  awaits drain before its final currency check;
  direct configuration refuses to replace a session while local commits are active.
- iCloud startup probe, migration completion, and rollback await locator replacement.

## Linearization and limits

Admission racing with `close()` has two outcomes: admitted first means the transition
awaits it; closed first means zero writes. Clearing, switching and revoking complete
only after drain and their live checks. No main-actor thread waits for a worker lock or
file coordinator. Cancellation before admission performs no write. Cancellation or
closing during an admitted commit suppresses stale UI publication; existing entity
markers and completion ordering keep partial filesystem failures retryable.

This gate coordinates local compilation and its index work, not arbitrary raw capture,
attachment transfers, migrations or third-party provider cancellation. It changes no
Markdown/YAML, sync schema, dependency, or persistence format.
