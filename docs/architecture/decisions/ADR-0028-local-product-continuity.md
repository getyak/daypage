# ADR-0028: Preserve the DayPage product experience on local files

Status: Accepted for the user's October 30, 2026 correction; GitHub #946, related GET-326.

## Context

ADR-0027 established the correct local-only dependency boundary, but its replacement
UI discarded the existing product's interaction hierarchy. The user explicitly
rejected the 0.5.0 screen as demo-like: removing accounts, databases and cloud sync
did not authorize discarding mature capture, reading and browsing behavior.

## Decision

Keep the current independent Xcode project and DayPageCore. Adapt the established
warm paper/amber native presentation into that project instead of importing the
legacy RootView or cloud-aware view models. Today is the initial record stream,
with a compact menu/date/search header and a persistent glass capture dock.
Archive, Feedback and Settings remain the drawer's three destinations; the
notebook identity returns to Today. Long-note reading, date browsing, text/tag/type/
pinned filters and note-scoped or selected-note AI chat retain their own purposes.

Photo/camera/file import and audio recording use Apple's native frameworks.
Capture drafts retain their local attachment bytes across collapse and relaunch.
The recording transfer requires durable-draft acknowledgement: quota or write
failure keeps the recording available to retry. Backgrounding pauses recording;
no provider receives audio automatically. Existing-note edits preserve their
attachments and keep their own recovery drafts; they do not borrow the new-note
attachment draft.

## File operations and recovery

The canonical raw format, filenames, separators and Memo codec stay compatible.
Read entries carry their source block for stale-write checks, including unknown
YAML. Pinning changes only the selected record's pin field. New attachment names
are generated UUIDs under raw/assets, with per-file/count limits and rollback of
new files on raw-write failure. Path and namespace validation applies to assets,
drafts and recovery records, including symlink boundaries.

Deleting a note means recoverable Trash. Hidden recovery records retain the
original day Markdown and selected record metadata; referenced attachments stay
in place. Prepared and committed deletion are distinguished, and restore journals
support interruption/retry without rewriting unrelated notes. Existing identities
or stale originals refuse a destructive replacement. No automatic permanent
purge is introduced.

Capture-draft consumption is tied to the saved note's stable identity, so a failed
post-save cleanup cannot silently attach the same photos/audio to the next note.
Runtime draft/recovery sidecars remain local and excluded from Git. No database,
account, migration of real data or old cloud runtime is introduced.

## Relationship to ADR-0027

This decision supersedes ADR-0027's Archive-as-home and dark-green-spine visual
choices. It preserves that decision's local/AI/privacy boundaries. Historical
graphs, background daily compilation, account dashboards and scheduling are not
silently reactivated by restoring note interactions. Existing files remain
preserved. New AI requests still require explicit Send with the source preview
and existing context/request limits.

## Verification

Use the active local app's build and isolated native UI suite for capture,
collapse/relaunch, edit, search, pin, trash/undo/restore, selection, languages and
appearance. Inspect native screenshots against the saved original product
screens, rather than treating legacy-project CI as new-app visual acceptance.
Core regressions use isolated real files and permissions to cover byte preservation,
namespace conflicts, symlinks, interrupted writes and attachment rollback.
Real device, microphone/camera hardware, external Files providers and real AI
services retain their own acceptance boundaries.
