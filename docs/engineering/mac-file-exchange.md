# Explicit notebook file exchange on Mac

GET-446 / #982 adds a permanent **Notebook files** consumer to the Mac App.
Source implementation and isolated tests are prepared; hosted CI and real Mac
interaction acceptance remain required before claiming delivery or release.
[ADR-0037](../architecture/decisions/ADR-0037-explicit-mac-notebook-file-exchange.md)
owns the boundary; [ADR-0034](../architecture/decisions/ADR-0034-manual-reviews-explicit-file-exchange.md)
owns the shared versioned format.

## Import and read

Open Notebook files → Choose an exchange or older Vault folder. Use a fully
downloaded folder. Selection verifies a pending copy but does not add live notes.
Read the included text, attachment counts, review pages and byte total, then
Confirm import into a new notebook. Existing/source files are preserved.

Imported notes appear in the same permanent page, including namespace identity,
full selectable original body and explicit attachment preview. Saved manual
review pages retain their generation range/time zone and historical source
references. A changed or missing source is indicated; it is not silently replaced
with a different note bearing the same UUID.

Pending imports remain visible after restart. Review a complete copy, reselect
the same unchanged source to resume an incomplete one, finish an already-published
receipt cleanup, or explicitly discard only the pending copy. A namespace
collision fails without replacing existing files.

## Export and destination

Select either Local exchange notebook or Current Mac Vault (read only), and
All/Day/Week. Preview reads that chosen source only. Verify the included content
and byte total, then Choose export destination. Range/source/date changes revoke
old previews and queued results. Export preserves raw/asset bytes and excludes
runtime/chat/draft sidecars. No credential or AI read is required.

Imports live in Application Support/DayPage/ExchangeNotebook under fresh UUID
namespaces. This local root is separate from the old Today/Archive Vault and the
cloud account displayed in the surrounding shell. Notes imported here are
intentionally read in Notebook files; no automatic account linking or old
SyncQueue admission occurs. To move them elsewhere, explicitly export a folder.

## Evidence boundary

The package's synthetic host tests and Mac target hosted build do not establish
real Files providers, Quick Look interaction, keyboard/VoiceOver, layout or signed
distribution. Native acceptance must separately exercise choose/cancel/preview,
confirm/readback, close/relaunch/recovery, attachment preview and date/source
changes with isolated synthetic files. No production Vault or provider is needed.
