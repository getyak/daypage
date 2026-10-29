# Local Notebook Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans. The lead implements in this session; an independent reviewer checks the finished branch.

**Goal:** Deliver a small native local notebook with personal AI and note chat, backed by files, with only Archive / Feedback / Settings navigation.

**Architecture:** A dependency-free DayPageCore Swift package owns compatible memo files, AI configuration/transport and local chat persistence. A standalone SwiftUI app builds for iOS. The old cloud edition is recoverable from a source archive release.

**Tech Stack:** Swift 5.9+, Foundation, Security, CryptoKit, SwiftUI, XcodeGen.

**Spec:** docs/superpowers/specs/2026-10-30-local-notebook-design.md

## Global Constraints

- iOS first (user confirmed); iOS 16.1+ app, no external dependencies or databases.
- Preserve existing raw Markdown files, YAML and assets; no destructive migration.
- No auth, cloud backend, telemetry or automatic model calls.
- Keychain-only API keys; no plaintext secrets in files/logs.
- Sidebar: Archive, Feedback, Settings only.
- Do not alter historical worktrees, real user data or live services.

## Review Focus

- Legacy separators and Markdown horizontal rules must not split or discard memo bodies.
- Concurrent writes, malformed blocks and edits must preserve unrelated bytes and metadata.
- AI requests must reject invalid endpoints and never leak keys across redirects.
- Cancellation/failure/restart must preserve drafts and readable conversation history.
- Compact screens, Dynamic Type and dark mode must keep navigation and save controls reachable.

### Task 1: Source archive and contracts

- [x] Link Linear and GitHub issues; record exact old revision and source-only release notes.
- [x] Independent builder check of the design; resolve significant ambiguity.
- [x] Publish/read back archival release. Existing multi-client source stays available for the other clients.
- [x] Write failing tests for the shared file and AI contracts.

### Task 2: Local core

Files: DayPageCore/Package.swift, Sources/DayPageCore/{Memo,NotebookStore,AIConfiguration,AIClient,ConversationStore,KeychainSecretStore}.swift, Tests/DayPageCoreTests/.

- [x] Reuse the original Memo codec and implement serialized, coordinated atomic file operations with tests.
- [x] Add bounded local note retrieval, local conversation persistence and safe endpoint/transport configuration.
- [x] Run the complete package test suite; 29 passed.

### Task 3: Native UI and Figma

Files: DayPageLocal/, DayPageLocal/DayPageLocal.xcodeproj/, DayPageLocalUITests/.

- [x] Create scoped editable Figma refinement using existing native font/icon conventions.
- [x] Implement archive, note editor/detail, explicit chat, local AI settings and feedback.
- [x] Build a separate local iOS project that does not resolve the other clients' cloud packages; keep the original multi-client project unchanged.
- [x] Build iOS and run Primary iPhone flows including dark/accessibility states. Compact was refused by the shared-session safety guard and remains unverified.

### Task 4: Delivery

Files: README.md, AGENTS.md, Makefile, .github/workflows/, docs/architecture/decisions/ADR-0027-local-notebook.md.

- [x] Update current docs and applicable lightweight CI for the new product boundary.
- [x] Independent code review; no remaining P0/P1/P2 findings.
- [ ] Commit reviewed paths, push and create issue-linked PR; verify latest-head applicable CI.
- [ ] Report separate source archive, local evidence, remote branch/PR and any remaining gates.
