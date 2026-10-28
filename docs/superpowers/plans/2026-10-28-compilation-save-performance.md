# Compilation Save Performance Implementation Plan

> **For agentic workers:** Execute inline with superpowers:executing-plans. The lead arranges independent review; do not delegate further.

**Goal:** Resolve issue #824 only if the current local compilation save path demonstrably blocks the main actor.

**Architecture:** Keep compilation progress and failure publication on the main actor. Send immutable parsed output and the Vault root captured at compilation entry to one serial persistence actor. Preserve existing atomic writes, entity operation markers, partial memo failure reporting, and local-only consent behavior.

**Tech Stack:** Swift 5.9, Foundation, Swift Concurrency, existing DayPageKit storage.

**Spec:** [Issue #824](https://github.com/getyak/daypage/issues/824), root AGENTS.md, and ADR-0007.

## Global Constraints

- iOS 16 compatibility; no dependencies, migrations, or persistence-format changes.
- Owned: CompilationService.swift, its directly required EntityPageService/WikiIndexService interfaces, focused compilation persistence tests, and this plan.
- Forbidden: attachment sync/downloader/live helper paths, UI rearrangement, personal Vaults, existing cloud notes, external model calls.
- Use only synthetic temporary Vaults. Runtime evidence stays outside the repository in the task handoff.
- Source checkout is dirty and remains untouched. Work starts at origin/main 604ff953 in a separate external worktree; native cross-repository creation was unavailable in the parent session.

## Review Focus

- A blocked coordinated write must leave the main actor responsive.
- A Vault switch during suspension must never split the save across roots.
- Entity failure must leave the previous daily completion marker intact.
- Concurrent saves must preserve entity idempotency and complete log rows.
- Cancellation before persistence must avoid writes; an entered synchronous commit retains existing partial failure semantics. Consent still gates outbound attempts, while already generated local results add no request.

### Task 1: Prove the current execution path

- [x] Add a focused regression that runs the real save with a controllable filesystem coordination gate in a synthetic Vault and asks the main actor to respond while that write is pending.
- [x] Run the existing compilation safety tests as baseline, then the regression. Capture the actual failure and inspect generated daily Markdown. Do not reuse the issue's historical 20–60 ms estimate.

**Scope ruling:** The lead approved the asynchronous close/drain integration in ADR-0026. The in-memory gate must never hold a lock across I/O or notifications. Add only necessary closing hooks in VaultInitializer, LocalDataResetPolicy, AppSettings, SyncQueueObserver and the actual native call sites; leave attachment ownership unchanged.

### Task 2: Move the bounded commit off the main actor

- [x] TDD the Storage scope: invalidation rejects queued tokens with zero effects; a drain suspends while active work runs, leaves the main actor responsive, and overlapping transitions keep admission closed.
- [x] Wire reset, locator replacement, AI preference changes and native session publication to synchronous close plus asynchronous drain. Revalidate the exact target after drain.
- [x] Make parsed compilation values Sendable. Capture the Vault root once at compile entry, including source reads, daily revision, hot cache, save and index rebuild.
- [x] Add a shared serial persistence actor in CompilationService.swift. Move synchronous save helpers into a root-bound persistence value; return memo failure count to the main actor. Await persistence before publishing done.
- [x] Allow the pure entity persistence implementation to execute outside the main actor while serializing its two read/modify/write entry points and resolving their root once.
- [x] Add a root-bound WikiIndexService rebuild entry point; retain the existing public default for callers.
- [x] Keep entity-first completion ordering, backups, atomic writes, hot cache guards, typed errors, log format and retry markers.

**Ruling:** The overlapping-save regression reproduced an existing same-second backup-name collision. Keep existing backup names when available and add a unique suffix on collision; this preserves both previous versions without changing raw/wiki document formats.

**Review correction:** Keep global writer invalidation separate from per-kind request currency so unrelated transitions cannot discard a revoke or Vault-switch intent. False consent must become effective synchronously before drain; only true waits for drain and latest-request currency. Both corrections have real API failing regressions before their fixes.

### Task 3: Verify and hand off

- [x] Run the regression GREEN and adjacent compilation/entity/wiki tests. Add explicit-root, overlapping-save, invalidation-before-commit, and failure assertions on actual isolated files.
- [x] Run the full DayPageKit suite with bounded jobs after the lead releases the build slot. Report every failure or unavailable gate honestly.
- [x] Run repository doctor and the relevant iOS build gate when the lead allocates capacity. Doctor and agent tests passed; local iOS build remained at package resolution and was stopped, so native type/build acceptance remains pending CI. Native syntax parsing passed separately.
- [ ] Obtain lead-arranged independent review. Stage only owned reviewed files, commit, push and open/attach a PR. The lead controls merge and release gates.
