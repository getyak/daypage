# Manual Reviews and Explicit Exchange Implementation Plan

> For agentic workers: implement in this isolated worktree, then obtain independent root review.

**Goal:** Ship explicit day/week generation and previewed local file exchange.
**Architecture:** Frozen source snapshots and revocable generation sessions reuse
AIClient; versioned Markdown pages remain separate from raw notes. Exchange jobs
use canonical raw files, hash manifests and new namespace publication.
**Tech Stack:** Existing Swift/Foundation/CryptoKit/SwiftUI and file APIs.
**Spec:** ../specs/2026-11-07-manual-reviews-file-exchange-design.md

## Global constraints

GET-442 / #978. No legacy cloud/background chain, dependency install, native/Swift
build, real data, original-workspace edits, commit or push by this worker.

## Review focus

Late replies and consent revocation; exact source-byte scope; source edits during
generation/save; same-ID different-content collision; pending-job recovery and
quota; path/link/hash/namespace boundaries; preservation of ordinary drafts.

- [x] Add date/week snapshots, revocable manual generation, versioned page codec
  and store with source fences; write synthetic transport/time/lease tests.
- [x] Add current Local source-selection/result-preview/history/save UI, explicit
  Keychain/request action and configuration/consent cancellation.
- [x] Add versioned canonical export, staged/import preview and explicit commit,
  restart/resume/discard handling; write format/path/hash/idempotence tests.
- [x] Register Local source/UI routes, localizations, focused contracts and ADR.
- [x] Run allowed lightweight static checks, provide exact uncompiled/native
  limitations and handoff for independent review and hosted CI.

The 24 new Swift test cases are written but not run locally: the shared host's
disk pause prohibits Swift/native work. Independent review and hosted CI remain
required. The Mac App adapter is GET-446 / #982; Web is GET-443 / #979. Neither is
claimed delivered by this Core fixture or the Local iOS view.
