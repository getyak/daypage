# ADR-0034: Manual reviews and explicit file exchange

Status: Accepted scope for GET-442 / #978; implementation awaits independent
review and hosted/native acceptance. The owner chose the local-first option A.

## Decision

The active Local app offers manually generated day/week review pages and explicit
folder exchange. This extends ADR-0027/0032 without restoring the legacy account,
Supabase, scheduled compilation or automatic client linking pipeline.

A day/week is frozen to the selected local calendar interval and time zone. Weeks
start Monday; the end instant is exclusive, including daylight-saving changes.
The person previews and selects at most 12 notes, enables the request, and presses
Generate. Only selected body text, source labels and dates are sent through the
existing configured BYOK transport. Attachments, transcripts, location metadata,
other notes and historical chats are not added as context. There is no automatic
generation, model discovery or credential read when opening the feature.

Revocation, configuration/selection changes and cancellation invalidate late
results and Save authority. Source revisions are checked before/after generation
and during coordinated publication. The person edits and explicitly saves the
result. Each immutable generation is a separate
`wiki/manual-reviews/<generation-UUID>.md` file, outside canonical raw notes.
Its versioned bounded header records period, source identities/revisions and
digests; the readable body and source links follow. Original raw/draft files are
preserved. Historical citations remain historical after source edits/deletion.

## Versioned exchange

The owning [v1 contract](../../contracts/file-exchange-v1.md) and JSON Schema use
canonical raw memo bytes, referenced original assets, optional manual pages and
a typed `records.json` projection. The manifest lists exact paths, byte counts and
SHA-256 values. Its stable `content_sha256` permits resuming an unchanged legacy
Vault without relying on a newly generated export ID/time.

Typed timestamps explicitly project to nearest milliseconds, with ties away
from zero; whole seconds remain whole and other producer values have three
fractional digits. Notes use original decimal raw scalars before parser clipping.
Review JSON Date metadata keeps its full original precision/bytes; only its
typed clock uses the declared reference-seconds-to-Unix projection in the wire
contract. Do not call that wire clock lossless, or let Date.parse clipping make
contradictory typed sub-millisecond digits look equal. This clarifies the draft
contract without changing the frozen fixture or any stored source format.

Every typed raw-note field is checked against the production Memo decoder and
the **individual exact raw memo block** SHA, not just the whole day-file hash.
External namespaces use physical `imports/<UUID>/...` paths; Core's logical UUID
chain is mapped explicitly at the boundary. Historical review revisions need not
match a later source revision. A bundle is not authentication or proof that a
provider request ran.

Selection first creates a bounded app-owned pending copy, with a durable plan
before payload writes. Opening/previewing does not publish live notes. Confirmation
atomically creates a fresh import namespace; source and existing notes are never
overwritten. A private nonce receipt makes restart cleanup idempotent. Incomplete
or unreadable jobs remain visible for reselecting the same source or explicit
discard. Unlisted sidecars, links, path aliases/traversal, unknown versions/fields,
hash/typed/raw mismatch and out-of-limit input fail closed. No automatic network
or synchronization is started by the exchange service. If the person previously
enabled personal iCloud replication, newly imported notes participate under those
existing settings; the UI discloses this before confirmation.

## Compatibility, migration and rollback

The raw format and existing full-Vault backup remain unchanged. Legacy folders
are projected into the same preview/confirmation flow; runtime/chat/draft files
are not copied into an exchange. Files and review Markdown are readable with Mac
file tools, and Core supports macOS 13. This is not evidence of a Mac App exchange
UI: its legacy DayPageKit host needs its own explicit adapter. Web consumption is
GET-443 / #979 and must use the current authenticated owner/RLS contract after a
separate preview, never the old email/Drizzle upload route.

There is no in-place migration. Removing this feature leaves ordinary raw/import
files readable; manual pages and pending recovery copies remain on disk. Rollback
must preserve those files and allow re-enabling the feature to resume/discard
pending jobs. Old clients may not list manual pages; they remain ordinary Markdown
files. Imported copies can be inspected before any later user-directed removal.

## Verification boundary

Synthetic tests cover time zones/DST, exact source context, consent/cancellation,
source changes, save collisions, byte preservation, manifest/typed/raw parity,
attachments, legacy folders, namespace isolation and interrupted import recovery.
The cross-client fixture contains only synthetic notes/assets. Hosted core/app CI
and independent review are required before merge. Files provider interaction,
device interruption, VoiceOver, actual provider requests and actual Mac/Web host
behavior require surface-specific acceptance; format fixtures alone do not prove
those user flows.
