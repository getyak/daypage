# GET-442 / GET-443 explicit file exchange contract v1

Frozen interface for parallel Local/Mac and Web implementation. Schema definitions
`manifest` and `records` are in [file-exchange-v1.schema.json](file-exchange-v1.schema.json). The folder has
daypage-exchange.json (manifest), records.json (version/notes/reviews), canonical
raw records and referenced original assets; optional wiki/manual-reviews Markdown.

## Timestamp projection and comparison

Typed timestamp fields are an explicit **nearest-millisecond projection**, with
ties away from zero on the UTC Unix timeline. Producers emit UTC RFC3339: whole
seconds have no fractional suffix; other values have exactly three digits.
Preserve existing Memo milliseconds, normalize offsets and carry into the next
second when rounding requires it. For note created/pinned fields, derive the
projection from the original decimal raw scalar, before a date parser can clip
sub-millisecond digits. Raw memo bytes/revisions are never rewritten.

Accepted scalar spelling uses `T`/`Z` case-insensitively or a signed `HH:MM`
offset; producers use uppercase.
Offset hours are 00–23 and minutes 00–59; apply that offset before rounding.
There is no separate fraction-length cap inside the existing payload budgets.
Validate the whole Gregorian civil time rather than normalizing invalid dates;
this codec does not represent leap seconds. The resulting UTC clock must fit
years 0001–9999. Unsupported/absent raw created/pinned timestamps fail exchange
admission instead of inventing the current time; ordinary legacy read policy
remains separate. The raw filename's owning day is not recomputed after rounding.

Review Markdown metadata uses Foundation JSON Date: an IEEE-754 binary64 number
of seconds since 2001-01-01 UTC. The corresponding typed clock is computed in
this order: `(reference_seconds + 978307200) * 1000`, then round to the nearest
integer with ties away from zero. Its higher original precision stays intact in
the unchanged raw review metadata. Wire timestamps are **not lossless clocks**;
the manifest's exact bytes/hash preserve the higher precision for recovery.

A consumer must compare against that declared projection, not call Date.parse
on both values and accept its silent clipping. Nonzero digits after the third
fractional place in a typed timestamp are a contradiction, even when Date.parse
would yield the same millisecond. Exact-zero padding/offset aliases can be
normalized when supported; producers still use the canonical UTC whole/three-digit
form. Historical source revisions are not recomputed from projected timestamps.

The synthetic fixture below remains byte-for-byte unchanged; new timestamp
regressions use separate isolated raw/review fixtures, including `.123Z`, decimal
carry/offsets, pre-epoch ties, review microseconds and contradictory typed digits.
Shared independent expected values are in
`DayPageCore/Tests/DayPageCoreTests/Fixtures/exchange-timestamp-projection-v1.json`.
The negative review JSON example deliberately rounds differently from an exact
decimal raw `...59.9995Z`: JSON Date is first a binary64 reference-seconds number,
whereas the raw RFC3339 fraction is rounded as original decimal digits.

## Payload limits and authority

Caps: manifest 256 KiB; records.json 16 MiB; total listed payload 50 MiB; 1,000
files; 500 notes; 100 reviews; per attachment 25 MiB; per review body 64 KiB. No
silent truncation. At least one note or review. Manifest counts must equal records.

Reject absolute paths, backslashes, controls, empty/dot/dot-dot components, links,
duplicate paths, duplicate namespace+original_id, duplicate namespace+generation_id,
unlisted files used as data, missing/size/hash mismatches and unknown versions.
Only records.json, (imports/UUID/)*raw/YYYY-MM-DD.md, (imports/UUID/)*raw/assets/*,
and (imports/UUID/)*wiki/manual-reviews/UUID.md are permitted. Namespace is empty
or repeated imports/UUID pairs. Do not accept any account, user_id or credential
from a bundle as authority. Paths are root-relative and case-preserving.

Note type is the Local raw type (text/voice/photo/location/mixed), not an already
authorized Web DTO. Web adapts it to its memo contract after explicit preview;
image-only/empty-body notes and mixed attachments must not be silently dropped or
filled with invented factual prose. Attachment.file is the full bundle-relative
path including namespace; its hash/size must match an asset manifest entry.

Review records are immutable generation metadata plus body. Start/end are exact
inclusive/exclusive instants, with frozen time_zone; source citations retain their
original local namespace/path identity and revision. Do not treat imported review
metadata as cloud authentication or evidence of a current provider execution.

No request before the person's explicit confirmation. Web derives the current
owner from its session, stages uploads under that owner, uses idempotent receipts,
and never overwrites a different existing record just because UUID matches.
Local confirms into a fresh UUID import namespace, preserving source and current
Vault. No automatic AI, compilation, account linking, sync or runtime migration.

For resume identity, compare canonical payload content (records plus file
path/kind/bytes/hash list); export_id/created_at may differ when re-selecting a
legacy unmanifested Vault with unchanged contents. For supplied v1 manifests,
keep export_id as additional provenance, not as permission to upsert arbitrary IDs.

`content_sha256` is required. Hash these UTF-8 bytes exactly, with no final newline:
format + LF + decimal(notes_count) + NUL + decimal(reviews_count) + LF +
files sorted by path's UTF-8 byte order, each represented by
path + NUL + kind + NUL + decimal(bytes) + NUL + sha256, joined by LF.
Paths reject all control characters, so these separators are unambiguous. Do not
use locale sorting or JSON reserialization to compute this cross-client identity.

Synthetic interoperable example: `DayPageCore/Tests/DayPageCoreTests/Fixtures/file-exchange-v1/`
in this repository. It has one mixed note and one plain-text attachment, no private
data. Both the raw record and typed records.json represent the same source.
