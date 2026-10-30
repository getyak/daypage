# DayPage Repository Constitution

This is the durable, repository-wide contract for humans and coding agents. Keep it
short and factual. Module-level `AGENTS.md` files may add local detail but must not
weaken the safety, ownership, data, or release rules here.

## Product and repository

DayPage captures raw daily signals and compiles them into Daily Pages, entity pages,
and a personal knowledge graph. This is a multi-surface repository:

- `DayPage/`: legacy SwiftUI iOS source retained for the archived edition and other Apple targets.
- `DayPageLocal/`, `DayPageCore/`: current local-only iOS app and file/AI core (GET-326, ADR-0027). Build `DayPageLocal/DayPageLocal.xcodeproj`, scheme `DayPage`; `DayPage/` and the original project now serve the legacy edition and other Apple targets.
- `DayPageMac/`, `DayPageWatch/`, `DayPageWidget/`: Apple platform companions.
- `DayPageKit/`: Swift package and source of truth for shared models, storage, and services.
- `DayPageTests/`: Xcode target tests; `DayPageKit/Tests/`: Swift package tests.
- `android/`: native Jetpack Compose client with Room indexing and a canonical raw Vault.
- `web/`: Next.js web product; follow `web/AGENTS.md` and local framework docs.
- `packages/mcp-server/`: TypeScript DayPage MCP server.
- `agentry/`: Go product runtime. It is not the repository development-agent control plane.
- `.agents/`: canonical development Agent Team roles, workflows, schemas, and skills.

Read [docs/README.md](docs/README.md) for current documentation routing. Treat old
PRDs, plans, screenshots, and audit reports as historical evidence unless an index
marks them current.

## Source-of-truth order

When instructions conflict, use this order:

1. Current user and platform instructions.
2. This constitution, then a closer module `AGENTS.md` for local rules.
3. Accepted architecture decisions and the current PRD linked from `docs/README.md`.
4. Executable code, tests, schemas, and checked-in configuration.
5. Historical documents and archived artifacts.

Do not copy volatile architecture facts into host adapters. Update the owning current
document and link to it.

## Core invariants

- User vault data is local-first and file-based. Do not delete, rewrite, or migrate it
  without an explicit migration plan, compatibility tests, and user authorization.
- Raw memo files remain `vault/raw/YYYY-MM-DD.md`, with YAML front matter and Markdown
  records separated by `\n\n<!-- daypage-memo-separator -->\n\n`; legacy
  `\n\n---\n\n` files remain read-compatible. Assets remain under `vault/raw/assets/`.
- Shared model/storage/service behavior belongs in `DayPageKit` unless an Apple target
  genuinely requires an adapter.
- The local-only iOS boundary in ADR-0027 uses `DayPageCore`, without cloud/database dependencies. Keep its raw format compatible with legacy Vaults; do not pull legacy sync or credentials into the new app.
- Secrets belong in ignored local files, keychain, or environment variables. Never
  commit API keys, auth state, personal vault content, transcripts, or runtime evidence.
- Preserve iOS 16 compatibility in shared/iOS code unless an approved decision changes it.
- No external dependency, schema migration, or persistence-format change without discussion.
- No force unwraps in production paths. Prefer typed errors, `guard`, and explicit recovery.

## Code Review Rules

- Flag storage, sync, import, or migration changes that can rewrite or lose raw
  vault content, break the canonical memo/front-matter/asset format, or drop
  legacy read compatibility without isolated round-trip and migration evidence.
- Flag shared model or service changes that let Apple, Android, web, MCP, or Go
  surfaces diverge from a versioned contract without updating the owning schema
  and cross-surface fixtures.
- Flag any path that exposes personal notes, transcripts, attachments, precise
  context, auth state, or secrets to logs, telemetry, fixtures, Slack, or a
  model beyond the user's explicit purpose and authorization.

## Agent Team protocol

Use `.agents/manifest.yaml` to discover roles and workflows. The lead owns the task
graph and integration; specialists own bounded paths. Parallelize only independent
work that benefits from separate context.

