# DayPage AI conversation redesign

Scope: current local-only iOS app, GitHub #957. The user requests implementation autonomously; the choices below are implementation decisions, not a claim of separate design approval.

## Intent and approach

Use getyak/tormie's compact native conversation layout, bounded context and candid personality as references. Keep SwiftUI navigation and local stores. A Web UI embedded in iOS would undermine native selection and accessibility; a hosted chat SDK would introduce an account/backend dependency. Use Microsoft's MIT-licensed SwiftStreamingMarkdown 0.7.0 for native Markdown rendering (iOS 16+) behind one view adapter, retaining the existing provider/Keychain boundary.

## Acceptance

- Settings has a dedicated AI models destination; the same destination opens directly from chat. Other notebook settings are outside it.
- Chat has a small character/model header, history and new-conversation actions, 14pt message gaps, native body text, restrained user bubbles and a single compact multiline composer. Controls remain at least 44pt and support Dynamic Type/dark mode.
- All existing `.daypage/chats/<UUID>.json` records remain readable. History enumerates every scope, preserves unreadable files and reports unreadable counts. Opening history restores its own note scope. New conversations never replace old files. No bulk migration or raw-vault rewrite.
- Drafts, outgoing questions and streamed partial messages save by default. Switching history flushes the current draft. Cancellation/failure/relaunch retain partial output with an interruption state and allow explicit retry. No network requests on history/character browsing.
- Local characters have name, role and Soul. Create/edit/duplicate characters; select one manually or rotate across selected characters, exactly one model reply per user send. Store the character snapshot with each assistant message; later edits do not relabel old replies. No implicit fan-out or background model spending.
- OpenAI-compatible and Anthropic SSE streams deliver visible text progressively, validate completion/error frames and support cancellation. Preserve transport size/time/redirect protections and JSON-only provider fallback. Show collapsible reasoning only if actually supplied by the provider, never fabricated hidden reasoning.
- Markdown headings, inline formatting, lists, tables and code blocks render natively; remote images stay disabled. Scroll follows only when at the bottom and offers a return-to-latest action when reading earlier messages.

## Constraints and risks

iOS 16.1; local Markdown/JSON only; keys only in device Keychain. Add optional Codable fields rather than migrating existing files. Invalid legacy records are not overwritten. Character instructions do not expand note scope or tool permissions. Preserve selected-note boundaries. Real-provider/device/TestFlight acceptance is separate from fixture/Simulator acceptance. Linear MCP unavailable at intake; record rather than silently claiming a Linear association.

## Verification

Core tests: legacy JSON, multi-scope history/corrupt-file visibility, editor leases/revisions, character snapshots and rotation, SSE fragmentation/errors/truncation/bounds. Native UI: model destination, character editing/rotation, history/new/reopen/relaunch, compact Markdown/streaming/cancel, narrow and large type. Repository local-iOS dependency contract and doctor; exact-head PR CI and independent code review before merge. Respect the shared host pause marker; heavy local verification remains deferred while it exists.
