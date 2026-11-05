# Local Watch capture and optional iCloud continuity

GET-392 / GitHub #969. Implementation branch; native and real-device acceptance is pending. See [ADR-0032](../architecture/decisions/ADR-0032-local-watch-and-personal-replication.md).

## What the user sees

Watch: one record/stop button, elapsed time, haptics, recent recordings with playback and separate “Saved on Watch” / “In DayPage” states. The Record a note App Shortcut opens the app and starts recording after microphone permission. A background transition ends and saves a recording; uninterrupted lock-screen/wrist-down capture is not promised. Recording stops at five minutes. Interrupted originals stay in a durable drafts directory and are recovered only after AVAudioRecorder has released the file.

Phone Settings → Devices & iCloud: Watch delivery status, optional on-device transcription, optional iCloud Drive sync, exchange status and saved versions. Chinese and English interfaces are included. Recording/import/playback need no DayPage account, key or server. On-device transcription is opt-in, requires Speech permission and supported on-device locale/model availability, and runs while DayPage is open. There is no network STT fallback.

iCloud is off by default. Enabling it copies local notes and attachments to the current Apple ID's `iCloud.com.daypage.app` container and merges its DayPage revisions into the local notebook. iCloud uses Apple's servers. Closing the app does not guarantee immediate remote delivery. “Local exchange complete” does not mean Apple's upload completed.

## Ownership and durability

- Live source: `Documents/vault/raw/YYYY-MM-DD.md`, with compatible existing separators, YAML and assets. Unknown YAML remains intact. Imported notes retain namespace boundaries.
- Watch: `Documents/WatchNotebook/drafts` and `outbox`. Original AAC audio is staged with UUID, recording time, duration and SHA-256 digest before enqueueing. Original copies are retained, including delivered audio; automatic retention/pruning is deliberately absent in v1.
- Phone: `.daypage-watch-inbox/received` envelopes are persisted synchronously before the ephemeral WatchConnectivity callback returns. The canonical capture inbox survives process death. A receipt is created only after a memo and its attachment exist. Receipt UUID+digest must match. Replay, lost receipt and replay after trash do not duplicate notes. Queued receipt flags prevent resending the full history on every resume; explicit Watch receipt requests can still query history.
- Replication: account-scoped `.daypage-continuity/<scope>` holds immutable cache, local materialization index and apply journal. Cached data never contains model credentials or provider keys.
- Remote: `Documents/DayPageContinuity/v1/revisions/<digest>.json` and `objects/<digest>`. Original older `Documents/vault` content is not moved, replaced or automatically migrated. Use the existing Files import for a downloaded old Vault.

An iCloud identity change revokes the old lease, cancels tasks, stops metadata discovery and disables sync. The user must enable it again after seeing that the current local Vault will be copied to the new account. Each account uses a separate scope. Lease/cancellation checks run in the transport and inside the Store's coordinated commit, rather than only before an async call.

### Legacy Watch upgrade recovery

The archived Watch sends `type=watchAudio/source=daypage-watch` and deletes its source on WC transport success. The phone therefore moves that ephemeral file synchronously into a random-name legacy spool before reading, hashing or decoding it. Conversion errors, missing metadata and clips outside current admission limits retain the original spool file. The background drain retries coalesced arrivals, derives a stable content UUID and copies usable audio into the canonical inbox. Existing legacy `watch_<sha>.m4a` references are hash-verified across live/trash entries, preserving their memo UUID and deletion intent. Small date/duration probe differences retain the first canonical metadata.

On the Watch, eligible old `tmp/com.daypage.watch/watch_*.m4a` recordings are copied into the durable outbox at activation, without deleting or rewriting the old path. New capture/legacy recovery remain mutually exclusive. This is an additive recovery plan, not an in-place format migration. Corrupt or unsupported old clips remain for recovery; paired upgrade ordering still needs real-device acceptance.

## Merge and recovery

Each revision identifies `namespace/memoUUID`, a sorted parent list, the original Markdown/day or a tombstone, and attachment content hashes. Reject duplicate logical identities across days before publishing, malformed versions, path traversal, symlinks, oversized objects, missing parents and mismatched hashes. Download/verify required objects before applying. The revision DAG, rather than wall-clock time, identifies concurrent heads. Both live heads become visible copies with stable namespaces; deletion racing with an edit preserves the edit. Historical revisions are retained.