Before delegating or editing:

1. Establish acceptance criteria, non-goals, risks, and verification gates.
2. Assign non-overlapping `owned_paths` and explicit `forbidden_paths`.
3. Inspect the dirty worktree and preserve all changes not owned by the task.
4. Record material assumptions and decisions in the handoff contract.

Workers must not edit outside their owned paths, revert another worker, or silently
resolve cross-owner conflicts. Use `.agents/templates/handoff.md` and
`.agents/schemas/handoff.schema.json` for non-trivial handoffs. Return evidence and
residual risk, not just “done.”

## Implementation workflow

- Start from evidence: trace the current path, tests, relevant current docs, and local
  design sources before proposing architecture.
- Feature, design, architecture, and broad refactor work requires a GitHub issue before
  implementation. Use `gh` for GitHub operations.
- Design work requires deep discussion and agreement, then issue -> scoped branch ->
  implementation -> Simulator/browser verification -> PR linked to the issue.
- Architecture changes require an ADR under `docs/architecture/decisions/`.
- Keep changes minimal and behavior-preserving unless changed behavior is accepted.
- Use `rg`/`rg --files` for search and `apply_patch` for manual edits.
- Never use `git add .` or `git add -A`. Stage only reviewed owned paths.
- Do not commit, push, open/merge a PR, tag, release, deploy, or write to remote services
  unless the current task explicitly authorizes that exact side effect.
- Release/TestFlight is a separate workflow with explicit authorization; it is never an
  automatic tail step of feature, fix, refactor, or verification work.
- Active iOS releases use `DayPageLocal/DayPageLocal.xcodeproj` and sign only
  `com.daypage.app`, without cloud `.env` configuration or legacy extensions.
  Both general and local-iOS CI must pass at the exact main candidate SHA.
- Never run destructive cleanup against a workspace, vault, simulator container, branch,
  worktree, database, or cloud environment without resolving the exact target and approval.

## Coding conventions

- SwiftUI views are value types. Extract coherent subviews when `body` becomes hard to audit.
- Shared services use clear actor isolation; UI-facing services/view models are normally
  `@MainActor final class` with observable state where appropriate.
- Keep ownership and notification names centralized; search before introducing another.
- Use `MARK: -` sections where they improve navigation.
- Follow existing module test style: Swift Testing/XCTest, Vitest/Playwright, Node test, or Go.
- For Next.js work, read the version-matched docs under `web/node_modules/next/dist/docs/`
  before relying on remembered APIs.

## Verification

Run the smallest complete gate set for touched paths, then the integration gate when
crossing a boundary. The engineering facade is documented in
`docs/engineering/testing.md`.

- Repository contracts: `make doctor`
- Full local checks: `make check`
- Swift package: `swift test --package-path DayPageKit`
- Local iOS core: `swift test --package-path DayPageCore`; dependency contracts: `python3 scripts/tests/test_local_ios_contract.py`; use the new local project for iOS builds/UI tests. The original project and tests cover the legacy clients.
- iOS code: build the `DayPage` scheme and run affected `DayPageTests` on Simulator.
- iOS UI: launch in Simulator and verify the affected flow; preview-only is insufficient.
- Storage: inspect actual generated Markdown/YAML in an isolated test vault.
- Web: lint, type-check, focused unit tests, and affected Playwright flows.
- MCP server: type-check and tests in `packages/mcp-server`.
- Agentry: `go test ./...`, `go vet ./...`, and `go build ./...` from `agentry/`.
- Design tokens: run the token drift check when token sources or generated outputs change.

Do not claim a gate passed unless you ran it and captured the command/result. If a gate
cannot run, report why, what was run instead, and the residual risk.

## Completion and review

A change is complete only when implementation, required tests, independent review,
current docs/ADR updates, and a structured handoff agree. Reviews prioritize correctness,
data safety, security/privacy, regressions, concurrency, and missing tests over style.

Keep generated build output, `.agents/**/runs/`, screenshots containing private data,
absolute personal paths, and credentials out of version control.
