# ADR-0030: Scoped local card tools and configurable speech

Status: Accepted within the user's November 3, 2026 direct implementation request. [GET-369](https://linear.app/getyak/issue/GET-369/add-useful-card-tools-and-configurable-speech-channels), [GitHub #961](https://github.com/getyak/daypage/issues/961).

## Decision

Extend DayPageCore with six bounded read-only note tools and a native provider loop. Existing conversations retain ordinary streaming until the person enables Search notes as needed. The host derives the full authorized set from the current conversation scope and Include notes state, never from model arguments or the twelve excerpt candidates. Scope uses namespace/day/UUID. Search, read, date filtering, counts, tags and supported attachment extraction return bounded structured results and source refs; writes remain explicit UI operations.

Direct OpenAI GPT-6 tools use stateless Responses with provider continuation items, Claude uses Messages blocks, and compatible services use Chat Completions. Calls are assembled and validated before execution. Limit the number of requests/calls, parameter and response size, and return recoverable errors without changing service or model. Provider reasoning continuation stays in the current run rather than becoming durable instruction authority.

Replies persist their source refs in optional conversation JSON fields. Saving a completed reply uses an independent stable memo ID and does not touch the capture draft or its assets. Existing raw Markdown remains unchanged and import namespaces retain their identity. Attachment parsing supports bounded UTF-8 files, PDF text, image OCR and already stored audio transcripts; new speech recognition is outside this change.

Add multiple named speech channels with a stable system option and direct OpenAI, ElevenLabs and custom OpenAI-compatible adapters. Channel metadata lives in local preferences; keys are device-only, separated by channel ID, dialect and normalized service origin. No chat-key reuse, background synthesis, automatic channel failover, SDK, database, server or raw-file migration. Save is offline; Preview sends a fixed synthetic sentence; Play sends only the chosen text. The settings editor reloads credentials after scope changes and synchronously checks the account before Save/Preview.

Use one app-owned playback controller and a weak global audio lease for previews, with generation/identity checks, stop/pause/resume, foreground lifecycle and recording exclusion. Remote audio is bounded, checked for MP3 framing, then decoded by AVAudioPlayer before playback is accepted.

## Consequences

Tools mode uses bounded nonstream rounds; ordinary chat retains token streaming. Speech has a visible 4,096-character request limit, with provider-specific voice/model settings. Pure system speech needs neither keys nor network. Custom HTTP remains explicitly restricted to supported local/private hosts. Simulator/HTTP fixture success does not establish paid provider access or physical-device audio quality.

Tests cover the protocol, scope, identities, persisted channels, credential account boundaries, headers, invalid audio, drafts, duplicate saves and failures. Hosted native UI may select the card-tools/speech plus existing chat suite while retaining the negative-Keychain stage; its receipt names the selected suite. The full native suite remains available.

## Sources

- https://developers.openai.com/api/docs/guides/function-calling
- https://developers.openai.com/api/docs/guides/reasoning
- https://developers.openai.com/api/docs/guides/text-to-speech
- https://platform.claude.com/docs/en/agents-and-tools/tool-use/handle-tool-calls
- https://elevenlabs.io/docs/api-reference/text-to-speech/convert
- https://developer.apple.com/documentation/vision/vnrecognizetextrequest
