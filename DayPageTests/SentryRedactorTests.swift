import XCTest
@testable import DayPage

/// Tests for SentryRedactor — issue #26.
///
/// These tests pin the redaction behaviour so a future contributor can't
/// silently weaken any pattern. Each case represents a class of data the
/// app has been observed to log; if any one regresses to passing through,
/// the next crash uploaded to Sentry would leak it.
final class SentryRedactorTests: XCTestCase {

    // MARK: - API keys

    func testRedact_openaiKey_isReplaced() {
        let out = SentryRedactor.redact("auth failed: sk-abcd1234efgh5678 returned 401")
        XCTAssertEqual(out?.contains("sk-abcd1234efgh5678"), false)
        XCTAssertTrue(out?.contains("[REDACTED_KEY]") == true)
    }

    func testRedact_stripeStyleKey_isReplaced() {
        let out = SentryRedactor.redact("billing: sk_live_AbCdEfGhIjKlMn")
        XCTAssertEqual(out?.contains("sk_live_AbCdEfGhIjKlMn"), false)
    }

    func testRedact_bearerToken_isReplaced() {
        let out = SentryRedactor.redact("retry: Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig failing")
        XCTAssertFalse(out?.contains("eyJhbGciOiJIUzI1NiJ9.payload.sig") == true)
        XCTAssertTrue(out?.contains("[REDACTED_TOKEN]") == true)
    }

    func testRedact_apiKeyEqualsForm_isReplaced() {
        let out = SentryRedactor.redact("config dump: apikey=ZZxxYYwwVVuuTTss")
        XCTAssertFalse(out?.contains("ZZxxYYwwVVuuTTss") == true)
    }

    // MARK: - PII

    func testRedact_email_isReplaced() {
        let out = SentryRedactor.redact("login fail for alice@example.com (retry 3)")
        XCTAssertFalse(out?.contains("alice@example.com") == true)
        XCTAssertTrue(out?.contains("[REDACTED_EMAIL]") == true)
    }

    func testRedact_phone_isReplaced() {
        let out = SentryRedactor.redact("dial +1 415-555-0123 failed")
        XCTAssertFalse(out?.contains("415-555-0123") == true)
    }

    func testRedact_coordinatePair_isReplaced() {
        let out = SentryRedactor.redact("weather fetch at 31.2345, 121.4678 failed")
        XCTAssertFalse(out?.contains("31.2345, 121.4678") == true)
        XCTAssertTrue(out?.contains("[REDACTED_COORD]") == true)
    }

    func testRedact_longHexBlob_isReplaced() {
        let out = SentryRedactor.redact("token=abcdef1234567890ABCDEF1234567890aa")
        XCTAssertFalse(out?.contains("abcdef1234567890ABCDEF1234567890aa") == true)
    }

    // MARK: - Pass-throughs

    func testRedact_nil_returnsNil() {
        XCTAssertNil(SentryRedactor.redact(nil))
    }

    func testRedact_empty_returnsEmpty() {
        XCTAssertEqual(SentryRedactor.redact(""), "")
    }

    func testRedact_innocuousText_isUnchanged() {
        let s = "compilation succeeded in 1.4s for 12 memos"
        XCTAssertEqual(SentryRedactor.redact(s), s)
    }

    func testRedact_isIdempotent() {
        let once = SentryRedactor.redact("auth: sk-MySecretKey1234 / alice@example.com")
        let twice = SentryRedactor.redact(once)
        XCTAssertEqual(once, twice, "Feeding the redactor's own output back must be a no-op")
    }

    // MARK: - Combination

    func testRedact_multipleSecretsInOneString() {
        let out = SentryRedactor.redact("ctx user=alice@example.com key=sk-AbcDef123456 loc=31.2345, 121.4678")
        XCTAssertFalse(out?.contains("alice@example.com") == true)
        XCTAssertFalse(out?.contains("sk-AbcDef123456") == true)
        XCTAssertFalse(out?.contains("31.2345, 121.4678") == true)
    }
}
