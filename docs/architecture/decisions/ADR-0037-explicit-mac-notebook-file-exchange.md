# ADR-0037: Explicit Mac notebook file exchange

Status: Accepted scope for GET-446 / #982, source implementation awaiting
independent review, hosted Core/Mac CI and native interaction acceptance.

GET-442 / ADR-0034 delivers the Local iOS consumer and versioned file contract.
The existing Mac host uses DayPageKit and a root-raw Today/Archive reader. Merely
putting new Core namespaces there would hide imported notes from those views and
could mix the new local-first flow with the old account/sync pipeline.

## Decision

Add a permanent **Notebook files** route in MacRootView. Its local adapter is the
small `DayPageMacExchange` package, depending only on the repository's local Core
and Apple frameworks. The old Mac Vault is an explicitly selected read-only
export source. Import always targets the separate local Application Support
`DayPage/ExchangeNotebook` root. The same consumer immediately lists imported
notes across every namespace, original referenced attachments and saved manual
review pages. Existing Today/Archive and cloud behavior are unchanged.

Folder selection creates a pending copy only. Content/count/byte preview and a
separate Confirm action precede publication in a new UUID namespace. Reuse Core's
bounded canonical reader, manifest/typed/raw parity, protected pending state,
same-source resume, receipt retry, explicit discard and collision rejection.
No private runtime/chat sidecars, account credentials or source-auth identifiers
gain authority from an import.

Exports offer explicit source and all/day/week range, then content preview and a
destination chooser. Each preview and FileDocument write uses Core's revocable
selection ticket, including exact date/time zone. Scope/source/date changes and
close revoke queued/late work, independently of disabled controls. Source files
are never rewritten by export. Attachments open only through an explicit system
Quick Look preview resolved by Core's scoped asset path; no automatic playback,
executable launch, transcription, AI request or upload is added.

The adapter never emits the old RawStorage/SyncQueue notifications and has no
legacy storage, cloud, provider or credential dependency. A current account label
in the surrounding Mac shell does not change this feature's local destination.
There is no automatic migration, account linking or synchronization between the
managed exchange notebook and the legacy Mac Vault.

## Compatibility and rollback

Use the exact ADR-0034 exchange contract and original raw memo/asset bytes.
Core is the shared codec; the Mac adapter does not fork it. Imported review
citations remain historical and display changed/unavailable sources honestly.
The Local, Web and Mac user surfaces require separate acceptance evidence.

Rollback removes the route/product dependency without deleting its local root,
pending copies or published namespaces. Re-enabling the feature reopens the same
Core root and recovery inventory. This decision does not migrate old Today data
or grant the old cloud runtime access to new imported copies.

## Verification

Isolated synthetic model tests exercise the actual adapter constructor and
choose/preview/confirm/readback flow, attachment resolution, namespace isolation,
pending restart/resume/discard, collision preservation, explicit read-only legacy
export, late export revocation and saved-review source links. Hosted macOS CI runs
the package tests and actual Mac target build. These are distinct from native
picker/Quick Look/keyboard/accessibility interactions and any signed release.
