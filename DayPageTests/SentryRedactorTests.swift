import XCTest
import UIKit
import DayPageServices
@testable import DayPage

/// The opt-in preview is the same payload used for feedback submission.
final class FeedbackPrivacyTests: XCTestCase {
    func testDiagnosticPayloadOmitsAccountAndPreciseTimezone() {
        let context = FeedbackContext(
            appVersion: "1.2", buildNumber: "34", bundleId: "qa.daypage",
            osVersion: "iOS 26", deviceModel: "iPhone", locale: "zh_CN",
            timezone: "Private/Timezone", isOnline: true,
            userId: "private-account-identifier", userEmail: "private@private-company.example",
            loginProvider: "private-provider"
        )
        let payload = context.promptDescription
        for value in ["private-account-identifier", "private@", "private-company.example",
                      "Private/Timezone", "private-provider"] {
            XCTAssertFalse(payload.contains(value), "Unnecessary identity must never reach GitHub")
        }
        XCTAssertTrue(payload.contains("appVersion: 1.2 (34)"))
        XCTAssertTrue(payload.contains("online: true"))
    }

    @MainActor
    func testCaptureOmitsAccountAndPreciseTimezone() {
        let context = FeedbackContext.capture()
        XCTAssertNil(context.userId)
        XCTAssertNil(context.userEmail)
        XCTAssertNil(context.loginProvider)
        XCTAssertEqual(context.timezone, "")
    }

    @MainActor
    func testNewFeedbackAndResetRequireDiagnosticChoiceAgain() {
        let model = FeedbackViewModel()
        XCTAssertFalse(model.includeDiagnostics)
        model.includeDiagnostics = true
        model.reset()
        XCTAssertFalse(model.includeDiagnostics)
    }

    private enum SyntheticFailure: Error { case stopped }

    @MainActor
    func testConcurrentSendStaysLockedAcrossLateVoiceError() async {
        let entered = expectation(description: "First request paused")
        var continuation: CheckedContinuation<GitHubIssue, Error>?
        var calls = 0
        let model = FeedbackViewModel(createIssue: { _, _, _ in
            calls += 1
            return try await withCheckedThrowingContinuation {
                continuation = $0
                entered.fulfill()
            }
        })
        model.rawFeedback = "Synthetic feedback"
        let first = Task { await model.send() }
        await fulfillment(of: [entered], timeout: 2)
        guard let continuation else { XCTFail("Request did not start"); return }
        model.handleVoiceRecordingComplete(result: VoiceRecordingResult(
            filePath: "synthetic", fileURL: URL(fileURLWithPath: "/synthetic"),
            duration: 0, transcript: nil))
        // Even another asynchronous status writer cannot unlock the request.
        model.status = .error("Synthetic late error")
        await model.send()
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(model.isSending)
        model.reset()
        XCTAssertEqual(model.rawFeedback, "Synthetic feedback")
        continuation.resume(throwing: SyntheticFailure.stopped)
        await first.value
        XCTAssertFalse(model.isSending)
    }

    @MainActor
    func testDiagnosticsOmittedUnlessExplicitlySelected() async {
        var bodies: [String] = []
        let model = FeedbackViewModel(createIssue: { _, body, _ in
            bodies.append(body)
            throw SyntheticFailure.stopped
        })
        model.rawFeedback = "Synthetic feedback"
        await model.send()
        XCTAssertFalse(bodies[0].contains("Diagnostic context"))
        model.includeDiagnostics = true
        let preview = model.diagnosticsPreview
        await model.send()
        XCTAssertTrue(bodies[1].contains(preview))
        XCTAssertTrue(bodies[1].contains("Diagnostic context"))
    }

