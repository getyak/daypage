# Note authoring and relationships implementation plan

> For agentic workers: use scoped implementation and independent review; keep the progress ledger under the task's ignored workspace.

**Goal:** Deliver all twelve new note tools and native review/commit/recovery in the current local iOS app.

**Architecture:** Extend the closed executor with bounded retrieval and typed write proposals. Commit only through a native-reviewed action service, persist receipts and confirmed relationships beside existing chat metadata, and preserve raw Markdown compatibility.

**Tech Stack:** Swift, Foundation, CryptoKit, SwiftUI, existing provider adapters, XCTest, existing hosted local-iOS workflow. No new dependency.

**Spec:** ../specs/2026-11-04-note-authoring-relations-design.md

## Global constraints

- iOS 16.1+, local DayPageCore; preserve raw Markdown/YAML and namespace/day/UUID identity.
- User-selected relationship policy: suggest first, confirm before saving.
- No raw user Vault access, new provider/dependency/database, local heavy build under pause or release upload.
- Exact host scope on every read/proposal/commit; durable idempotency and conflict-checked undo.
- Preserve existing unrelated output/ and all other worktrees/services.

## Review focus

- A proposal created before a manual edit must fail safely without overwriting any bytes.
- Repeated Save, concurrent calls and restart after file publication must not duplicate writes.
- A relationship must not disclose a hidden endpoint, stale quote or unrelated namespace.
- Invalid arguments and malformed/symlink metadata must never write outside the intended Vault.
- Cancelling, switching conversations and reopening must preserve truthful proposal/receipt state.

### Task 1: Core tools and durable actions

Files: new focused DayPageCore retrieval/action/relation modules and tests; extend NoteTools.swift, NotebookEntry revision and shared message/event models only as agreed with integration owner.

- [ ] Write behavior tests for all twelve tools, scope/argument denial, exact files, revision conflicts, duplicate apply, restart and undo.
- [ ] Capture a failing core run in hosted CI before feature implementation (local host is paused).
- [ ] Implement retrieval, relationship suggestions/list and typed pending proposals; schemas must match execution.
- [ ] Implement reviewed commit and recovery using stable action identity, existing notebook operations and contained atomic metadata files.
- [ ] Run complete DayPageCore tests in hosted CI and inspect final file fixtures.

Interfaces are documented in the core brief and settled before UI integration. Result proposals have Codable stable identities; apply/undo return persisted receipts; scope is supplied by the native host.

### Task 2: Native integration and fixture journeys

Files: DayPageLocal/ChatSession.swift, NoteChatView.swift, NotebookModel.swift, localization, project file if needed; AgentLoop/NoteChat shared event/message fields; native UI tests and fixture/server/runner selection.

- [ ] Persist proposal events on assistant messages and display clear review cards.
- [ ] Wire confirmed apply, cancel, retry, open saved note and conflict-checked undo; disable commits without current scope.
- [ ] Add synthetic protocol and native journeys that inspect save/link/unlink/reopen behavior, including cancellation and unavailable access.
- [ ] Run local lightweight contracts and hosted build/native suite; preserve source-bound evidence.

### Task 3: Independent review and delivery

- [ ] Update current engineering docs, ADR, indices and privacy boundary if required by actual behavior.
- [ ] Review complete diff independently; fix confirmed P0/P1 with regressions and re-review.
- [ ] Require latest-head applicable CI, exact merge tree and native evidence; create/link the PR to GET-388 and GitHub issue.
- [ ] Merge through repository gates, read back main results and issue state, archive only task-owned worktree after preserving unique evidence.
