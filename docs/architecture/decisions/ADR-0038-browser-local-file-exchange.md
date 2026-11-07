# ADR-0038: Explicit file exchange into browser-local notebooks

- Status: Accepted destination; implementation candidate, browser acceptance pending
- Decision date: 2026-11-07
- Tracking: GET-443, GitHub issue #979 / PR #983 (parent-owned)

## Decision

The user selected storage in the current browser, continuing through file
exchange. `/notebooks` is a separate read-only library. It does not create legacy
cloud memos, upload files, enqueue compilation, call AI, or change Auth/RLS/DB
schema. The ordinary Supabase client verifies identity metadata only; selected
filenames, manifests, digests, text and assets remain in this browser even after
confirmation. Existing server layout reads retain their existing scope.

An import belongs to the tuple of public Supabase project realm, verified
`auth.getUser().id`, and a fresh local namespace. Email and original memo IDs
are not storage identities. This is account separation within the application,
not encryption against someone controlling the browser profile. Browser site
data clearing, private mode, quota/eviction and hardware failure can lose local
data; keep the original export and use exact-file ZIP recovery. No persistence
permission or successful transaction is advertised as a cloud backup.

## Persistence and recovery

The versioned IndexedDB database has four stores: jobs, immutable Blob files,
derived items and immutable receipts. Selection invokes the shared local preview
validator only. Explicit **Save to this browser** confirmation revalidates private
byte copies and creates a durable pending job before copying original files.
Each Blob is added under an immutable owner/namespace/path key, then read back
and SHA256-checked. Hashing/Blob reads run outside IndexedDB transactions.

One final transaction checks the job and immutable file generations, then publishes
all derived items, receipt and committed visibility together. Cross-tab writers
serialize through the same stores and unique owner/export-ID index. Exact retry
returns the original receipt/namespace; changed content, original manifest bytes
or parser version under the same export ID is a conflict. Cancellation/quota
keeps an already-created pending job; resumption requires the same complete
source. Explicit discard deletes only that owner's pending namespace, never a
published notebook or its source export.

Server components pass only verified UID and public project realm. Client-side
`getUser` must verify before unlocking, and before file operations. A different
or signed-out auth event synchronously hides content, revokes owner epochs and
aborts this consumer's active transactions; an unchanged-owner token refresh
does not itself replace ownership. Focus rechecks identity without resetting
valid in-flight work. An old-owner commit that completed before cancellation
remains its old owner's receipt and cannot acknowledge success for a new owner.

Cold reads verify original files and derive/compare item projections again.
Note/review body and metadata render as escaped text, with current/changed/missing
citation status confined to the imported notebook. External markup/media URLs
do not load. Attachments require an explicit local preview action and a bounded
recognized presentation signature or plain UTF8 text; unsupported formats retain
their original download. All originals can be recovered through a UTF8 STORE
ZIP with CRC32 and unchanged paths/bytes. The source payload limit is50MiB plus
the separately bounded256KiB original manifest; ZIP headers/names add bounded
container overhead (at most1001 entries,512UTF8 bytes per path). No ZIP64,
compression, reconstruction of raw memos, or partial archive labeled complete.
Preparation exposes an owned Blob download link; the final save is a real user
click rather than a scripted download that may lose browser gesture permission.

## Validation boundaries

Root owns the shared v1 schema, raw/typed note and manual-review parity, timestamp
projection and cross-surface fixtures. A local consumer does not establish that
all parity checks are finished; review parity remains a separate gate until its
own current-source tests and independent review pass. No Core/Mac/Auth/cloud
model, permission or dependency is changed by this decision.

Lightweight source gate:

```sh
cd web
node --experimental-strip-types --test scripts/file-exchange-local.node.mjs
```

Real Chromium IDB gate source (only after resource/pause checks; existing installed
dependencies and browser required, no automatic install):

```sh
GET443_BROWSER_RUN=1 node scripts/file-exchange-local-idb.browser.mjs
```

Optional `GET443_TOOLCHAIN_PACKAGE` selects an absolute existing package.json
for read-only Playwright/TypeScript resolution; the default is this Web package.
`GET443_BROWSER_CHANNEL=chrome` selects an existing installed Chrome, and
`GET443_ARTIFACT_DIR` selects the registered test-artifact root. None installs
dependencies or browsers. The gate creates its own unique persistent profile,
closes and verifies the first browser process exit, then opens the same profile
at the same loopback origin and compares notes/reviews/manifest/all original bytes.
It never attaches to an existing user profile. Only owned temporary profile and
server resources are closed; logs/snapshots remain outside source. Cleanup failure
fails the gate without masking an earlier test error.

The gate also checks cancellation/pending resume, real Chromium quota refusal,
cross-tab publication/replay/discard, ownership and transaction abort. Quota
metadata is read before/after override; the verified Chrome quota allowance cache
expires before the write assertion. A committed control notebook and pending job
must remain unchanged. An injection failure remains red while independent
process-restart evidence is still retained. The fixture server permits only known
static GET/HEAD requests without queries and blocks all outside requests.
It does not load Next, sign in to the product, or prove UI/auth acceptance.
Full current-head Web lint/types, real browser auth-switch/preview/confirm/reopen,
original download extraction and narrow layout acceptance remain required before
declaring the consumer delivered. Under a disk pause these are reported as pending,
never replaced by memory-fake success.

## Sources

- [Next16.2.6 client boundary](https://github.com/vercel/next.js/blob/v16.2.6/docs/01-app/03-api-reference/01-directives/use-client.mdx)
- [Next16.2.6 authentication guide](https://github.com/vercel/next.js/blob/v16.2.6/docs/01-app/02-guides/authentication.mdx)
- [IndexedDB transaction lifetime](https://developer.mozilla.org/en-US/docs/Web/API/IDBTransaction)
- [Supabase auth events](https://supabase.com/docs/reference/javascript/auth-onauthstatechange)
