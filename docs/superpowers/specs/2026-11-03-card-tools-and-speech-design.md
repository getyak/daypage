# GET-369: useful card tools and speech channels

User authorized direct design and implementation on 2026-11-03 after the tools research. Linear GET-369; GitHub #961. Base a56d225a. Preserve local Markdown, iOS 16.1, explicit Send, note scope, drafts and personal provider boundaries.

## Chosen design
Use native Foundation adapters with no SDK, database or Vault format changes. Add an explicit note-tools switch to chat (off for existing conversations until chosen), scoped read-only search/read/list/statistics/tags/attachment-reading operations and visible source links. Completed replies can be saved explicitly as a new card, without consuming the capture draft. Add device/system speech plus multiple named saved remote TTS channels, using OpenAI-compatible and ElevenLabs request adapters; custom compatible servers remain possible. Save and preview are separate; preview uses a fixed synthetic sentence. Keys are independently scoped by channel and service origin in the existing device-only Keychain.

Alternatives considered: embedding the Go runtime introduces an unnecessary iOS process/runtime boundary; introducing a cloud gateway adds an account and trust dependency. Native tools and direct provider adapters fit the current product.

## Ownership and integration
- Agent worker: new DayPageCore NoteTools/AgentLoop models, executors, bounded provider rounds and tests; owns minimal AIClient transport access change in NoteChat.swift if necessary. Do not modify existing AIStreaming.swift enum; define AgentEvent wrapping AIStreamEvent instead.
- Speech worker: new DayPageCore Speech* models/config/request/transport and tests, plus new DayPageLocal SpeechSettingsView.swift and SpeechPlayback.swift. Do not edit existing app/settings/model/project/localization.
- Lead: ChatSession/NoteChatView/NotebookModel/SettingsView integration, AttachmentTextReader, project.yml/pbxproj, localization, UI tests, scripts, docs, CI and remote delivery.
Workers do not run simultaneous test/build jobs. Agent runs and drafts must retain existing persistence leases. TTS settings receive UserDefaults explicitly, using the isolated QA suite in UI tests.

## Public interface contract
- NoteToolContext stores the host-filtered [NotebookEntry] and optional async attachmentReader(cardRef, attachmentIndex) closure returning bounded extracted text. Models cannot choose Vault paths. Helpers return complete card ref (namespace/day/UUID), day, snippets and bounded source list. Read-only tools only; saves are user UI actions.
- AIClient.runWithTools(configuration:apiKey:messages:context:toolContext:character:onEvent:) async throws; AgentEvent.stream(AIStreamEvent), .toolStarted(String), .sources([NoteToolSource]). No raw protocol arguments in user-visible status.
- Tool mode may use bounded nonstream tool rounds while ordinary chat keeps existing streaming; no tools/extra access unless explicitly enabled. Unsupported model/server surfaces recoverable error and ordinary-chat switch, never silently changes provider.
- SpeechSettingsView(defaults: UserDefaults), SpeechPlayback(defaults: UserDefaults) ObservableObject with speak(_ text: String, id: String), stop(), isActive(id:), error/status. Settings persisted channel selection is read when playback starts. QA defaults are isolated. Cloud speech only on explicit user Play/Preview; no auto speak.
- New tools/tts tests verify success and denial/recovery, exact outputs and stored data, not only implementation shape.

## Acceptance and non-goals
Core tests include scoped search/no hits, repeated UUID namespaces, malformed tool args, bounded loops, both provider dialects, cancellation, all TTS request dialects, endpoint/key isolation, invalid audio and saved multi-channel config. Native UI verifies tool switch/source/open/save/reopen, settings/channel/preview/error/retry/system speech controls. Native build and UI run in hosted isolated CI while local resource pause exists. Real-provider live audio and physical-device quality are separate evidence, not implied by fixtures. No automatic reminders/web/search/secret reuse, no package release in this change.

## Risks and rollback
Gate every tool read on host scope and include-notes state. Save result uses independent stable ID and operation feedback. Bound media text and speech input; reject redirects and oversized/invalid responses. Keep cloud errors generic and keys out of config/logs. Feature switches preserve ordinary chat and system speech as usable defaults. Revert code to roll back without changing existing raw files.

