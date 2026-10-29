# DayPage Web

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users and purpose

DayPage lets a person capture daily moments as raw notes, then read compiled
Daily Pages and explore connections between concepts and entities. Capture is
the first task; organization is a separate, explicit action.

## Capabilities and constraints

- `/add` and mobile `/today` share the working Composer, persisted draft,
  browser speech support, save handler and retry behavior.
- Daily Pages and knowledge pages live under `/wiki`; the graph is an optional
  view of the same account's pages.
- Preserve existing account checks, raw content, sources, backlinks, annotations
  and recovery. This UI work does not migrate the legacy capture database or
  establish cross-client data parity.
- Authenticated data must remain account scoped. Test UI states with synthetic
  data; do not include personal notes or credentials in screenshots or fixtures.

## Product principles

1. Make leaving a moment easier than organizing it.
2. Keep writing and reading visible; reveal supporting tools when requested.
3. Keep failures and their recovery truthful and reachable.
4. Preserve source provenance when showing compiled content.

## Design brief and evidence

GET-285 requests almost no chrome in capture, with Day One / Ambi as references
for restraint. Existing tokens, fonts and working interactions remain the
implementation authority. See `docs/design/capture-first-entry.md` at the
repository root for current behavior and account boundaries.

This record uses the explicit issue brief and current repository contract.
Native app redesign, new positioning, a replacement brand and future marketing
build defaults are outside this task and remain undecided.
