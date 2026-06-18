import Foundation
import Sentry

// MARK: - LLMMessage

/// A single chat message in an OpenAI-compatible conversation.
struct LLMMessage: Equatable {
    enum Role: String {
        case system
        case user
        case assistant
    }
    let role: Role
    let content: String

    static func system(_ content: String) -> LLMMessage { LLMMessage(role: .system, content: content) }
    static func user(_ content: String) -> LLMMessage { LLMMessage(role: .user, content: content) }
    static func assistant(_ content: String) -> LLMMessage { LLMMessage(role: .assistant, content: content) }
}

// MARK: - LLMError

/// Errors surfaced by ``LLMClient``. Kept distinct from ``CompilationError`` so
/// callers (compilation vs. chat) can map them to their own UX copy.
enum LLMError: LocalizedError {
    case missingApiKey
    case invalidURL
    case offline
    case networkTimeout
    case rateLimited
    case apiError(statusCode: Int, body: String)
    case emptyResponse
    case unknown(Error)

    var errorDescription: String? {
        switch self {
        case .missingApiKey: return "DeepSeek API Key 未配置"
        case .invalidURL: return "API URL 无效"
        case .offline: return "当前离线，请检查网络后重试"
        case .networkTimeout: return "网络请求超时"
        case .rateLimited: return "请求频率超限（429），请稍后重试"
        case .apiError(let code, let body):
            if code == 401 { return "API Key 无效或已过期（401）" }
            return "API 错误 \(code)：\(body.prefix(200))"
        case .emptyResponse: return "AI 返回为空"
        case .unknown(let err): return "未知错误：\(err.localizedDescription)"
        }
    }
}

// MARK: - LLMClient

/// 可复用的 OpenAI 兼容聊天补全客户端（DeepSeek）。
///
/// 设计动机：编译管线（`CompilationService`）与「和过去对话」Agent
/// （`MemoryChatService`）都需要调用同一个 LLM 端点。把网络、重试、
/// 错误映射、Sentry span 抽到这里，两边共用，避免逻辑分叉。
///
/// 与编译管线的边界：本类**只负责传输**——构造 messages、发请求、重试、
/// 返回纯文本。prompt 构造、JSON 解析、文件写入仍归各调用方所有。
///
/// 隐私/架构约束（研究文档 §5 红线）：云端调用走前台/后台均可，但
/// **端侧模型不可用于后台**。本类是云端通道；端侧分流是未来的独立实现点。
struct LLMClient {

    // MARK: - Configuration

    struct Config {
        var baseURL: String
        var apiKey: String
        var model: String
        var maxTokens: Int
        var temperature: Double
        var timeout: TimeInterval

        /// 默认从 `Secrets` 解析 DeepSeek 配置（与原编译管线一致）。
        @MainActor
        static func deepSeek(
            maxTokens: Int = 4096,
            temperature: Double = 0.7,
            timeout: TimeInterval = 120
        ) -> Config {
            let base = Secrets.deepSeekBaseURL.isEmpty
                ? "https://api.deepseek.com/v1"
                : Secrets.deepSeekBaseURL
            let model = Secrets.deepSeekModel.isEmpty ? "deepseek-v4-pro" : Secrets.deepSeekModel
            return Config(
                baseURL: base,
                apiKey: Secrets.resolvedDeepSeekApiKey,
                model: model,
                maxTokens: maxTokens,
                temperature: temperature,
                timeout: timeout
            )
        }
    }

    let config: Config
    /// Sentry transaction 名称，用于区分 compilation / chat 调用。
    let spanName: String

    init(config: Config, spanName: String = "llm.chat") {
        self.config = config
        self.spanName = spanName
    }

    // MARK: - Chat Completion

    /// 发送一组 messages，返回 assistant 的纯文本回复（已 trim）。
    /// 带指数退避重试（与原编译管线一致：3 次，0/2/6s）。
    /// - Parameter onRetry: 每次重试前回调 `(当前次数, 最大次数)`。
    func complete(
        messages: [LLMMessage],
        onRetry: ((Int, Int) -> Void)? = nil
    ) async throws -> String {
        let online = await MainActor.run { NetworkMonitor.shared.isOnline }
        guard online else { throw LLMError.offline }
        guard !config.apiKey.isEmpty else { throw LLMError.missingApiKey }

        let maxAttempts = 3
        let backoffSeconds: [Double] = [0, 2, 6]
        var lastError: Error = LLMError.networkTimeout

        for attempt in 1...maxAttempts {
            if attempt > 1 {
                onRetry?(attempt, maxAttempts)
                let delay = backoffSeconds[min(attempt - 1, backoffSeconds.count - 1)]
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            do {
                return try await sendOnce(messages: messages)
            } catch let error as LLMError {
                switch error {
                case .rateLimited:
                    lastError = error
                case .apiError(let code, _) where code == 401 || code == 403 || code == 400:
                    throw error  // 不重试认证/请求格式错误
                case .missingApiKey, .invalidURL, .emptyResponse:
                    throw error
                default:
                    lastError = error
                }
            } catch let urlError as URLError {
                switch urlError.code {
                case .timedOut:
                    lastError = LLMError.networkTimeout
                case .notConnectedToInternet, .networkConnectionLost:
                    lastError = LLMError.offline
                default:
                    throw LLMError.unknown(urlError)
                }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    // MARK: - Single request

    private func sendOnce(messages: [LLMMessage]) async throws -> String {
        guard let url = URL(string: "\(config.baseURL)/chat/completions") else {
            throw LLMError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = config.timeout

        let body: [String: Any] = [
            "model": config.model,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "max_tokens": config.maxTokens,
            "temperature": config.temperature
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let dsnEmpty = await MainActor.run { Secrets.sentryDSN.isEmpty }
        let span = dsnEmpty ? nil : SentrySDK.startTransaction(name: spanName, operation: "http.client")
        defer { span?.finish() }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.apiError(statusCode: -1, body: "No HTTP response")
        }
        guard http.statusCode == 200 else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "(empty)"
            DayPageLogger.log(level: "ERROR", message: "[LLMClient/\(spanName)] status=\(http.statusCode) body=\(bodyStr.prefix(500))")
            if http.statusCode == 429 { throw LLMError.rateLimited }
            throw LLMError.apiError(statusCode: http.statusCode, body: bodyStr)
        }

        return try Self.parseContent(from: data)
    }

    // MARK: - Response parsing

    /// 从 OpenAI 兼容响应中提取 `choices[0].message.content`。
    /// Exposed for unit tests.
    static func parseContent(from data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError.emptyResponse
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LLMError.emptyResponse }
        return trimmed
    }
}
