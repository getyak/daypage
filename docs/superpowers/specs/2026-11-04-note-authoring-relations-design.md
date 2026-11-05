# Note authoring and relationships

Status: accepted scope by the user's November 4 instruction to implement every proposed tool, with relationship suggestions confirmed before persistence. GET-388; follows GET-369/ADR-0030.

## Outcome and approaches

Add twelve tools to the six existing local iOS tools: notes_create, notes_append, notes_propose_patch, notes_similar, notes_neighbors, notes_find_duplicates, relations_suggest, relations_list, relations_link, relations_unlink, notes_set_tags and notes_set_pin. A person can find older ideas, inspect the evidence, create or improve a note and save confirmed relationships. Existing ordinary chat, drafts, attachments and raw Markdown stay compatible.

Selected direction: extend DayPageCore and the existing native conversation, reuse the configured chat provider and keep data file based. Local lexical/Chinese-bigram retrieval returns candidates and match evidence; the configured model can explain, compare and expand queries. Do not describe this as an embedding-based semantic index. The alternative of adding an embedding service/index now adds model configuration, cost and index maintenance before retrieval quality is measured. A separate graph database would duplicate the local Vault and is unnecessary for confirmed edges.

## Storage and authority

All tools operate within the host-derived conversation selection. Disabling note inclusion/tools disables tool access. Tools receive no arbitrary paths, credentials or unrestricted store. Reads return bounded structured data and exact sources. Every write returns a typed pending proposal, never a claimed committed result. Native Review and Save/Confirm is the only commit path. A model cannot confirm its own proposal. Proposals and receipts survive conversation reopening; cancellation never silently commits.

Create writes a new ordinary Markdown memo independently of capture drafts. Append/patch/tags preserve other notes, unknown YAML, attachments and original metadata; edits require the exact original revision. Tags remain the existing body hashtag convention. Pin uses the existing pinned_at field. Patch is a single unambiguous before/after replacement rather than arbitrary filesystem patch execution. Stable proposal identities and durable action records prevent duplicate writes on repeated taps or restart; undo refuses to overwrite subsequent edits.

Confirmed relationship metadata lives under .daypage, uses a versioned JSON format and full namespace/day/UUID card identities, and never rewrites original memo format. Types: related, supplements, contradicts, evolves, duplicate and derived_from. Direction is explicit; both outgoing and incoming edges are discoverable. Reasons are suggestions with exact excerpts, not established facts. List hides out-of-scope endpoints and indicates stale/deleted source evidence. Links are idempotent and unlink removes only the selected edge. Missing/malformed/unknown-version metadata is recoverable and never treated as an empty store that can overwrite evidence.

## Retrieval and budgets

Similar accepts an anchor card or bounded query, excludes the anchor and returns ranked candidates with matching terms/tags. Neighbors uses a full anchor identity and chronological ordering. Duplicate detection normalizes text, excludes short boilerplate and reports exact versus near candidates; it never merges or removes original notes. Candidate/pair, text, result and source limits are explicit; incomplete coverage must be reported. No-match remains no-match. Existing six-request/twelve-call agent budgets remain unless a verified test requires a documented adjustment.

## Native flow

The conversation's note tools switch now covers searching and proposed changes, with clear explanatory text. Each assistant reply can carry sources and pending action cards. Review shows tool purpose, target date/excerpt and before/after or relationship endpoints, then Save/Confirm or Cancel. Success exposes the actual saved note/relationship, status and Undo; errors preserve proposals and offer retry. Saved receipts are read back after reopening and do not depend on a model's answer. Proposal controls are unavailable while streaming, after note access is disabled, or when scope has changed. No new navigation hierarchy or capture interruption is needed.

## Verification and boundaries

Use synthetic isolated Vaults only. Test every new tool through its executor, all provider definitions/continuations, invalid arguments, scope denial, no match, namespaces, revision conflicts, concurrent duplicate requests, restart recovery, undo and exact final Markdown/JSON. Native fixtures exercise create, append/patch, similarity/source navigation, confirmed link/list/unlink and reopen; existing chat/speech regression journeys remain selected. Existing pause marker forbids local heavy native builds; use hosted workflows. Latest-head CI and independent review are required before merge; merge does not close GET-388 until acceptance readback. No TestFlight/App Store deployment, new external provider, dependency, database, background processing, destructive note operation or private Vault inspection is in scope.

## Ownership and risk

Core owner: DayPageCore tool definitions/executor, typed actions, retrieval, relationship/action persistence and focused core tests. Integration owner: DayPageLocal, ChatMessage/AgentEvent integration, native QA/fixture, current documentation and workflows. Review is read-only and independent. Cross-owner API changes are messaged before editing shared paths. Main risks are stale target writes, retry duplication, metadata path traversal/symlinks, false relation claims, scope leakage and native confirmation not matching the proposed action.
