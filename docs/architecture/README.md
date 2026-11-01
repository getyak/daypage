# Architecture

- [System overview](overview.md): current components, ownership, data flow, and trust boundaries.
- [Decisions](decisions/): accepted or proposed durable architecture decisions.
- [ADR-0006](decisions/ADR-0006-repository-agent-team-control-plane.md): development Agent Team control plane.
- [ADR-0007](decisions/ADR-0007-compilation-entity-operation-markers.md): retry-safe entity persistence.
- [ADR-0008](decisions/ADR-0008-local-first-sync-and-cloud-mcp.md): local-first multi-device sync and user-scoped Cloud MCP.
- [ADR-0009](decisions/ADR-0009-native-surfaces-shared-contracts.md): proposed cross-platform native surfaces and shared product contracts.
- [ADR-0010](decisions/ADR-0010-vault-derived-read-models.md): asynchronous disposable read models over the Markdown Vault.
- [ADR-0011](decisions/ADR-0011-action-button-voice-capture.md): superseded primary Action Button voice proposal; retained as a possible separate voice shortcut.
- [ADR-0012](decisions/ADR-0012-action-button-screenshot-capture.md): Action Button screenshot capture, durable ingest, and privacy-gated multimodal understanding.
- [ADR-0013](decisions/ADR-0013-privacy-safe-operational-diagnostics.md): privacy-safe auth and sync diagnostics with user-visible support references.
- [ADR-0014](decisions/ADR-0014-deepseek-harness-host-adapter.md): DeepSeek Harness development-host adapter.
- [ADR-0015](decisions/ADR-0015-stable-memo-detail-and-bounded-media.md): stable memo-detail identity, safe Vault presentation boundaries, and bounded image decoding.
- [ADR-0016](decisions/ADR-0016-revisioned-attachment-sync.md): revisioned local-first attachment synchronization with resumable transfer and garbage collection.
- [ADR-0017](decisions/ADR-0017-apple-system-actions.md): local-first Apple System Actions with native confirmation, device execution, immutable receipts, and bounded agent proposals.
- [Issue #887 verification matrix](../verification-issue-887-apple-system-actions.md): automated gates plus the matching-OS and real-device release checklist.
- [ADR-0018](decisions/ADR-0018-backend-first-agent-data-plane.md): backend-first Agent runs, artifacts, reducers, automations, and approved tool execution over local-first capture.
- [ADR-0019](decisions/ADR-0019-agent-evaluation-learning-plane.md): authoritative feedback/evaluator records, privacy-bounded Opik projection, versioned datasets, experiments, annotation, and promotion gates.
- [ADR-0020](decisions/ADR-0020-imported-media-compatibility.md): imported AAC and QuickTime compatibility with preserved source bytes.
- [ADR-0021](decisions/ADR-0021-private-backend-rls-baseline.md): authenticated account isolation and private attachment access.
- [ADR-0022](decisions/ADR-0022-account-scoped-web-memo-reading.md): account-scoped Web history, keyset reading and private media proxy.
- [ADR-0023](decisions/ADR-0023-account-tag-imports.md): exact imported labels and immutable account import receipts.
- [ADR-0024](decisions/ADR-0024-account-origin-session-binding.md): Apple sync realm binding, session generations and recovery boundaries.
- [ADR-0025](decisions/ADR-0025-native-tag-projection-and-sync-completion.md): native account-tag projection cache, consistency boundary and truthful sync completion.
- [ADR-0026](decisions/ADR-0026-drained-local-compilation-commits.md): off-main local compilation persistence and asynchronous close/drain before scope changes.
- [ADR-0027](decisions/ADR-0027-local-ios-notebook.md): the active local-only notebook and optional personal AI boundary.
- [ADR-0028](decisions/ADR-0028-local-product-continuity.md): preserve the established native notebook experience on local files.
- [ADR-0029](decisions/ADR-0029-personal-ai-provider-presets.md): official direct AI presets and explicit automatic or fixed model selection.

The overview is descriptive and should track executable reality. ADRs explain durable
choices and trade-offs. Product requirements belong in a current PRD or issue, not in an
ADR.
