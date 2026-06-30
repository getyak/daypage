import Foundation

// MARK: - RetryPolicy

/// Backoff schedule + attempt budget for retryable async operations.
///
/// Encodes the schedule that LLMClient and CompilationService independently
/// hard-coded as `[0, 2, 6]` seconds × 3 attempts. By making it explicit and
/// passable, individual call sites (chat vs. compilation) can later pick
/// different policies without forking the loop body.
public struct RetryPolicy: Equatable {
    /// Total attempts including the first try (must be ≥ 1).
    public let maxAttempts: Int
    /// Sleep before attempt N (1-indexed). Index 0 is always 0s — the first
    /// attempt never waits. Indices past the end repeat the last value.
    public let backoffSeconds: [Double]

    /// Original DayPage default: 3 attempts at 0 / 2 / 6 seconds.
    public static let standard = RetryPolicy(maxAttempts: 3, backoffSeconds: [0, 2, 6])

    /// Sleep duration before the given attempt number (1-indexed). Attempt 1
    /// always returns 0; attempts past the schedule reuse the tail value.
    public func delayBeforeAttempt(_ attempt: Int) -> Double {
        guard attempt > 1 else { return 0 }
        let idx = min(attempt - 1, backoffSeconds.count - 1)
        return backoffSeconds[idx]
    }
}

// MARK: - RetryDecision

/// What `retryAsync` should do when a thrown error is observed.
public enum RetryDecision {
    /// Retry the next attempt (subject to the attempt budget).
    case retry
    /// Surface the error immediately and stop the loop.
    case stop
}

// MARK: - retryAsync

/// Execute `operation` with the given `RetryPolicy`. The classifier closure
/// decides per-error whether to retry; throwing from it re-throws unchanged.
///
/// Why a classifier rather than a fixed retry-on-everything: LLM clients need
/// to fail fast on 401 / 400 but retry on 429 / timeout. Classification
/// lives at the call site so we don't need a new policy per error taxonomy.
///
/// - Parameters:
///   - policy: Attempt budget + backoff schedule.
///   - onRetry: Optional callback fired *before* each non-first attempt
///     with `(attempt, maxAttempts)`. Useful for surfacing retry counts to UI.
///   - shouldRetry: Inspect the thrown error and return `.retry` / `.stop`.
///     Defaults to retrying every error.
///   - operation: The retryable async work.
/// - Returns: The successful operation result.
func retryAsync<T>(
    policy: RetryPolicy = .standard,
    onRetry: ((Int, Int) -> Void)? = nil,
    shouldRetry: (Error) -> RetryDecision = { _ in .retry },
    operation: () async throws -> T
) async throws -> T {
    precondition(policy.maxAttempts >= 1, "RetryPolicy.maxAttempts must be ≥ 1")
    var lastError: Error?

    for attempt in 1...policy.maxAttempts {
        if attempt > 1 {
            onRetry?(attempt, policy.maxAttempts)
            let delay = policy.delayBeforeAttempt(attempt)
            if delay > 0 {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        do {
            return try await operation()
        } catch {
            lastError = error
            if attempt == policy.maxAttempts { throw error }
            switch shouldRetry(error) {
            case .retry: continue
            case .stop:  throw error
            }
        }
    }

    throw lastError ?? CancellationError()
}
