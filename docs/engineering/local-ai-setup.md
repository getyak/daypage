# Personal AI setup in the local iOS app

Scope: [GET-351](https://linear.app/getyak/issue/GET-351/make-ai-setup-effortless-and-simplify-note-cards), [GitHub #955](https://github.com/getyak/daypage/issues/955). AI remains optional and uses the person's own service account. Writing and reading notes work offline.

## Setup

Choose a provider in Settings, choose its region if shown, and enter that provider's API key. The official key-management link opens the selected provider's website. The endpoint is supplied by the preset. Save stores the connection on this device; it does not need a network request. Test connection is separate and sends only a synthetic connection question, without note excerpts.

Automatic is the default where supported. It follows available general-purpose text models within the selected service, using documented rolling aliases or the provider's own model list. Models and pricing can change. Automatic does not authorize switching to another service or trying other accounts. Choose a fixed model to retain the same model ID. Refresh available models fetches metadata only, without notes. Qwen instead offers documented rolling aliases under Suggested models; it does not claim to fetch an authenticated live list. Advanced allows an exact fixed model name; Custom connection retains manual OpenAI-compatible and local endpoints.

Supported direct providers are OpenAI, Anthropic Claude, Google Gemini, DeepSeek, Alibaba Qwen, Moonshot Kimi and Zhipu GLM; OpenRouter is an explicit gateway choice. GLM has no verified official model-discovery API or cross-version rolling alias in the reviewed documentation: it starts with a documented fixed model and explains that model updates are manual. It must not display a fictional automatic option.

Keys remain device-only Keychain entries scoped to origin. A provider or region change loads only that origin's saved key or in-memory draft; it does not carry another origin's key. API access and website subscriptions are separate products. No provider account, API key, balance, subscription, relay or billing change is created by DayPage.

A saved anonymous connection stays anonymous even if an older version left an unused historical key. Explicit Save removes that origin's old key. If Keychain access fails, setup shows a local error and Retry while retaining typed input and the surrounding chat. Failed reads remain marked for retry across provider changes; they do not become a valid empty key. Save, Test and Refresh stay blocked until the key can be read, and retry never overwrites a newly typed key. A failed write does not claim successful saving or change connection preferences.

Custom local HTTP requires explicit permission and a private-network host. On iPhone, localhost refers to the phone; use the computer's LAN address for a computer-hosted model. Existing baseURL/model preferences remain readable. There is no Vault migration or new preference schema.

## Network and recovery

Selecting a provider or model does not start network requests. Only explicit model refresh, connection testing and chat Send use the network. Chat still previews its excerpts; failure and cancellation preserve the question and existing notes. Model discovery and chat reject redirects and bound response bytes and time. Discovery errors do not send the internal automatic marker as a real model, guess a different provider, or report a successful connection.

## Official references reviewed

- [OpenAI models](https://developers.openai.com/api/docs/models) and [Chat Completions](https://developers.openai.com/api/reference/chat-completions/overview)
- [Claude model discovery](https://platform.claude.com/docs/en/api/models/list) and [Messages](https://platform.claude.com/docs/en/api/messages/create)
- [Gemini OpenAI compatibility](https://ai.google.dev/gemini-api/docs/openai)
- [DeepSeek API and rolling model names](https://api-docs.deepseek.com/quick_start)
- [Qwen OpenAI compatibility and regional keys](https://help.aliyun.com/zh/model-studio/compatibility-of-openai-with-dashscope)
- [Kimi API overview](https://www.kimi.ai/help/kimi-api/api-overview)
- [Kimi current models](https://platform.kimi.ai/docs/api/list-models) and [K3 chat requirements](https://platform.kimi.ai/docs/api/chat)
- [GLM official documentation](https://docs.bigmodel.cn/) and [Z.ai documentation index](https://docs.z.ai/llms.txt)
- [OpenRouter model metadata filtered by the current account](https://openrouter.ai/docs/api/api-reference/models/list-models-filtered-by-user-provider-preferences-privacy-settings-and-guardrails)

## Protocol choices

Trusted official OpenAI reasoning models use the current completion budget and supported low reasoning effort. Its automatic Chat Completions catalog excludes known Responses-only Pro and search variants. Gemini's supported generations use low reasoning effort and an 8,192-token combined budget; selection compares generation before same-generation capability tiers so an old Pro does not outrank the current Argon line. GLM 5.3 retains required thinking, uses low effort and a bounded combined budget. OpenRouter uses its documented unified reasoning controls and the same bounded budget; excluding reasoning from output does not make those tokens free.

Claude uses native Messages and extracts visible text blocks. Kimi K3 requires thinking and preserved reasoning for native assistant history. DayPage keeps its existing visible-message storage: it supplies bounded prior dialogue as explicitly untrusted quoted user context, while retaining the current user question as a separate message. It applies that shape defensively to an explicitly routed Kimi K3 model as well, without claiming a reproduced gateway failure. It does not persist hidden reasoning. GLM's default clearing of prior thinking permits normal visible assistant history. DeepSeek's documented non-thinking mode keeps reflective note chat lightweight. These provider-specific parameters are not applied to arbitrary custom hosts.

Use current official documentation when extending a protocol or automatic family rule. A model ID in a historical screenshot is not proof of current availability. Live-provider access, billing and physical-device Keychain behavior require separate acceptance; synthetic fixtures establish only the exercised request/response and UI boundaries.
