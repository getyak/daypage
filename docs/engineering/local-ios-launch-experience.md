# Local iOS launch experience

Scope: [GitHub #950](https://github.com/getyak/daypage/issues/950), the active `DayPageLocal` app. This prepares the current local experience; it does not submit a public App Store version or publish a TestFlight build. Broader distribution work remains separate in [#922](https://github.com/getyak/daypage/issues/922).

## Navigation and capture

Today remains home. Archive, Settings and Feedback expose a direct Today action while retaining the drawer. Search opens its own dismissible navigation stack; its query does not filter the underlying Archive. Closing search returns to its origin, and note detail retains native back navigation.

Archive is chronological browsing with an overview, date/type/tag/pinned filters and explicit reset. Empty notebooks, empty search results, loading and file-read failures have distinct states. A transient catalog caches tags, day counts and unfiltered groups; filtered results group records in one pass. It is not another persistence store.

Cards are native List rows on iOS 16.1 and later. Swipe right exposes pin/unpin and scoped chat; swipe left exposes previewed sharing and recoverable Trash. Full swipe does not act. A visible menu and accessibility actions expose the same abilities. Selection disables gestures and content navigation. Capture drafts and edited-note drafts retain their existing independent recovery paths.

New notes record the present moment. When saving from a historical date or Archive, return to Today so the saved note stays visible; editing an existing note preserves its reading location. Reading cards stay within a 760-point column on wider layouts.

## Dates

The calendar stages changes until Done. Each saved date has a record dot; the selected date displays its count. Empty dates can be selected. Cancel and accessibility escape leave the original selection unchanged. Month paging, leap days, alternate user calendars and local time zones use strict Gregorian file identities. Display labels and first weekday follow locale; date keys do not change to a non-Gregorian year.

## Personal AI

AI is optional. An unconfigured chat opens setup while preserving the question. Empty notebooks and unavailable selections explain why Send is disabled. Suggested questions only fill the local draft. Configured chat shows its model and source excerpts; only explicit Send starts a note-bearing request. Cancellation and request failure preserve the question. Connection tests send no notes. No credentials, providers or background requests are added.

## Sharing

Card and detail actions open the same preview. Paper, Ink and Minimal styles apply to image exports; date visibility is explicit. Text includes every character. Original includes the complete text and listed attachments, without serializing private note YAML. Original attachment files retain their existing metadata, which the preview explains.

Images render at 360 points wide and scale 2, with measured height at most 2,400 points and at most 4 million RGBA pixels before bitmap allocation. More than 4,000 characters or 100 line breaks offers complete Text/Original instead of silently cropping an image. Attachment-only notes default to Original. Missing or unreadable attachments keep the preview open for retry.

## Isolated verification

Use the managed `dev-ios-session` wrapper, Primary iPhone and serial execution, following [local setup](local-ios-notebook.md). Build `DayPageLocal/DayPageLocal.xcodeproj`, scheme `DayPage`. Full source tests live in `DayPageCore/Tests` and `DayPageLocalUITests`.

Debug-only QA additions require both the isolated bundle `com.daypage.app.localqa` and `-qaNotebookSession`:

- `-qaSeedNotebook -qaSeedLargeNotebook`: 360 synthetic records over 120 days, only in the existing isolated QA vault.
- `-qaExportShareImage`: retain the rendered synthetic image as `Documents/qa-shared-note.png` in that QA app for pixel/direction/tail inspection. It has no effect in Release or a normal app session.

The existing loopback fixture verifies actual request/response handling without sending notes to a real provider. Real devices, camera/microphone hardware, signed-device Keychain, external Files providers and real AI providers remain separate acceptance gates. Do not stop a borrowed simulator or bypass the shared-device lease to force compact/iPad evidence.

## Evidence for this task

- Core: 77 tests passed, including 5,000-record grouping/query tests, Gregorian calendar cases and bounded/full-text sharing policy.
- Active project/privacy contracts: 3 passed. Capture-draft recovery: 13 regression groups passed.
- Native Debug build-for-testing passed. Full native journey results and visual evidence are recorded in the linked PR after execution.
- Independent whole-diff review found a shared-query leak between search and Archive; it was fixed and a return regression added. No remaining confirmed findings at that review.
- Actual synthetic Ink image was inspected upright with its complete final line. System share and remaining native flows are checked separately from the pure policy tests.
- Linear MCP was unavailable during this task; no Linear status or linkage was fabricated.
