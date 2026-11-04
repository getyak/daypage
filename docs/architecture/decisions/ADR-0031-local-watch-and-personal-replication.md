# ADR-0031: Local Watch capture and optional personal replication

Status: Proposed, implemented behind opt-in sync; pending native/device acceptance. GET-392 / #969.

The owner explicitly requested Apple Watch audio continuity and restoration of optional iCloud sync/backup. This supersedes ADR-0027's exclusion of sync destinations only for the newly authorized personal iCloud and paired-Watch adapters. The app retains its local Vault, account-free operation and independence from DayPageKit's archived cloud runtime.

Adopt the [local Watch/iCloud specification](../../superpowers/specs/2026-11-05-local-watch-icloud-design.md). Content-addressed immutable revisions and objects provide a portable transport, explicit ancestry, conflict preservation and historical recovery. File-based local materializations retain the existing raw format. Watch acknowledgements prove local persistence, separately from cloud exchange or transcription.

iCloud is optional Apple-hosted storage, not local-only transport. All recording, import, playback and supported on-device transcription remain local. Never describe iCloud as staying exclusively on the physical device.
