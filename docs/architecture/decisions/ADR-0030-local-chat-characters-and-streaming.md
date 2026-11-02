# ADR-0030: Local conversations, characters and streaming Markdown

Status: accepted for implementation of GitHub #957 (user requested framework selection and autonomous delivery).

The current iOS app remains local-only. Conversation JSON and scope markers keep their paths and required keys; optional character snapshots, reasoning, delivery state, note inclusion and update time extend the existing objects. Missing fields decode as nil. History enumerates existing files without rewriting them; malformed records remain on disk and their count is visible. No raw-note migration occurs. Character preferences live in a separate atomic `.daypage/characters.json` file; API secrets remain in device Keychain.

Each explicit send produces one reply. Rotation advances across the conversation's selected character snapshots; no automatic fan-out, persona generation or background spending is introduced. Editing a library character updates future selected instructions while historical assistant messages retain their original snapshot. The model has no tools and sees only bounded, inspectable note excerpts and dialogue.

Foundation URLSession AsyncBytes consumes bounded SSE with ephemeral sessions, timeout/cancellation and redirect rejection, supporting OpenAI-compatible and native Anthropic event shapes. Complete JSON responses remain a fallback for local servers. Failed/truncated streams retain interrupted text rather than reporting a successful answer. Provider-supplied reasoning is optional, collapsible and persisted; no internal reasoning is inferred or fabricated.

The app target adds Microsoft's MIT-licensed SwiftStreamingMarkdown at exact version 0.7.0, whose iOS floor is 16. Framework evaluation considered Tormie's Foundation presentation-intent renderer (small but limited streaming/code features), MarkdownUI (maintenance mode), and hosted chat SDKs (unnecessary backend dependency). Keep the new renderer behind the message row. Images are disabled by default; link navigation permits only http, https and mailto. No analytics listener is installed. The pure file/network core retains no external dependencies.

References: [renderer](https://github.com/microsoft/SwiftStreamingMarkdown/tree/v0.7.0), [Anthropic SSE](https://platform.claude.com/docs/en/build-with-claude/streaming), [OpenRouter streaming](https://openrouter.ai/docs/api/reference/streaming), [Tormie](https://github.com/getyak/tormie).
