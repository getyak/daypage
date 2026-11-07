# Local Screenshot Capture Implementation Plan

> For agentic workers: implement in this isolated worktree, then obtain independent root review.

**Goal:** Bring image Shortcuts and sharing into active local iOS with explicit note confirmation.

**Architecture:** A dependency-free capture inbox coordinates app/extension writers.
The app owns preview and NotebookStore publication; the extension stages only.

**Tech Stack:** Existing Swift/Foundation/ImageIO, AppIntents, SwiftUI/UIKit, XcodeGen.

**Spec:** ../specs/2026-11-07-local-screenshot-capture-design.md

## Global Constraints

No original-workspace edits, legacy cloud runtime, private data, added packages,
automatic network/AI, native heavy work or push. GET-440 / GitHub #976.

## Review Focus

Image decode bounds; cross-process publication/cancellation; symlinks/tampering;
crash after Vault publication before acknowledgement; existing draft preservation.

## Tasks

- [ ] Add ScreenshotInbox in DayPageCapture with atomic bounded, locked I/O;
  exercise it with synthetic PNG/JPEG, tampering, quota, duplicate/discard and concurrency tests.
- [ ] Add active-app inbox/preview controller and image AppIntent. Save using
  stable capture UUID through NotebookStore, acknowledge only after persistence;
  check local Trash on retry and preserve ordinary drafts.
- [ ] Add one-image Share target with cancellation gate, type/file validation,
  App Group entitlement and completeRequest only after durable staging.
- [ ] Register sources/embedding in project.yml and generated project; update
  dependency/privacy contracts and record narrow ADR exception for this extension.
- [ ] Run resource/audit preflight and focused host/static checks. Request root
  coordination before native SDK/build work; provide exact diff/test limitations
  for independent review before commit/push.
