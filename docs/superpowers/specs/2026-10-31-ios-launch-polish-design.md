# DayPage local iOS launch experience

The user requests a coherent App Store quality pass across all current local iOS pages, with flexible card swipes, lightweight personal AI, record-aware date selection, a distinct Archive, useful sharing styles and reliable journeys at data/permission/failure boundaries.

## Direction and scope

Retain ADR-0028's warm paper, amber controls, serif reading and local-only files. Make Today the stable home; every secondary page exposes a direct return to Today. Search is a separate, dismissible task that returns to the page that opened it. Archive is for chronological rediscovery, with a summary and month grouping before optional filters. Preserve sidebar destinations Archive, Feedback and Settings.

Alternatives considered: adding more controls to the existing archive leaves search and browsing indistinguishable; adopting a new tab/navigation system discards the established capture-first structure. Selected by the agent under the user's standing autonomous implementation instructions: preserve the shell, separate search and browsing, use native list swipe actions and focused modal workflows.

## Observable behavior

1. Today, Archive, Settings and Feedback share a quiet shell. Secondary pages have visible Today navigation. Search has its own title, focused query, clear/cancel and results; closing returns to the originating page and preserves browsing state. Note detail uses the native back path. Capture belongs to Today and Archive, and does not cover search controls.
2. Cards support both swipe directions through native List rows on iOS 16.1+: leading pin/unpin and note chat; trailing share and recoverable Trash. Full swipe never deletes. A visible menu and accessibility actions provide equivalents without gestures. Selection suppresses card interaction. Preserve expand/collapse, attachment preview and long-press actions.
3. The date sheet displays a Gregorian month grid with localized month/day labels, previous/next month, Today, count/dot markings and a selected-day count. Empty dates remain selectable. Cancel makes no changes; Done commits exactly the selection. Dates and counts use the canonical local day, including year/leap-day boundaries. VoiceOver announces date and note count. Large text and narrow widths remain operable.
4. Archive defaults to browse, not a search box. A summary and grouped notes provide place and scale; date/type/tag/pinned filters have clear labels, a reset action and accurate result counts. Empty vault and no matches offer different recovery. Loading/read failure are explicit. Pre-group visible entries in one pass instead of scanning every entry for every day. Stable IDs and lazy rows support thousands of notes.
5. AI remains optional and sends only on explicit Send. An unconfigured chat explains setup and opens settings without losing the draft. Configured chat shows its model and chosen note scope, gracefully handles an empty notebook/selection, offers local draft-only suggestions, and preserves cancellation/failure recovery. AI settings changes refresh the same chat. No automatic provider call, new account, bundled key or note transmission.
6. Sharing opens a dedicated preview from both card and detail. Offer paper/ink/minimal visual styles, date visibility and image/text/original-with-attachments formats. Explicitly explain whether attachments are included. Export cannot silently truncate long content; retain a complete-text/original alternative and bound image memory. Rendering failure stays in the preview with retry. Never mutate notes or attach private metadata unexpectedly.

## Constraints and ownership

- Deployment floor iOS 16.1; no new dependency, persistence-format change or migration.
- Owned: DayPageLocal, DayPageCore presentation/query helpers and tests, DayPageLocalUITests, active engineering docs and project source list.
- Forbidden: legacy clients/DayPageKit, cloud/backend/web, real vaults, release configuration, credentials and unrelated output/.
- Store submission and TestFlight upload are separate workflows and are not implied by this preparation task.
- Preserve all draft, trash, edit and source-privacy boundaries and existing recovery tests.

## Validation

Run the full core suite and active-project contracts. Test native journeys on managed Primary iPhone serially, including search return, Archive filters/selection/trash, both swipe directions, calendar record markers and cancellation, AI setup/draft and explicit fixture send, share preview/style/format, offline save/relaunch and long notes. Capture synthetic screenshots in English/Chinese, light/dark and large text. Use the managed compact/iPad pools when available; do not disrupt another session. Independently review the whole diff, then current-commit CI before merge. Keep local tests, CI, merge, actual provider/device and Apple acceptance distinct.
