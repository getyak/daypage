# Local Watch capture and personal iCloud continuity

Owner request: restore the old Watch/iCloud designs in the current local app, implement automatically delivered Watch voice notes, and allow optional iCloud sync/backup with room for other platforms. GET-392 / GitHub #969.

## Decisions and alternatives

Keep `Documents/vault` authoritative and available offline. WatchConnectivity delivers original audio directly to the paired phone. Optional iCloud Drive carries immutable, content-addressed note revisions and attachment objects. This restores the intent of `tasks/design-watch-recording.md` and `tasks/design-icloud-sync.md`, without reintroducing the archived service runtime.

Moving the live Vault into iCloud would make account loss and placeholder downloads affect ordinary capture. CloudKit would require a separate record model and reduce file portability. Neither is selected. The implementation choice is local Vault plus a provider-neutral revision transport; it is an engineering decision under the owner's autonomous implementation instruction.

## Watch experience

One large record/stop control, elapsed time, haptics, a short recent-recordings list and clear local/delivered states. Save AAC original audio and metadata durably before enqueueing. Retain audio after transport completion until an application receipt containing the recording UUID and content digest proves the phone persisted it. Persist an inbox synchronously before returning from WCSession's ephemeral-file callback. Import uses the recording UUID as the memo UUID; replay never creates a duplicate, including after trashing. Retry on activation, reachability and foreground. System scheduling gives eventual delivery, not a guaranteed latency. No cloud transcription or credentials on Watch.

Phone import creates a voice card immediately. Optional on-device Speech recognition requires explicit permission and `requiresOnDeviceRecognition`; unsupported locales, denial or failure keep the original voice card. No network fallback. App launch, background Watch delivery and foreground resume use the same durable inbox.

## Revision transport

Version 1: immutable JSON revisions (`key`, `parents`, original Markdown or tombstone, attachment digests), SHA-256 addressed objects and revision IDs. A key is the original namespace plus memo UUID. Unknown YAML remains byte-preserved. Hashes validate transport integrity, not authenticity. Directory/iCloud is an adapter, not a core dependency.

Local changes make child revisions; missing local materializations make tombstones. Concurrent heads remain separate recoverable conflict copies. Never select by wall-clock time. The local index maps materialized entries to revision heads. A durable apply journal resumes interrupted integration before detecting fresh local changes. Each write checks the expected original record; stale UI/sync writes fail instead of replacing newer content. Missing objects/parents postpone integration. Malformed versions/paths/symlinks fail closed. There is no automatic history pruning.

## iCloud and recovery

Off by default. Resolve the explicit `iCloud.com.daypage.app` container off the main thread. Discover changes with NSMetadataQuery; request placeholder downloads and retry when results update. Save locally first, coalesce sync after mutations, run on foreground, retry transient failures without deleting local content. Sign-out/account changes stop the session and require re-enabling for the new account; in-flight results must not cross identities. Credentials and capture drafts do not enter the transport.

Settings show availability, pending/error state, last successful local exchange, sync now and revision recovery. “Exchange succeeded” must not claim Apple finished remote upload. Restore a historical revision as a separate imported copy, including audio; do not rewind or overwrite current notes. Older iCloud Vaults retain explicit Files import, with originals untouched. Version history covers notes and attachments after enabling, excluding chats, characters, keys, drafts and already-trashed notes; label this explicitly rather than promising a full app backup.

Account identity scopes cache/index/journal, and every coordinated Store commit revalidates the lease. Journal intent is persisted before each raw operation; ambiguous recovery preserves a branch (possibly an extra old-value copy after write-before-commit interruption). A valid trash receipt distinguishes a user deletion from an insertion that never committed. Watch recovery excludes active AVAudioRecorder files. Background transition ends/saves the recording; continuous lock-screen/wrist-down capture needs separate device evidence.

## Boundaries and gates

iOS 16.1+, watchOS 9+. No new third-party dependencies, DayPage login, custom backend, provider-key sync, distribution or TestFlight. New sidecars are additive; raw Vault compatibility remains unchanged. Owned paths: DayPageCore sync/Watch models and tests, DayPageLocal adapters/settings/project, new DayPageLocalWatch, local contracts/CI and current docs. Forbidden: legacy clients, user Vaults, credentials, production and unrelated worktrees.

Host tests: Watch replay/receipt digest, original-byte preservation, independent edits, update/delete conflicts, attachment integrity, missing parents, interrupted apply, stale edits, idempotent restore and hostile paths. Native build and UI gates cover both targets. Real paired devices and a signed iCloud account are mandatory acceptance for background delivery/account changes; simulator/host evidence cannot substitute. The active host resource pause prevents heavy native work until cleared; preserve it and keep the PR unmerged while required gates remain unproven.

Apple references: [Watch file callbacks](https://developer.apple.com/documentation/watchconnectivity/wcsessiondelegate/session(_:didreceive:)), [iCloud documents](https://developer.apple.com/documentation/uikit/synchronizing-documents-in-the-icloud-environment), [on-device Speech](https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition).
