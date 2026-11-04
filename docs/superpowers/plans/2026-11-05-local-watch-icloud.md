# Local Watch and iCloud Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans for implementation; independent whole-branch review before landing.

**Goal:** Deliver original Watch recordings into the local notebook and provide optional personal iCloud continuity and recovery.

**Architecture:** Add a durable Watch envelope/inbox and a provider-neutral immutable revision engine to DayPageCore. Thin native adapters own WatchConnectivity, iCloud discovery and on-device Speech. The existing Vault remains the local source of truth.

**Tech Stack:** Swift, Foundation/CryptoKit, SwiftUI, WatchConnectivity, AVFoundation, Speech, iCloud Drive.

**Spec:** `docs/superpowers/specs/2026-11-05-local-watch-icloud-design.md`

## Global Constraints

- iOS 16.1+, watchOS 9+, original Markdown/unknown YAML preserved.
- No credentials, cloud STT, custom service, distribution or unapproved data migration.
- Resource pause prohibits heavy builds; record missing native/paired/iCloud evidence honestly.

## Review Focus

- Crash after local commit but before receipt/index write must be recoverable.
- Deletion versus concurrent edit preserves the edited branch and historical original.
- Placeholder objects/unknown parents cannot cause partial/destructive application.
- Account switches cannot upload the prior account's pending work.
- Concurrent UI edits cause retry, never silent overwrite.

### Task 1: Durable capture and revision core

- [x] Add failing host tests for replay, conflicts, tombstones, restore and hostile/missing content.
- [x] Implement WatchCaptureStore, VaultRevision/transport and VaultReplica with durable apply journal.
- [x] Add narrowly scoped NotebookStore snapshot/apply primitives preserving original blocks.
- [x] Run DayPageCore tests serially in a registered artifact and inspect isolated Markdown (181 total, 15 continuity tests).

### Task 2: Native local adapters and Watch experience

- [x] Add original-first Watch recorder/queue and minimal accessible SwiftUI app.
- [x] Add synchronous durable phone inbox/receipts and optional on-device transcription.
- [x] Add optional iCloud adapter/discovery/account-bound settings and recovery list.
- [x] Connect app lifecycle and local mutation signals; update project/entitlements/contracts.

### Task 3: Review and evidence

- [x] Update ADR/current docs and hosted native gates for both targets.
- [x] Run scoped host/contracts; obtain independent review and fix confirmed material findings.
- [ ] Commit owned paths, open linked draft PR, record blocked native/device gates in Linear.
- [ ] Merge/close only after all required acceptance gates pass.

## Evidence ledger

- Host core: 181 tests passed, including 15 continuity tests and the review's interruption/delete/restore regressions.
- iOS/watchOS new adapter SDK type checks: passed; linking/signing/launch/UI remain unrun.
- Dependency/privacy contracts: 3 passed. Release-profile assembly: 15 tests / 88 assertions passed with every external side effect stubbed. `make doctor` and `git diff --check` passed.
- Independent static review: prior P1 journal/account/recording races fixed and re-reviewed. Large-library capacity remains unproven.
- Resource pause `INC-20261102194933-5bfd49` retained. No native build, new simulator, paired-device session, iCloud account operation, release lane or distribution performed.
