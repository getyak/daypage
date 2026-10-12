# Unpublished DayPage Recovery Implementation Plan

> **For agentic workers:** Implementation uses the user's Pi + MiMo preference; Codex owns scope, independent validation, review, and remote delivery. Continue execution under the existing user authorization.

**Goal:** Recover and improve unpublished source without reversing current `main`, then deliver reviewed code to the remote repository.

**Architecture:** Retain current navigation, privacy, persistence and release safeguards. Integrate three bounded source sets: exact design-token alias cleanup, portable serialized iOS gates, and screenshot capture using original bytes, durable manifests, an explicit Share handoff and opt-in understanding.

**Tech Stack:** Swift/SwiftUI, Swift Package Manager, App Intents, UIKit Share Extension, Python, Bash, Make, GitHub Actions.

**Spec:** GitHub issues #928, #876 and the limited cleanup item under #332; ADR-0012 and `docs/design/testflight-fidelity.md` define recovered behavior.

## Global Constraints

- Preserve iOS 16 compatibility; availability-gate App Intents and extension behavior.
- No new external dependency or canonical raw memo/asset format migration.
- No personal vault access, live AI requests, key collection, release or TestFlight upload.
- Preserve original worktrees and use a branch from `935917debd8242993ba0500488f0800c688c0277`.
- Never replace newer main files wholesale with historical versions.
- Use one Primary iPhone session and registered transient artifact paths; preserve formal evidence before cleanup.

## Review Focus

- Crash/failure between original, manifest and memo writes must recover exactly one memo.
- Consent revoked while queued or in flight must prevent stale completion and further requests.
- Delete/undo and changed Vault root must never remove or rewrite an unrelated memo or asset.
- Share and Intent delivery must enforce image type, byte/pixel limits and safe app-group paths.
- Current navigation, keychain migration, diagnostics and release tag safeguards must survive recovery.

## Task 1: Inventory and verified baseline

**Files:** Private inventory/snapshots; current docs and source.
**Interfaces:** Recover local/base bytes per source; classify remote-equivalent and superseded differences.

- [x] Snapshot tracked diffs and identify untracked source separately from runtime artifacts.
- [x] Compare source bytes with current remote main; 133 five-pass files are already remote.
- [x] Record decisions in `docs/engineering/remote-recovery.md`, including remaining device-only acceptance.
- [x] Run baseline repository/script/localization gates and retain their results.

## Task 2: Local iOS gates and design cleanup

**Files:** `Makefile`, `scripts/ci/ios-local.sh`, `scripts/ci/select_simulator.py`, `scripts/ci/run_script_tests.sh`, script fixtures, `DayPage/DesignSystem/*`, migrated views, testing and fidelity docs.
**Interfaces:** `ios-local.sh check|build`; explicit simulator UDID/profile validation; existing canonical DSColor values.

- [x] Resolve wrapper/script merges while retaining main's Python fixture discovery.
- [x] Prove invalid explicit devices fail closed and argument/reason text cannot become shell code.
- [x] Keep actual ownership checks, one native test worker and portable CI fallback.
- [x] Retain all alias expansion values and live helpers; migrate recovered screenshot callers too.
- [x] Run script, token and localization gates; update docs from local-only to remote-delivery status.

## Task 3: Screenshot capture recovery and hardening

**Files:** Screenshot model/services/tests, `SaveScreenshotIntent`, Share Extension, Today integration, Settings, project configuration and ADR-0012.
**Interfaces:** Existing `ScreenshotCaptureCoordinator`, manifest/memo IDs, explicit provider protocol, review-only action drafts.

- [x] Resolve source conflicts against current main; retain insight/related swipe actions, current search and isolated unit-test host.
- [x] Inspect exact-byte ingest, deduplication, reconciliation, limits, consent revocation, retries and delete/undo.
- [x] Add behavioral regression tests for confirmed defects and watch them fail before fixing.
- [x] Keep cloud processing off by default, label generated drafts and require user confirmation for suggested actions.
- [x] Run all DayPageKit host tests (342 XCTest + 75 Swift Testing, 0 failures, 3 existing skips).
- [x] Run affected native suites, app build and isolated Simulator smoke.

## Task 4: Independent review and remote delivery

**Files:** Final diff, review/evidence records and current operating docs.
**Interfaces:** Reviewed commit, current-head GitHub CI, linked PR.

- [x] Obtain a fresh independent review and resolve all confirmed P0/P1 findings.
- [ ] Save non-sensitive gate evidence with actual pass/fail/skipped results.
- [ ] Stage only reviewed source/document paths, commit, push a dedicated branch and create a linked PR.
- [ ] Inspect all current-head CI results and repair change-related failures; read back the remote commit/PR.
- [ ] Preserve source, formal evidence and device-only limitations; remove only this task's rebuildable transient artifacts after delivery.

## Task 5: Bounded privacy recovery batch (#928) and screenshot follow-ups

**Files:** `AIRequestConsent`, `AppSettings`, `LLMClient`, `CompilationService`,
`WeeklyCompilationService`, `BackendIntelligenceService`, `DiagnosticsConsent`,
`DiagnosticsEventGate`, `SentryLive` (DayPageApp), Thread/Doubao/Voice request
boundaries, screenshot store/coordinator/provider/inbox, consent test suites.
**Interfaces:** Injectable `AIConsentChecking`, typed terminal
`AIAuthorizationError`, epoch `(UUID, startedAt)` snapshot, stable share
capture identity, single-flight preflight reservation.

- [x] Enforce the existing master AI switch at every new request boundary
  (LLM entry/retry/SSE, Thread via guarded client, Doubao file post-read and
  stream frames, Whisper post-read and every retry, backend flush/request,
  connectivity probes). Defaults and consent UI preserved; no v2 grant policy.
- [x] Map denied errors to terminal `CompilationError.aiDisabled` /
  `WeeklyCompilationError.aiDisabled`; keep independent account sync and
  read-only derived refresh ungated.
- [x] Persist the immutable diagnostics epoch start floor; reject old/nil
  timestamps in the real beforeSend via the testable `SentryLive.makeBeforeSend`
  seam before the unchanged field scrubber (source-proven SDK race, not an
  observed upload).
- [x] Screenshot live consent guards + settings revoke wiring; vault-root path
  containment with exact-filename/manifest-identity checks and share-inbox
  identity binding; share replay identity; single-flight preflight; undo
  finalization ownership close.
- [x] Test-first RED→GREEN for each boundary with recording transports,
  terminal URLProtocol, fake gates/read/flush/fallback; isolated stores only.
- [x] Selective canonical-directory inventory for migration copy and verification,
  per-manifest hashes, destination preflight and isolated native migration fixtures.
- [x] Fresh independent final review and affected Xcode/Simulator gates.
- [ ] Commit/push/PR and current-head remote gates (follow the linked PR for
  delivery state after this source checkpoint).
