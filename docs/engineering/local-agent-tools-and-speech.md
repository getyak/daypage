# Local card tools and read aloud

Scope: GET-369/GET-388, ADR-0030/ADR-0031. Active app: DayPageLocal, iOS 16.1+.

## Card tools

In Conversation, expand the notes row and enable Search notes as needed. On explicit Send, the AI may search/read all cards in the conversation's current selection, including supported attachment text. The row shows that complete available count. Include note excerpts off also disables tools. Opening history uses that conversation's stored scope. Roles affect style, never scope.

Eighteen tools are available within the current conversation's selection:

| Tool | Behavior |
|---|---|
| notes_search | Keyword/date/tag search, exact count before preview limits |
| notes_read | Bounded original body and attachment metadata |
| notes_list | List cards with date/tag filters |
| notes_stats | Exact scoped card/day/attachment/body-character counts |
| notes_tags | Tags and distinct-card counts |
| assets_read | Supported attachment text |
| notes_create | Propose a new note independently of the capture draft |
| notes_append | Propose text appended to one note |
| notes_propose_patch | Propose one unambiguous before/after replacement |
| notes_set_tags | Propose replacing body hashtags, preserving other text |
| notes_set_pin | Propose pin/unpin using existing metadata |
| notes_similar | Local lexical candidates from an anchor or query |
| notes_neighbors | Chronological neighbors of an exact card |
| notes_find_duplicates | Exact-normalized or near-lexical candidates, never merging |
| relations_suggest | Candidate relationships with original excerpts |
| relations_list | Confirmed incoming/outgoing connections within scope |
| relations_link | Propose a directed connection and explanation |
| relations_unlink | Propose removing one confirmed connection |

Dates use inclusive YYYY-MM-DD bounds. Search/list/statistics counts cover matching scoped cards, not only previews. Sources open the exact original card and persist after reopening. Missing sources show a recoverable message.

### Review and save changes

The model only prepares a change. Review change opens the target and proposed text or relationship endpoints. Confirm change writes the local files and returns a durable receipt; Cancel proposal never changes a note. Saved cards can be opened. Undo change refuses to overwrite subsequent edits. Reopening reads the file receipt rather than trusting assistant text. Retries in the same user turn reuse stable proposal identity and timestamp. Disabling note inclusion/tools disables confirmation as well as reading.

Relationships follow the user's selected policy: suggest first, save after confirmation. Types are related, supplements, contradicts, evolves, duplicate and derived_from. Both endpoints must be authorized by the host scope. Directions are explicit, incoming edges are discoverable and changed evidence is marked stale. Authorized missing endpoints remain unavailable markers with their old text and explanation masked from new model requests; excluded endpoints are hidden. Explanations remain interpretations. Original note files are preserved. Sending reads a fresh Vault snapshot rather than the native UI cache. Live tool authority is rechecked before tools and subsequent model rounds; already-dispatched requests cannot be recalled.

Version-1 local metadata lives at `.daypage/note-actions.json`: pending proposals, confirmed edges and recoverable receipts, including bounded original/updated blocks for undo. `.daypage/note-actions-origin.json` binds its initialization identity, so a missing journal after prior use cannot silently become a new history. Raw Markdown format is unchanged. Damaged, unsupported-version or linked metadata fails without replacement. Interrupted preparation never automatically publishes an unconfirmed change; reopening reconciles only already-published bytes. Ambiguous interrupted actions are quarantined while unrelated reads and safe changes remain available. Per-edge generations prevent an old undo from reviving a later removed relation. Native commits validate the live conversation lease, scope, switches and cancellation under the same synchronous gate as session changes. No database, embedding provider or background cloud request is introduced.

Similarity uses local words, Chinese bigrams and shared hashtags, not semantic embeddings. The configured chat model can interpret candidates or try alternate queries. Retrieval inspects up to 500 candidate cards and 6,000 body characters per card; duplicate discovery inspects at most 5,000 pairs. Results expose method/coverage/truncation. No-match remains empty, and equal long prefixes are never called exact duplicates. Write text is bounded to 6,000 characters; invalid arguments never reach the write path.

The runtime allows at most six model requests/twelve tool calls, twenty result cards and twenty-four source refs, with bounded text and input sizes. Tool mode completes bounded nonstream rounds; ordinary mode remains streamed. Unsupported responses preserve the question and let the person switch off tools.

Supported attachments: UTF-8 txt/md/markdown/csv/json/log, text PDFs (first twenty pages), image OCR via Vision, existing audio transcripts. Extraction is local and bounded to 25MB/16,000 characters before the tool's narrower output cap. Unsupported/scanned-only PDFs and recordings without transcripts report unavailable; this feature does not silently start cloud transcription. Original media is preserved.

Save as a note creates a new card with the reply's stable message identity, independently of the capture draft. Repeated saves return the same existing card; edited cards are not overwritten.

## Speech channels

Settings → Speech channels. The default is a system voice installed on the device. Add a channel, choose provider, set model/voice/address as appropriate, save and select. Multiple named channels remain available; the checkmark marks the saved playback selection. A saved channel can be edited or deleted; the stable system option remains.

- System: installed device voices, no service/key.
- OpenAI: direct audio/speech, editable model/voice, MP3.
- ElevenLabs: direct text-to-speech/voice_id, editable model and bounded speed, MP3.
- OpenAI-compatible: explicitly configured remote or permitted local server; Use API key off means no Keychain access and no authentication header. A stored key stays inert until explicitly reenabled; deleting the channel also removes its stored key.

Save works offline. Preview synthesizes the fixed sample only, using the current edited channel; it never sends a note. Card and completed-answer Read aloud uses the saved selected channel. Explicit Play can consume that provider's quota. Each request supports up to 4,096 characters; oversized text shows an error rather than truncating.

Keys are independently stored in device Keychain by channel/provider/origin; preferences never contain keys. Changing provider/address cannot carry the previous key into a new service. Failures preserve typed settings. Preview does not change the saved selection. There is no automatic failover. Stop/cancel, pause/resume, leaving the app and beginning recording release or interrupt the task's own playback. No persistent audio files or new background audio mode are used.

## Verification

Core:
```sh
swift test --package-path DayPageCore --jobs 1
python3 scripts/tests/test_local_ios_contract.py
python3 scripts/tests/test_chat_session_recovery.py --build-path DayPageCore/.build
python3 scripts/tests/test_capture_draft_transactions.py
```

The core and native UI use synthetic fixtures, never personal Vaults. The task-owned native HTTP fixture binds 127.0.0.1:18763 and supports ordinary streaming, a complete tools roundtrip, decodable synthetic MP3, and deliberate speech failure. New CardToolsSpeechUITests require the fixture and do not skip absent-fixture cases.

While the shared Mac has a resource pause, use the existing hosted workflow:
```sh
gh workflow run ios-local.yml --repo getyak/daypage --ref main -f native_ui=true -f native_ui_suite=card_tools_speech
```

This selects sixteen signed journeys (note authoring, relations, card tools, speech and existing ChatExperienceUITests), plus two unsigned cases: real Keychain denial and anonymous speech that must remain usable without Keychain. native-acceptance.json records the suite and exact source SHA. Omit the suite or use full for every native journey. Do not interpret the selected suite as all-app acceptance.

Live OpenAI/ElevenLabs/custom account access, voice quality, quota and physical-device audio remain separate checks requiring an actually configured service. Fixture success is protocol and app-path evidence only.
