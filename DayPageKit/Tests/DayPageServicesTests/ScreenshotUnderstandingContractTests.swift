import XCTest
import Foundation
import DayPageModels
import DayPageStorage
@testable import DayPageServices

// MARK: - Fixtures

private enum ConsentFixtures {
    static let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )!

    static func makeVault() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("daypage-screenshot-consent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Recording transport counting outbound requests.
private actor CountingTransport: HTTPTransport {
    private(set) var count = 0
    let handler: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(handler: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        count += 1
        return try await handler(request)
    }
}

private struct FailIfCalledProvider: ScreenshotUnderstandingProvider {
    var providerInfo: ScreenshotProviderInfo {
        .init(kind: "test", model: "never", promptVersion: "test")
    }
    func understand(_ request: ScreenshotUnderstandingRequest) async throws -> ScreenshotUnderstandingResult {
        XCTFail("Provider must not be called while screenshot cloud analysis is disabled")
        throw ScreenshotUnderstandingProviderError.invalidResponse
    }
}

private struct OkProvider: ScreenshotUnderstandingProvider {
    var providerInfo: ScreenshotProviderInfo {
        .init(kind: "test", model: "ok", promptVersion: "test")
    }
    func understand(_ request: ScreenshotUnderstandingRequest) async throws -> ScreenshotUnderstandingResult {
        ScreenshotUnderstandingResult(
            suggestedTitle: "标题",
            kind: .other,
            summary: "摘要",
            visualDescription: "描述",
            provider: providerInfo
        )
    }
}

private struct EmptyExtractor: ScreenshotEvidenceExtracting {
    func extract(from imageData: Data) async throws -> ScreenshotEvidence { ScreenshotEvidence() }
}

/// Scripted authorization fake: pops verdicts in order; the last repeats.
private final class ScriptedConsent: AIConsentChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var verdicts: [Result<Void, AIAuthorizationError>]

    init(_ verdicts: [Result<Void, AIAuthorizationError>]) {
        self.verdicts = verdicts
    }

    func authorize() throws {
        lock.lock()
        let verdict: Result<Void, AIAuthorizationError>
        if verdicts.count > 1 {
            verdict = verdicts.removeFirst()
        } else if let only = verdicts.first {
            verdict = only
        } else {
            verdict = .success(())
        }
        lock.unlock()
        try verdict.get()
    }
}

private func okResponseBody() -> Data {
    let output: [String: Any] = [
        "suggestedTitle": "t",
        "kind": "other",
        "summary": "s",
        "visualDescription": "v",
        "entities": [],
        "suggestedActions": [],
        "warnings": [],
    ]
    let responsePayload: [String: Any] = [
        "output": [["content": [[
            "type": "output_text",
            "text": String(data: try! JSONSerialization.data(withJSONObject: output), encoding: .utf8)!,
        ]]]],
    ]
    // swiftlint:disable:next force_try
    return try! JSONSerialization.data(withJSONObject: responsePayload)
}

// MARK: - Provider adapter live guards

/// Issue #928 second-batch finding 1: the OpenAI adapter must re-check the
/// live policy immediately before send AND before response acceptance. A
/// request authorized at capture time must not go out after the user turned
/// the switches off, and a late response must not be accepted.
final class ScreenshotUnderstandingContractTests: XCTestCase {

    private func makeProvider(consent: AIConsentChecking, transport: HTTPTransport) -> OpenAIScreenshotUnderstandingProvider {
        OpenAIScreenshotUnderstandingProvider(
            configuration: .init(apiKey: "test-only"),
            transport: transport,
            consent: consent
        )
    }

    private func makeRequest() -> ScreenshotUnderstandingRequest {
        ScreenshotUnderstandingRequest(
            captureID: UUID(),
            imageData: Data([1, 2, 3]),
            imageMIMEType: "image/jpeg",
            evidence: ScreenshotEvidence(),
            localeIdentifier: "zh-Hans-CN"
        )
    }

