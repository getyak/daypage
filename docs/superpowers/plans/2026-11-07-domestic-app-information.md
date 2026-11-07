# Domestic App Information Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development or superpowers:executing-plans task by task. Preserve the acceptance evidence for each task.

**Goal:** Add a real public information service for DayPage and an offline-first native reader.

**Architecture:** Fixed static JSON served by Nginx on the Shanghai ECS; DayPageLocal holds bundled bilingual content and a bounded explicit-action HTTP client. No Vault, account, AI or capture data reaches this service.

**Tech Stack:** Foundation URLSession, SwiftUI, Nginx, existing repository CI; no added external dependencies.

**Spec:** `docs/architecture/decisions/ADR-0033-public-app-information.md`

## Global Constraints

- iOS 16.1 minimum; keep DayPageCore and raw Vault untouched.
- Endpoint exactly `https://daypage-api.cubxxw.com/daypage/v1/app-info.json`.
- Bodyless GET only after explicit action; no cookies, credentials or private context.
- Eight-second timeout, 128 KiB streaming cap, HTTP 200/JSON, no redirects.
- Schema 1, app ID com.daypage.app, bounded bilingual plain text and real revision date.
- Keep all existing unrelated code and worktrees; no native heavy work below 10 GiB.
- Prepare private service first. Filing approval, public exposure and App binary release are separate gates.

## Review Focus

- Oversized chunked response must stop reading at the cap, retaining offline policy.
- Redirects, including same-host redirects, must never carry requests elsewhere.
- Dismissal or repeated taps must not publish stale results or continue requests.
- Malformed/missing bilingual fields or wrong App identity must fail closed.
- App launch and ordinary recording/settings must never contact the new endpoint.

### Task 1: Offline reader and bounded client

Files: DayPageLocal AppInformationService/View, SettingsView, bundled app-info.json, localization, project.yml/pbxproj, focused Swift transport fixture and runner, ios-local workflow.

Interfaces: public `AppInformation` validated bilingual text; `AppInformationService.fetch()` returns that value; view starts with bundled content and invokes fetch only from the latest-information action.

- [ ] Add meaningful failing fixture cases for valid content, schema/app identity, offline/HTTP/TLS failure, redirect, streaming cap, cancellation and no authentication/cookie/body. Run and record the expected red result before implementation.
- [ ] Implement the smallest app-layer client and native page, retaining the existing accessible privacy entry. Use system text layout, Dynamic Type and selection; no remote links or HTML.
- [ ] Run the fixture and existing local dependency contract; wire fixture into hosted CI. Verify new files are in the real Xcode project.
- [ ] Update accurate privacy/support and release documentation, including existing user-confirmed note tools and personal iCloud/Watch facts.
- [ ] Independently review the branch; fix confirmed P0/P1 and material failures. Run appropriate hosted CI/native UI at the final SHA before merge/release.

### Task 2: Private server preparation and filing

Files: owned `deploy/app-information/` static content, Nginx configuration, install/verify/rollback instructions and content validation.

Consumes Task 1's same bundled JSON bytes; produces the exact GET endpoint and a content hash receipt.

- [ ] Validate GET-only JSON response and 404 for other paths with private server configuration; assert no App access-log records and no write backend.
- [ ] Install only reviewed exact files on the purchased ECS, preserving other nodes/services. Verify loopback/Tailnet responses, restart continuity and same content hash.
- [ ] Enter truthful planned service domain and purpose in the filing draft, then complete provider-required materials/identity checks.
- [ ] After filing allows public operation, prepare DNS/TLS/public port change for required action-time approval and verify public HTTPS. Keep public availability marked pending until then.
- [ ] Release the verified App update through the separate authorized Apple workflow; read back processing, version and mainland availability after the real filing number is entered.

Ruling: The user explicitly authorized autonomous minimal service implementation; no additional execution-method question is needed. Source baseline is b9dc0f4daa71e606bc602e828ca67bdfe77cb8ce. Native managed worktree creation did not return a result; a clean Git worktree was created instead. No local builds are authorized while current disk is below the existing 10 GiB operating boundary.
