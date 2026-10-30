# Restore DayPage's established local iOS experience

User direction: keep the previous product's visual and interaction foundations while removing accounts, databases and cloud sync. The 0.5.0 minimal notebook does not meet this requirement. GitHub #946, related GET-326.

## Accepted foundation and implementation decisions

- Preserve ADR-0027's dependency-free DayPageCore, compatible Documents/vault Markdown and explicit personal AI configuration. No new dependencies, schema migration or real-note manipulation.
- Restore the original native Today hierarchy: compact menu/date/search header, a warm paper timeline with restrained 16–18 pt prose and timestamps, and a persistent bottom glass capture dock (+, writing, amber microphone, AI). No marketing hero or giant primary button.
- Restore writing as a bottom sheet with date/time, recoverable draft, attachment rail and clear save/collapse/discard behavior. Photos, files and microphone use Apple's native frameworks; audio stays local.
- Keep exactly three sidebar destinations Archive/Feedback/Settings; tapping the notebook identity returns home. Archive supports date selection, full-text/tag search, type and pinned filters. Note details support Markdown reading, attachments/playback, edit, pin, share and reversible trash.
- Use the original warm neutral/amber tokens and compact spacing; Chinese and English UI, dark mode, Dynamic Type, reduced motion and touch targets are real acceptance surfaces.

## Ownership

Lead: DayPageLocal app shell/theme/model/timeline/archive/resources/project, docs and integration. Storage specialist: DayPageCore/NotebookStore and focused core tests only. Capture specialist: NoteViews.swift and new attachment/recording UI helpers only. Read-only auditor: original UX inventory. Independent reviewer after integration.

## Gates

1. Storage tests first reproduce missing pin/trash/restore/attachment behavior. Validate raw-file compatibility, conflicts, unknown YAML, separate namespaces, symlinks and recovered drafts with synthetic Vaults.
2. Current-project build and UI tests through dev-ios-session Primary iPhone. Test save/relaunch/edit, filtered search, date browsing, pin, trash/undo, drafts, local attachment persistence and explicit AI configuration/context boundaries.
3. Inspect actual screenshots against the original layout: empty/populated, editor, note detail, archive, drawer, Chinese/English/dark/large text. No layout-quality claims from unit tests.
4. Local core suite, dependency contracts, doctor and applicable host tests. Independent review for data safety, action recovery, accessibility and UI.
5. PR linked to #946/GET-326, current-head CI. Release follows the existing authorized TestFlight workflow only after this correction is verified.

## Risks and boundaries

- Original views are tightly coupled to cloud-aware services; adapt their interaction and pure presentation patterns into the current local app instead of relinking the legacy runtime.
- Voice recording is local. Do not silently invoke the removed transcription provider or send notes to a model.
- No permanent-delete surface. Trash preserves attachments and original Markdown; undo must be conflict-safe.
- Real-device, real-provider and Files/iCloud-provider claims require independent evidence beyond simulator fixtures.
