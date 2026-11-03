# Local card tools and read aloud

Scope: GET-369, ADR-0030. Active app: DayPageLocal, iOS 16.1+.

## Card tools

In Conversation, expand the notes row and enable Search notes as needed. On explicit Send, the AI may search/read all cards in the conversation's current selection, including supported attachment text. The row shows that complete available count. Include note excerpts off also disables tools. Opening history uses that conversation's stored scope. Roles affect style, never scope.

Six tools: notes_search, notes_read, notes_list, notes_stats, notes_tags, assets_read. Dates use inclusive YYYY-MM-DD bounds. Counts cover matching scoped cards, not only returned previews. Sources below the answer open the exact original card and persist after reopening. A missing source shows a recoverable message.

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
gh workflow run ios-local.yml --ref codex/get-369-card-tools-speech -f native_ui=true -f native_ui_suite=card_tools_speech
```

This selects eleven signed journeys (all new card-tools/speech and existing ChatExperienceUITests), plus two unsigned cases: real Keychain denial and anonymous speech that must remain usable without Keychain. native-acceptance.json records the suite and exact source SHA. Omit the suite or use full for every native journey. Do not interpret the selected suite as all-app acceptance.

Live OpenAI/ElevenLabs/custom account access, voice quality, quota and physical-device audio remain separate checks requiring an actually configured service. Fixture success is protocol and app-path evidence only.
