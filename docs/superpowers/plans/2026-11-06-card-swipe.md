# GET-425 Card Swipe Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans; implement in this session and obtain an independent final review.

**Goal:** Prevent dragging a note from opening its detail while preserving taps, native swipe actions and the sidebar gesture.

**Architecture:** Give the shared note body button a tap-specific interaction. Keep List swipe handling and the sidebar recognizer independent; disable automatic full-swipe navigation.

**Tech Stack:** SwiftUI, iOS 16.1+, XCTest UI tests.

**Spec:** `docs/superpowers/specs/2026-11-06-card-swipe-design.md`

## Global Constraints

- Preserve local Vault data, accessibility activation, the existing device pool and unrelated changes.
- No dependency, storage-format, release or TestFlight changes.

## Review Focus

- Short/diagonal and out-and-back drags must not become body-button activation.
- A later intentional tap must work without a stale suppression timer.
- Native horizontal actions, vertical scrolling and edge drawer gestures remain reachable.
- Diary, Archive and Search use the same corrected interaction.

## Task 1: Correct the shared card interaction

- [ ] Add focused native regression journeys to `DayPageLocalUITests/CardShareUITests.swift`; record baseline failures before production edits.
- [ ] Change only the body-button interaction and full-swipe policy in `DayPageLocal/NotebookTimeline.swift`.
- [ ] Update existing swipe journeys to explicitly tap the revealed actions.
- [ ] Run the affected card suite and diary/sidebar/scroll journeys on Primary iPhone with `dev-ios-session run` and one reused build directory.
- [ ] Run applicable host contracts, inspect the final diff independently, and fix confirmed findings.
- [ ] Commit reviewed owned paths, open a PR linked to GET-425, and merge only after applicable gates pass. Record unavailable evidence accurately.