    @MainActor
    func testUploadFreezesDraftAttachmentsAndDiagnosticsChoice() async {
        let entered = expectation(description: "Image upload paused")
        var continuation: CheckedContinuation<String, Error>?
        var bodies: [String] = []
        let model = FeedbackViewModel(createIssue: { _, body, _ in
            bodies.append(body)
            throw SyntheticFailure.stopped
        }, uploadImage: { _, _ in
            try await withCheckedThrowingContinuation { continuation = $0; entered.fulfill() }
        })
        model.rawFeedback = "Original synthetic draft"
        model.pendingImages = [PendingFeedbackImage(data: Data([1]), thumbnail: UIImage(), filename: "qa.jpg")]
        let task = Task { await model.send() }
        await fulfillment(of: [entered], timeout: 2)
        guard let continuation else { XCTFail("Upload did not start"); return }
        model.includeDiagnostics = true
        model.rawFeedback = "Late private draft"
        model.pendingImages = []
        continuation.resume(returning: "https://example.invalid/qa.jpg")
        await task.value
        XCTAssertEqual(bodies.count, 1)
        XCTAssertTrue(bodies[0].contains("Original synthetic draft"))
        XCTAssertTrue(bodies[0].contains("qa.jpg"))
        XCTAssertFalse(bodies[0].contains("Late private draft"))
        XCTAssertFalse(bodies[0].contains("Diagnostic context"))
    }

    @MainActor
    func testOverlappingImageLoadsBlockSendUntilBothFinish() async {
        var continuations: [CheckedContinuation<Data?, Never>] = []
        var requests = 0
        let entered = expectation(description: "Two image loads paused")
        entered.expectedFulfillmentCount = 2
        let model = FeedbackViewModel(createIssue: { _, _, _ in
            requests += 1
            throw SyntheticFailure.stopped
        })
        model.rawFeedback = "Synthetic feedback"
        let load: () async throws -> Data? = {
            await withCheckedContinuation { continuations.append($0); entered.fulfill() }
        }
        let first = Task { await model.addImageData(load: load) }
        let second = Task { await model.addImageData(load: load) }
        await fulfillment(of: [entered], timeout: 2)
        guard continuations.count == 2 else { XCTFail("Loads did not start"); return }
        XCTAssertEqual(model.imageProcessingCount, 2)
        continuations[0].resume(returning: nil)
        await first.value
        XCTAssertTrue(model.isProcessingImage)
        await model.send()
        XCTAssertEqual(requests, 0)
        continuations[1].resume(returning: nil)
        await second.value
        XCTAssertFalse(model.isProcessingImage)
        await model.send()
        XCTAssertEqual(requests, 1)
    }

    @MainActor
    func testVoiceCompletionFromResetDraftCannotChangeNewDraft() {
        let model = FeedbackViewModel()
        model.startVoiceRecording()
        let generation = model.voiceGeneration
        model.reset()
        model.rawFeedback = "New synthetic draft"
        let result = VoiceRecordingResult(filePath: "synthetic",
            fileURL: URL(fileURLWithPath: "/synthetic"), duration: 0, transcript: "Old private transcript")
        model.handleVoiceRecordingComplete(result: result, generation: generation)
        XCTAssertEqual(model.rawFeedback, "New synthetic draft")
        XCTAssertEqual(model.status, .idle)
    }

    @MainActor
    func testResetDiscardsLateImageImportWithoutChangingNewDraft() async {
        let entered = expectation(description: "Image load paused")
        var continuation: CheckedContinuation<Data?, Never>?
        let model = FeedbackViewModel()
        let task = Task {
            await model.addImageData {
                await withCheckedContinuation { continuation = $0; entered.fulfill() }
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        guard let continuation else { XCTFail("Load did not start"); return }
        model.reset()
        model.rawFeedback = "New synthetic draft"
        continuation.resume(returning: nil)
        await task.value
        XCTAssertEqual(model.status, .idle)
        XCTAssertEqual(model.rawFeedback, "New synthetic draft")
        XCTAssertTrue(model.pendingImages.isEmpty)
        XCTAssertEqual(model.imageProcessingCount, 0)
    }

}

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