Reject namespace case aliases at every prefix in the graph, materialization plan and Store commit. Recheck actual directory spellings, including empty directories, inside coordinated writes; an expected-missing record cannot replace an existing UUID. A standalone lowercase namespace remains compatible. Validate a pulled graph before persisting its revision JSON, so correcting an invalid remote graph also recovers the next exchange instead of poisoning the local cache.

Before raw integration, persist a journal and an intent marker per operation. Recover by comparing the current record with its expected/target fingerprints. A changed value becomes a branch; a valid local trash receipt preserves deletion of a newly downloaded note. A nonnil ambiguous value after a marked operation is conservatively preserved, including a user restore of the old value. A crash between marking intent and writing may therefore retain an extra old-value branch. A missing new record without trash evidence is safely re-downloaded rather than being mistaken for a deletion. This avoids turning a write-before-commit interruption into deletion on every other device.

Saved versions recover as separate deterministic imported copies, with original audio; repeated selection is idempotent. This is **notes and attachments version history**, not a complete app backup. Chats, characters, note relationships/action receipts, model keys, unfinished capture drafts and notes trashed before sync was enabled are excluded. Relationships and operation history stay on the local device. The existing notebook file export remains the way to copy the full on-disk Vault, including local relationships; credentials remain device-only.

No automatic history collection or pruning. Metadata discovery plus coalesced mutations/foreground activation drives exchange; errors retry after 30 seconds, subject to system suspension. A running exchange retains a dirty flag for another pass. Large libraries and long histories need capacity/performance acceptance before a release: the current core scans metadata and uses mapped attachment reads where safe, but is not a streaming engine.

## Extension boundary

`ReplicaTransport` supplies revision discovery and immutable object read/write. A future folder, WebDAV, Android or desktop adapter must preserve the version-1 records, ancestry, hashes and idempotency. iCloud URL discovery, identity and credentials stay outside the engine. A transport implementation alone does not establish a working Android/Web product, and no such adapter is shipped here.

The v1 revision ID is SHA-256 of the typed revision encoded by Foundation `JSONEncoder` with `.sortedKeys`; the writer must preserve its string escaping and omission of nil fields. Attachment hashes cover original bytes. Foreign writers require canonical encoding/fixture compatibility tests before activation; a future incompatible canonicalization must use a new protocol version. Hashes provide integrity, not user authentication or additional encryption; remote access is governed by the selected provider.

## Verification and remaining acceptance

Host tests cover round-trip original Markdown/assets, Watch replay/receipt mismatch, two-device edits/deletions/concurrent edits, stale writes, missing dependencies, historical restore, cross-day UUID ambiguity, and interruptions followed by edit/delete/restore. Local contracts allow only the new Watch capture package and personal CloudDocuments entitlements while continuing to exclude the archived cloud runtime. Lightweight SDK type checks check the new adapters and Watch SwiftUI sources; they do not link, sign, package or launch an app.

The release configuration now enumerates both local targets and requires exact profiles for `com.daypage.app` and `com.daypage.app.watchkitapp` before archive/export. Isolated Ruby tests stub every external operation, including match, keychain and uploads. No release lane or provisioning mutation was run for this feature; future signed acceptance must verify both profiles and the main app's CloudDocuments entitlement.

Required before merging/releasing: exact-source full iOS/watchOS builds and existing UI gates; real paired Watch/iPhone foreground/background/cold-launch delivery, receipt-loss replay, interruption and shortcut orderings; signed iCloud opt-in, two-device exchange, download placeholders, offline recovery, sign-out/account switch while upload/apply runs; accessibility and small Watch sizes; storage/capacity sampling. Real Apple account/provider behavior cannot be established by isolated folder tests. TestFlight/App Store publication is separately authorized work.

Rollback: disable the opt-in provider and retain all local Vault/cache files; revert the feature commit without deleting original user data or the old source archive. The host's active resource pause is preserved; no new Simulator devices are created or shared devices stopped.
