# AI presets and quiet cards implementation plan

> For agentic workers: use superpowers:subagent-driven-development or executing-plans with scoped file ownership and independent final review.

**Goal:** Configure common personal AI services with provider/key choices and make note cards self-contained and quiet.
**Architecture:** Typed official provider presets and bounded model discovery in DayPageCore; native settings and existing origin-scoped Keychain; existing List cards with a custom reading button and top metadata.
**Tech stack:** Swift, Foundation URLSession, SwiftUI, XCTest; iOS 16.1 minimum; no new dependencies.
**Spec:** ../specs/2026-11-01-ai-presets-and-quiet-cards-design.md

## Global constraints

Preserve raw Vault and AIConfiguration coding shape, custom endpoints, local HTTP consent, request/context bounds, redirect rejection, device-only Keychain, explicit Send and drafts. No production credentials or real notes in tests. No automatic release.

## Review focus

- Provider changes must not carry the previous provider's key or resolved-model state.
- Model discovery failures/empty lists/pagination cannot silently send a sentinel or stale foreign model.
- New general-purpose models must rank correctly without selecting specialized/retired variants.
- Anthropic and current OpenAI request shapes must match official APIs.
- Removing chevrons must preserve full reading, swipes, menu hit targets, selection and accessibility.

### 1. Provider catalog, model discovery and protocols

- [ ] Add focused failing tests for preset endpoints, automatic resolution, stable family selection, no cross-origin pagination/redirects, missing keys, protocol payloads and response bounds.
- [ ] Add AIProvider/AIModelCatalog and adapt AIConfiguration/AIClient while preserving existing public complete API and coding fields.
- [ ] Public integration contract: AIProvider (CaseIterable/Identifiable) with id/name/baseURL/keyURL, configuration and matching(configuration:); AIModelOption (Identifiable/Equatable/Sendable) with id/name; AIModelCatalog automaticModel constant, models(configuration:apiKey:) async throws, resolve(configuration:apiKey:) async throws -> AIConfiguration. If official discovery differs, coordinate before changing this contract.
- [ ] Run focused then complete DayPageCore tests; commit only owned core paths.

### 2. Provider-first Settings and chat

- [ ] Replace required URL/model typing with provider/key/model choices; preserve custom fields and local HTTP disclosure.
- [ ] Offer available-model refresh, fixed selection and automatic default; separate Save and no-notes Test; show resolved model and actionable errors.
- [ ] Preserve origin-bound secret loading, drafts, cancellation and old saved connections. Localize new en/zh copy; hide internal auto marker from chat.
- [ ] Add native tests for provider switching, custom compatibility, available-model/failure state and persisted selection. Commit settings integration.

### 3. Quiet self-contained cards

- [ ] Move full date/time and status to top left; move ellipsis to top right with 44pt hit target.
- [ ] Remove built-in List disclosure arrow using programmatic navigation without wrapping menu/attachment controls.
- [ ] Flatten recent/date headers; keep ordering, selection and native swipes.
- [ ] Validate detail, pin/share/trash/undo, long content, dark mode and large text; commit card changes.

### 4. Integration, review and delivery

- [ ] Run storage/resource audit, core tests, local iOS contracts and doctor; build/test only active project through dev-ios-session.
- [ ] Save synthetic Simulator screenshots and receipts outside Git. No real-provider claim without credentials.
- [ ] Update current docs, record official-source and actual validation limits; independently review and fix confirmed important findings.
- [ ] Create one linked PR for GitHub #955 and Linear GET-351; wait for all exact-head applicable checks, merge, and read back. Close Linear after acceptance.
