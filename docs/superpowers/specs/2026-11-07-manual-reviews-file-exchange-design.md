# Manual reviews and explicit file exchange

GET-442 / GitHub #978, implementing the owner's choice A. Keep the independent
local app, explicit BYOK requests, canonical raw files and optional existing
iCloud/Watch behavior. No background generation, account linking, database,
automatic upload, dependency install or real-data migration.

## Manual day/week review

The person chooses a local calendar day or Monday-based week, sees the frozen
time zone and individual selected text sources, explicitly enables this request,
and taps Generate. The exact context is bounded to 12 notes / 18,000 characters /
72 KiB, with no attachment bytes or automatic truncation. Existing AIClient and
origin-scoped Keychain behavior are reused only at that explicit action.

Cancellation, consent/config changes and new selections revoke the generation
lease. Selected source revisions are checked before the request, after its reply
and at Save. Output is a preview; Save creates a separate versioned Markdown page
with generation UUID, range/time zone, immutable source references/digests and
provenance. It never rewrites raw notes, ordinary drafts or legacy daily pages.
Saved pages can be read/exported as Markdown and are not future raw-note inputs.

## Explicit exchange

Keep existing canonical raw Markdown and namespaced imports. A versioned folder
manifest enumerates only selected raw record files, referenced attachment bytes
and saved manual pages; each path has a digest/size. Do not copy credentials,
runtime files, private chat/draft sidecars or arbitrary selected-folder contents.
The original full-Vault backup remains a separate existing operation.

Export previews scope/count/bytes before opening the file destination chooser.
Import first copies/validates into an isolated pending job, then previews source
and a new UUID namespace; only Confirm publishes it. Conflicts never overwrite
existing notes. Interrupted jobs remain listed for resume with the same selected
source or explicit discard; completed publication is idempotent by manifest.

Mac's RawStorage consumes the same raw/YAML/separator layout. Web has no folder
import consumer today: compatibility means a checked projection to its memo DTO,
not a claim that a Web account is linked or that its UI opens a whole Vault.

## Verification

Synthetic host regressions cover time zones/DST, scope/limits, request-before-
consent, revoked leases/late replies, source changes, save identity and failures;
exchange round trips, paths/links, hashes, duplicate identities, conflicts and
restart recovery. Existing privacy/dependency/static format gates remain. Source
and lightweight static work are allowed under the root pause; no local Swift,
native build, package installation, browser, real Vault or live provider work.
