# Effortless AI setup and quiet note cards

User request: continue improving the local iOS notebook after 0.5.2. Choose common AI providers rather than typing addresses/model IDs; default to automatically updated frontier general-purpose models. Put each card's full date/time at its top left and a lighter actions menu at its top right. Remove external date/recent headings and navigation arrows.

## Approach

Use native SwiftUI provider/model pickers backed by a small typed catalog and official direct APIs. Keep custom OpenAI-compatible/local servers. This avoids an additional gateway account or app backend; a gateway remains an explicit provider choice (OpenRouter). Keep baseURL/model preferences backward compatible, infer protocol only from exact trusted provider endpoints, and store the automatic-selection marker in the existing model string. No vault or preference schema migration, dependency, account, or billing changes.

Provide OpenAI, Anthropic Claude, Gemini, DeepSeek, Qwen, Kimi, GLM and OpenRouter where official protocols can be verified. Add regional endpoint choices where credentials differ by region. Show an official key-management link. Standard setup shows provider, key, model (automatic by default) and one save action; addresses and local HTTP live under custom/advanced settings. Allow fetching available models and explicitly pinning one.

Automatic selection stays in the chosen provider and general-purpose text family, prefers currently available stable models, excludes specialized image/audio/embedding/coding-only and retired models, and never silently switches provider. Use official rolling aliases where documented; otherwise query the provider's authenticated model list with strict response/size/transport bounds. Discovery failure must preserve the current draft and offer retry or explicit model entry, not claim connection success. Show the resolved model in connection testing. No note excerpts are sent while selecting/fetching/testing. Keep explicit Send and context preview. Test connection separately from offline-capable Save.

Card header is full localized year/month/day plus time, pin/import status, and a visually small ellipsis with a 44pt hit target. The reading surface opens detail without SwiftUI List's automatic chevron. Menu and attachments remain independently actionable; left/right native swipes and accessible actions stay available. Flatten external list date headings without changing sort order or filters. Preserve empty/loading/error states and Archive navigation.

## Verification and ownership

Core owner: DayPageCore AI provider catalog, discovery, protocol request/response adaptation and focused tests. Parent owns settings/chat integration, localization and docs. Card owner owns NotebookTimeline.swift and NotebookArchive.swift only; parent owns UI tests. All source work shares a scoped worktree; no overlapping file ownership. Run host core tests serially, then the active local Xcode project through dev-ios-session on the existing Primary iPhone, using the isolated QA bundle/vault. Verify preset selection, key isolation, automatic/fixed models, failures, existing custom setup, chat drafts, card header/menu/swipes/detail, light/dark/large text. Independent review and exact-head CI precede merge. TestFlight publication remains separate from feature acceptance.

## Sources

- https://developers.openai.com/api/docs/models
- https://developers.openai.com/api/reference/chat-completions/overview
- https://platform.claude.com/docs/en/api/models/list
- https://platform.claude.com/docs/en/api/messages/create
- https://ai.google.dev/gemini-api/docs/openai
- https://api-docs.deepseek.com/quick_start
- https://help.aliyun.com/zh/model-studio/compatibility-of-openai-with-dashscope
- https://openrouter.ai/docs/api-reference/models/get-models

Builder decisions: native direct integration and the exact discovery policy are agent choices within the user's requested simplification. Do not treat an unverified vendor alias or endpoint as current.
