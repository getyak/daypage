# ADR-0029: Direct personal AI presets and explicit automatic models

Status: Accepted within the user's November 1, 2026 request; [GET-351](https://linear.app/getyak/issue/GET-351/make-ai-setup-effortless-and-simplify-note-cards), GitHub #955.

## Context

The local notebook required people to discover and type an API address and model name. The requested improvement is provider-first setup with current models while preserving a private, optional, personally configured AI connection.

## Decision

Keep direct Foundation HTTP adapters in DayPageCore. Use a typed catalog of verified official endpoints and regional key-management links; Custom remains an OpenAI-compatible adapter. Recognize provider-specific protocols only for exact canonical endpoints. Claude uses its native Messages API. Do not add a DayPage backend, SDK dependency, shared gateway, account or secret distribution service.

Retain the existing AIConfiguration coding fields. An explicit model string represents fixed selection; a reserved marker represents automatic selection. The marker must be resolved before constructing a note-bearing request. Discover from the chosen provider's own model metadata or documented rolling alias, restrict automatic choices to supported general-purpose text families, and report discovery failures. Never guess a nonexistent alias, send the marker, switch providers, or send notes as part of model discovery. Where neither discovery nor a rolling alias is documented (currently GLM), use a clearly identified fixed default and manual updates.

Origin-scoped device-only Keychain storage, HTTPS and explicit private-network HTTP consent, redirect rejection, response/request bounds, explicit Send, source previews and durable conversation drafts remain required. Preset selection and offline Save do not start network requests. Model refresh and a no-notes connection test are explicit actions. There is no Vault migration or background model polling.

## Consequences

Most people configure only a provider and its key. People can pin a model, choose an available model or enter an exact custom model ID. Automatic selection and vendor pricing may change over time, which setup explains. Official model-list access and native request shape are independently testable; real service access, billing and signed-device credentials remain separate acceptance gates.

## Relationship

This extends ADR-0027's optional personal AI adapter and preserves ADR-0028's local product and draft boundaries. The [setup guide](../../engineering/local-ai-setup.md) records the supported experience and official references.