    func testDeniedEntryReachesNoTransport() async {
        let transport = CountingTransport { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let provider = makeProvider(
            consent: ScriptedConsent([.failure(.screenshotCloudDisabled)]),
            transport: transport
        )
        do {
            _ = try await provider.understand(makeRequest())
            XCTFail("understand() must refuse when screenshot cloud analysis is off")
        } catch let error as AIAuthorizationError {
            XCTAssertEqual(error, .screenshotCloudDisabled)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        let count = await transport.count
        XCTAssertEqual(count, 0, "no request may leave after the switch turns off")
    }

    func testRevocationBetweenSendAndAcceptanceRefusesTheResponse() async {
        let transport = CountingTransport { request in
            (okResponseBody(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        // First check (pre-send) passes; the second (pre-acceptance) denies.
        let provider = makeProvider(
            consent: ScriptedConsent([.success(()), .failure(.aiDisabled)]),
            transport: transport
        )
        do {
            _ = try await provider.understand(makeRequest())
            XCTFail("a late response must not be accepted after revocation")
        } catch let error as AIAuthorizationError {
            XCTAssertEqual(error, .aiDisabled)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        let count = await transport.count
        XCTAssertEqual(count, 1)
    }

    func testAllowAllPolicyStillDeliversTheParsedResult() async throws {
        let transport = CountingTransport { request in
            (okResponseBody(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let provider = makeProvider(consent: AllowAllAIConsent(), transport: transport)
        let result = try await provider.understand(makeRequest())
        XCTAssertEqual(result.suggestedTitle, "t")
        let count = await transport.count
        XCTAssertEqual(count, 1)
    }
}

// MARK: - Coordinator live guards and durable local-only state

@MainActor
final class ScreenshotConsentBoundaryTests: XCTestCase {
    private var vault: URL!
    private var previousOverride: URL?

    override func setUpWithError() throws {
        vault = try ConsentFixtures.makeVault()
        previousOverride = VaultInitializer.testOverrideURL
        VaultInitializer.testOverrideURL = vault
    }

    override func tearDownWithError() throws {
        VaultInitializer.testOverrideURL = previousOverride
        if let vault { try? FileManager.default.removeItem(at: vault) }
    }

    func testLiveGuardBlocksRequestEvenWhenCaptureSnapshotAllowed() async throws {
        // A pass captured `cloudAnalysisAllowed: true`, but the live policy is
        // denied at request time: zero provider calls and a durable localOnly
        // phase — never failed/pendingNetwork.
        let coordinator = ScreenshotCaptureCoordinator(
            store: ScreenshotCaptureStore(vaultRoot: vault),
            evidenceExtractor: EmptyExtractor(),
            understandingProvider: FailIfCalledProvider(),
            cloudConsent: ScriptedConsent([.failure(.aiDisabled)])
        )
        let outcome = try await coordinator.ingest(
            data: ConsentFixtures.onePixelPNG,
            declaredContentType: "image/png",
            source: .actionButtonShortcut,
            cloudAnalysisAllowed: true
        )
        let processed = await coordinator.retry(
            captureID: outcome.manifest.id,
            cloudAnalysisAllowed: true
        )

        XCTAssertEqual(processed?.phase, .localOnly)
        XCTAssertNil(processed?.failureReason)
    }

    func testLateFailureCannotOverwriteLocalOnly() async throws {
        // keepLocal closes the capture while a request is in flight; the late
        // provider FAILURE must not overwrite the durable localOnly state.
        final class GatedFailProvider: ScreenshotUnderstandingProvider, @unchecked Sendable {
            let gate = GatedBox()
            var providerInfo: ScreenshotProviderInfo {
                .init(kind: "test", model: "gated-fail", promptVersion: "test")
            }
            func understand(_ request: ScreenshotUnderstandingRequest) async throws -> ScreenshotUnderstandingResult {
                await gate.enter()
                throw URLError(.notConnectedToInternet)
            }
        }
        let provider = GatedFailProvider()
        let coordinator = ScreenshotCaptureCoordinator(
            store: ScreenshotCaptureStore(vaultRoot: vault),
            evidenceExtractor: EmptyExtractor(),
            understandingProvider: provider,
            // Explicit policy: this test's subject is the late-failure state
            // machine, not the live toggle (covered separately).
            cloudConsent: AllowAllAIConsent()
        )
        let outcome = try await coordinator.ingest(
            data: ConsentFixtures.onePixelPNG,
            declaredContentType: "image/png",
            source: .actionButtonShortcut,
            cloudAnalysisAllowed: true
        )
        let processTask = Task { @MainActor in
            await coordinator.retry(captureID: outcome.manifest.id, cloudAnalysisAllowed: true)
        }
        await provider.gate.waitUntilEntered()
        try await coordinator.keepLocal(captureID: outcome.manifest.id)
        provider.gate.release()
        _ = await processTask.value

        let reader = ScreenshotCaptureStore(vaultRoot: vault)
        let manifest = try await reader.manifest(for: outcome.manifest.id)
        XCTAssertEqual(manifest.phase, .localOnly)
        XCTAssertNotEqual(manifest.failureReason, "network-unavailable")
    }

    func testSettingsRevokeInvalidatesInFlightCaptureEpoch() async throws {
        // The settings revoke hook bumps the epoch; a late success is then
        // discarded instead of accepted while the setting remains off.
        final class GatedOkProvider: ScreenshotUnderstandingProvider, @unchecked Sendable {
            let gate = GatedBox()
            var providerInfo: ScreenshotProviderInfo {
                .init(kind: "test", model: "gated-ok", promptVersion: "test")
            }
            func understand(_ request: ScreenshotUnderstandingRequest) async throws -> ScreenshotUnderstandingResult {
                await gate.enter()
                return ScreenshotUnderstandingResult(
                    suggestedTitle: "late",
                    kind: .other,
                    summary: "late",
                    visualDescription: "late",
                    provider: providerInfo
                )
            }
        }
        let provider = GatedOkProvider()
        let coordinator = ScreenshotCaptureCoordinator(
            store: ScreenshotCaptureStore(vaultRoot: vault),
            evidenceExtractor: EmptyExtractor(),
            understandingProvider: provider,
            // Explicit policy: the epoch invalidation under test is wired from
            // Settings through noteCloudConsentRevoked(), independent of the
            // ambient defaults.
            cloudConsent: AllowAllAIConsent()
        )
        let outcome = try await coordinator.ingest(
            data: ConsentFixtures.onePixelPNG,
            declaredContentType: "image/png",
            source: .actionButtonShortcut,
            cloudAnalysisAllowed: true
        )
        let processTask = Task { @MainActor in
            await coordinator.retry(captureID: outcome.manifest.id, cloudAnalysisAllowed: true)
        }
        await provider.gate.waitUntilEntered()
        // Settings → screenshot cloud OFF calls this hook.
        await coordinator.noteCloudConsentRevoked()
        provider.gate.release()
        _ = await processTask.value

        let reader = ScreenshotCaptureStore(vaultRoot: vault)
        let manifest = try await reader.manifest(for: outcome.manifest.id)
        XCTAssertEqual(manifest.phase, .localOnly, "a late completion must not be accepted after revoke")
        XCTAssertNil(manifest.understanding)
    }
}

/// Tiny gate used by fake providers/extractors: bounded entry wait so a broken
/// preflight fails the test instead of parking xctest.
final class GatedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var released = false

    func enter() async {
        lock.lock()
        entered = true
        let alreadyReleased = released
        lock.unlock()
        if alreadyReleased { return }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            lock.lock()
            let done = released
            lock.unlock()
            if done { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func waitUntilEntered() async {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            lock.lock()
            let seen = entered
            lock.unlock()
            if seen { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Gated provider/extractor never entered — an earlier step failed")
        release()
    }

    func release() {
        lock.lock()
        released = true
        lock.unlock()
    }
}
