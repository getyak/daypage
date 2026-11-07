# GET-442 / GET-443 explicit file exchange contract v1

Frozen interface for parallel Local/Mac and Web implementation. Schema definitions
`manifest` and `records` are in [file-exchange-v1.schema.json](file-exchange-v1.schema.json). The folder has
daypage-exchange.json (manifest), records.json (version/notes/reviews), canonical
raw records and referenced original assets; optional wiki/manual-reviews Markdown.

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
