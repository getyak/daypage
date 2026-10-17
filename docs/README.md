# DayPage documentation

This index distinguishes current operating documents from historical evidence. If a
document is not linked as current here, verify it against code and tests before using it
to drive a change.

## Current

- [Repository constitution](../AGENTS.md)
- [Architecture index](architecture/README.md)
- [System overview](architecture/overview.md)
- [Backend system](backend-system.md)
- [Engineering index](engineering/README.md)
- [Setup](engineering/setup.md)
- [Testing and evidence](engineering/testing.md)
- [DayPage Cloud MCP staging runbook](mcp-cloud-runbook.md)
- [Agent Data Plane runbook](agent-data-plane-runbook.md)
- [Agent Evaluation runbook](agent-evaluation-runbook.md)
- [Contributing workflow](engineering/contributing.md)
- [Agent Team system](agent-system/README.md)
- [TestFlight fidelity and design-system cleanup](design/testflight-fidelity.md)
- [Native Figma reading implementation](design/figma-reading-implementation.md)
- [Shared backend import](operations/shared-backend-import.md)
- [Shared web account reading](operations/shared-web-account-reading.md)

There is currently no single repository-wide PRD designated as current. For scoped work,
the active GitHub issue, accepted ADRs, code, and tests define the contract until a
current PRD is adopted and linked here.

## Architecture decisions

- [ADR-0012: Action Button screenshot capture and evidence-first understanding](architecture/decisions/ADR-0012-action-button-screenshot-capture.md) — Accepted
- [ADR-0008: Local-first sync and OAuth-protected DayPage Cloud MCP](architecture/decisions/ADR-0008-local-first-sync-and-cloud-mcp.md) — Accepted
- [ADR-0006: Repository Agent Team control plane](architecture/decisions/ADR-0006-repository-agent-team-control-plane.md) — Accepted
- [ADR-0013: Privacy-safe operational diagnostics](architecture/decisions/ADR-0013-privacy-safe-operational-diagnostics.md) — Accepted
- [ADR-0014: DeepSeek Harness development-host adapter](architecture/decisions/ADR-0014-deepseek-harness-host-adapter.md) — Accepted
- [ADR-0015: Stable memo detail and bounded media](architecture/decisions/ADR-0015-stable-memo-detail-and-bounded-media.md) — Accepted
- [ADR-0016: Revisioned local-first attachment synchronization](architecture/decisions/ADR-0016-revisioned-attachment-sync.md) — Accepted
- [ADR-0017: Local-first Apple System Actions](architecture/decisions/ADR-0017-apple-system-actions.md) — Accepted
- [ADR-0018: Backend-first Agent data plane](architecture/decisions/ADR-0018-backend-first-agent-data-plane.md) — Accepted
- [ADR-0019: Agent evaluation and learning plane](architecture/decisions/ADR-0019-agent-evaluation-learning-plane.md) — Accepted
- [ADR-0020: Imported media compatibility](architecture/decisions/ADR-0020-imported-media-compatibility.md) — Accepted
- [ADR-0021: Private tables in a fresh shared backend](architecture/decisions/ADR-0021-private-backend-rls-baseline.md) — Accepted
- [ADR-0022: Account-scoped web memo reading](architecture/decisions/ADR-0022-account-scoped-web-memo-reading.md) — Accepted; local real-account Web reading verified, native and release acceptance pending
- [ADR-0023: Account tag imports](architecture/decisions/ADR-0023-account-tag-imports.md) — Accepted; shared-backend rollout and Web reading verified, native reading delivered via ADR-0025 (local synthetic acceptance only)
- [ADR-0024: Account/origin/session binding](architecture/decisions/ADR-0024-account-origin-session-binding.md) — Accepted; native realm/session isolation implemented, live device gates parent-owned
- [ADR-0025: Native tag projection and sync completion](architecture/decisions/ADR-0025-native-tag-projection-and-sync-completion.md) — Accepted; derived tag cache, consistency boundary and truthful sync completion implemented in DayPageKit + Apple hosts; real-account/device/live acceptance pending parent gates
- `docs/ADR-0001-*.md` through `docs/ADR-0005-*.md` are legacy-location decisions.
  Read their status fields and verify implementation before relying on them.

## Historical material

Top-level `docs/PRD-vNext.md`, dated research/audits, `docs/plans/`, `tasks/`, `archive/`,
screenshots, and [design explorations](design/README.md) preserve rationale and evidence.
They are not automatically current requirements.

When implementation changes a documented boundary, update the owning current document
and add or supersede an ADR; do not silently rewrite historical documents.
