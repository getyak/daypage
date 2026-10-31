# DayPage iOS launch polish implementation plan

> For agentic workers: use focused implementation with one independent final review. The user delegates routine design decisions and execution; no repeated approval gate.

**Goal:** Make local iOS capture, rediscovery, AI and sharing a coherent, recoverable experience.

**Architecture:** Preserve NotebookModel, local Markdown and existing shell. Separate search presentation, use native List row actions, extract a record-aware calendar and sharing preview. Compute archive groups once per result set.

**Tech Stack:** SwiftUI/UIKit, Foundation, Swift Testing/XCTest, iOS 16.1.

**Spec:** `docs/superpowers/specs/2026-10-31-ios-launch-polish-design.md`.

## Global constraints

- iOS 16.1, no new dependencies, no format migration or real-vault mutation.
- Warm paper/amber/serif visual system; English and Simplified Chinese.
- AI requests only on explicit Send with source preview.
- User's autonomous execution instruction selects routine implementation choices.
- No Store submission or TestFlight release in this task.

## Review focus

- Thousands of notes across years: grouping does not scan the full collection per section.
- Card swipe does not conflict with vertical scroll, selection or back navigation; delete is confirmed.
- Calendar cancellation/year/leap-day/empty-date selection preserves the exact chosen day.
- Sharing long/attachment-only notes never silently clips or exports unintended assets.
- Setup, cancellation and empty AI context keep drafts and avoid unsolicited network requests.

### Task 1: Navigation, Archive and large collections

**Files:** NotebookView.swift, NotebookArchive.swift, NotebookTimeline.swift, core query helper/tests, LocalNotebookUITests.swift.

**Interfaces:** Keep `ArchiveView` browsable and present search independently. Native List rows host LocalMemoCard. Group results as stable day sections with arrays, not repeated filters.

- [ ] Add native UI cases for Archive vs search and return to origin; add core grouping/query boundary cases before helper implementation.
- [ ] Record baseline core/contract results and missing behavior in native tests.
- [ ] Implement explicit Today/back/search routes, browse summary/reset/empty/error states and lazy native lists.
- [ ] Run core and affected UI cases; commit this optimization independently.

### Task 2: Record-aware calendar

**Files:** new NotebookCalendar.swift, core calendar helper/tests, NotebookArchive.swift, project.yml.

**Interfaces:** `NotebookCalendar(selectedDay: Binding<String>, onSelect: () -> Void)` retains existing callers; reads counts from NotebookModel entries, stages selection locally.

- [ ] Add leap-year/year-boundary/weekday-grid tests and native record-count/cancel/commit test.
- [ ] Implement month navigation, record indicators, localized accessibility and explicit Done.
- [ ] Run core and affected UI cases; commit separately.

### Task 3: Card actions and sharing

**Files:** LocalMemoCard in NotebookTimeline.swift, NoteViews.swift, new NoteSharePreview.swift, optional pure sharing helper/tests.

**Interfaces:** `NoteSharePreview(entry: NotebookEntry)` is shared by cards and details. Parent Task 1 supplies List rows for native swipe support. Do not change CaptureDock or NotebookTimeline layout in this task.

- [ ] Add focused native cases for both swipe directions, pin, confirmed Trash and share preview style/format.
- [ ] Implement leading pin/chat, trailing share/trash, explicit menu/accessibility equivalents and no full-swipe deletion.
- [ ] Implement bounded image preview with styles/date and complete text/original alternatives, explicit attachment semantics and recovery.
- [ ] Run bounded verification coordinated with parent; commit separately after integration.

### Task 4: Lightweight AI guidance

**Files:** NoteChatView.swift, SettingsView.swift only if needed, localization resources, native tests.

**Interfaces:** Retain ChatSession persistence and NoteContext scope. Suggestions edit the draft without Send. Setup returns to the current conversation.

- [ ] Add native empty-context/setup-draft tests; retain loopback send/cancel coverage.
- [ ] Implement compact status, setup/empty guidance and draft-only suggestions with accessible composer.
- [ ] Run affected native journeys and commit separately.

### Task 5: Integration and release preparation evidence

**Files:** active engineering docs, localization resources, project list, handoff evidence.

- [ ] Check core, contract, capture-recovery tests and native build.
- [ ] Run serial Primary iPhone UI journeys, capture English/Chinese/light/dark/large-text evidence; compact/iPad if the shared lease allows.
- [ ] Independent whole-branch review; fix confirmed high-priority issues and rerun affected checks.
- [ ] One issue-linked PR, exact-head CI, merge only after required gates pass; record outstanding real-provider/device/Apple gates separately.
