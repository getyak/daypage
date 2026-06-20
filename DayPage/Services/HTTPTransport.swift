import Foundation

// MARK: - HTTPTransport

/// Thin protocol that abstracts the one `URLSession.shared.data(for:)` call
/// the LLM layer makes. Exists so tests can inject canned responses without
/// touching the network — issues #30 / #31 / #32.
///
/// Keep this protocol tiny on purpose: a single async-throwing method that
/// mirrors `URLSession.data(for:)` is enough to cover every HTTP call the
/// app makes today (DeepSeek, OpenAI Whisper, OpenWeather). If a future
/// caller needs upload tasks or streaming, add a separate method rather
/// than widening this one — keeping the surface narrow keeps fakes cheap.
protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

// MARK: - URLSession conformance

/// Production conformance. The compiler resolves the unannotated
/// `URLSession.data(for:)` method, so no extra plumbing needed.
extension URLSession: HTTPTransport {}

// MARK: - Default

/// Single source of truth for "which transport does production use". Tests
/// override via dependency injection at the call site; production code
/// just reads this property so any future swap (e.g. enabling a logging
/// transport in DEBUG) is a one-line change.
enum HTTPTransports {
    nonisolated(unsafe) static var shared: HTTPTransport = URLSession.shared
}
