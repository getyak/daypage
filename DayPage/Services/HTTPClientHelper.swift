import Foundation

// MARK: - HTTPClientHelper

/// Builders for JSON-over-HTTPS requests used across DayPage services.
///
/// Before this helper, CompilationService / LLMClient / FeedbackService /
/// VoiceService / ThreadConversationViewModel / SettingsView each wrote the
/// same three lines (`setValue("Bearer …")`, `setValue("application/json")`,
/// `timeoutInterval = …`). Diffs around header conventions were noisy and
/// auth changes had to touch five files.
///
/// Keep this helper transport-only: no retry, no body construction beyond
/// JSON encoding, no response handling. Those belong to the caller or
/// ``RetryHelper``.
enum HTTPClientHelper {

    /// Build a `URLRequest` for an OpenAI-compatible JSON POST endpoint.
    /// - Parameters:
    ///   - url: Fully qualified endpoint URL.
    ///   - apiKey: Bearer token; caller is responsible for non-emptiness.
    ///   - timeout: Per-request timeout in seconds. Default mirrors prior callers.
    /// - Returns: A `POST` request with Authorization + Content-Type set; body unset.
    static func bearerJSON(url: URL, apiKey: String, timeout: TimeInterval = 120) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        return request
    }

    /// Same as ``bearerJSON(url:apiKey:timeout:)`` but encodes `body` into JSON.
    /// Throws when `body` is not a valid JSON object.
    static func bearerJSON(
        url: URL,
        apiKey: String,
        timeout: TimeInterval = 120,
        body: [String: Any]
    ) throws -> URLRequest {
        var request = bearerJSON(url: url, apiKey: apiKey, timeout: timeout)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}
