# Card Reading Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the user's four card-reading, swipe and optional-location changes.

**Architecture:** Native SwiftUI rendering and swipe actions; injected UserDefaults for type preferences. CLLocationManager is created only after explicit Add location. Existing Memo.location is carried through the draft's identity/revision boundary.

**Tech Stack:** Swift, SwiftUI, CoreLocation, XCTest/Swift Testing, Python host harness. No new dependencies.

**Spec:** ../specs/2026-11-06-card-reading-design.md

## Global Constraints

- iOS 16.1+; preserve raw Markdown/YAML and old draft compatibility.
- Location defaults off for each new note; no background/continuous location or reverse geocoding.
- Preserve uncommitted output and shared services; use an isolated worktree and registered artifacts.
- Root owns integration, draft/model/editor/location/project/localization; core_tools owns timeline/theme/settings/NoteTypography; design_check is read-only.

## Review Focus

- Late location callbacks after closing, cancelling, saving or replacing the draft must not mutate another draft.
- Body autosaves and attachment updates must retain or intentionally remove location at the same revision.
- Invalid/old preferences and old draft JSON must remain readable.
- Invisible day anchors must preserve calendar and capture jumps without creating empty tall rows.
- Full swipe must open Chat/Share; Trash must still require confirmation.

### Task 1: Card presentation, typography and swipes

**Files:** NotebookTimeline.swift, NotebookTheme.swift, SettingsView.swift, new Core NoteTypography.swift and focused tests.

**Interfaces:** `NoteTypography.load(from: UserDefaults)`, `NoteTypography.save(_:to:)`; NotebookModel publishes mutable `noteTypography`.

- [ ] Test default15, persisted style/size, corrupt/invalid inputs and injected-defaults isolation.
- [ ] Remove outside-card headings/footer and retain compact scroll anchors.
- [ ] Implement preferences and live preview with Dynamic Type.
- [ ] Put Chat/Share first on respective edges and enable full swipes.
- [ ] Verify actual native swipe, card counts/scroll jumps and settings relaunch.

### Task 2: Optional capture location

**Files:** Memo.swift, CaptureDraftStore.swift, NotebookModel.swift, NoteViews.swift, new NoteLocationCapture.swift, project and localized usage descriptions.

**Interfaces:** Snapshot/sidecar optional Memo.Location. `NotebookModel.setCaptureLocation(_:for:)` checks draft identity and storage gate. Location adapter has explicit request/cancel and result callback.

- [ ] Extend actual draft transaction fixture for old decoding, location autosave/asset changes/removal/commit/discard/staleID.
- [ ] Carry location through every snapshot construction and raw commit, without changing raw format.
- [ ] Add explicit location acquisition, cancellation, timeout/error recovery and editor controls.
- [ ] Show selected location in card/detail, leaving text-only default unchanged.
- [ ] Run host round trips and isolated native capture, reopen and permission checks.

### Task 3: Integrate and deliver

- [ ] Add focused native tests with deterministic synthetic location plus a separate actual permission-denial check.
- [ ] Update affected diary/card contracts and current docs; run relevant host/core checks and simulator journeys.
- [ ] Independently review the final diff, fix confirmed issues, link GitHub issue and GET-418 in PR.
- [ ] Follow the latest applicable CI and repository gates; report source, native evidence and any remaining limitations accurately.
