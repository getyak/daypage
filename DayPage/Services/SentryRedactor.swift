import Foundation

// MARK: - SentryRedactor

/// Best-effort secret/PII scrubbing applied to every Sentry payload before
/// it leaves the device. The redactor is intentionally permissive (it
/// allows-through anything that doesn't match a known sensitive pattern)
/// so we keep diagnostic value, but it must catch every category the
/// project actually produces — see the regex set below.
///
/// Categories scrubbed:
///
///   • API key prefixes — `sk-...`, `sk_live_...`, `sk_test_...`, generic
///     "API key=", "Bearer ..." headers. Covers OpenAI, DeepSeek,
///     DashScope, Anthropic, Stripe-style keys.
///   • Email addresses (used as account identifiers — must not be tied
///     to crash events on the Sentry side).
///   • Phone numbers (E.164 / common formats — appear in shared memo text
///     and onboarding logs).
///   • Coordinates — decimal lat/lng pairs that surface in weather and
///     location service logs. Coarse coordinates can re-identify the
///     user's home, so they go.
///   • Long bearer-style hex/base64 blobs (≥32 chars) that haven't matched
///     an earlier pattern — defensive backstop for tokens we forgot to
///     name explicitly.
///
/// Pure functions. Safe to call from any actor. Idempotent: feeding an
/// already-redacted string through the function again is a no-op.
enum SentryRedactor {

    // MARK: - Patterns

    /// Each pattern carries its replacement; order matters because
    /// earlier patterns can shorten the input the later ones see.
    private static let patterns: [(NSRegularExpression, String)] = {
        func r(_ pattern: String) -> NSRegularExpression {
            // swiftlint:disable:next force_try
            try! NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            )
        }
        return [
            // sk-..., sk_live_..., sk_test_..., generic prefix
            (r(#"sk[-_](live|test)?[-_]?[A-Za-z0-9]{6,}"#), "[REDACTED_KEY]"),
            // Bearer / Authorization tokens
            (r(#"(Bearer|Authorization:\s*Bearer)\s+[A-Za-z0-9._\-]{8,}"#), "$1 [REDACTED_TOKEN]"),
            (r(#"(api[_-]?key|apikey|key)\s*[=:]\s*[A-Za-z0-9._\-]{8,}"#), "$1=[REDACTED_KEY]"),
            // Emails
            (r(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#), "[REDACTED_EMAIL]"),
            // Phone (E.164-ish: optional +, 8–15 digits)
            (r(#"\+?\d[\d\s\-]{7,14}\d"#), "[REDACTED_PHONE]"),
            // Decimal coordinate pair (lat, lng) — looks like 31.23, 121.47
            (r(#"-?\d{1,3}\.\d{4,}\s*,\s*-?\d{1,3}\.\d{4,}"#), "[REDACTED_COORD]"),
            // Long hex blob fallback (32+ hex chars not already redacted)
            (r(#"\b[A-Fa-f0-9]{32,}\b"#), "[REDACTED_HEX]")
        ]
    }()

    // MARK: - Public surface

    /// Returns `input` with every matched secret/PII run replaced by a
    /// human-readable marker. `nil` in → `nil` out.
    static func redact(_ input: String?) -> String? {
        guard let input = input, !input.isEmpty else { return input }
        var current = input
        for (re, replacement) in patterns {
            let range = NSRange(current.startIndex..., in: current)
            current = re.stringByReplacingMatches(
                in: current,
                options: [],
                range: range,
                withTemplate: replacement
            )
        }
        return current
    }
}
