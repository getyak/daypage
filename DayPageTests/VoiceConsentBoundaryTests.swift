import Testing
import Foundation
import DayPageModels
import DayPageStorage
import DayPageServices
@testable import DayPage

// Issue #928 — VoiceService Whisper upload-retry and on-device fallback
// boundaries. Every dependency is a recording fake: fake bytes, fake HTTP,
// scripted policy, fake fallback. No microphone, no speech permission, no
// SFSpeechRecognizer, no real keys, no live calls.

private final class ScriptedVoiceConsent: AIConsentChecking, @unchecked Sendable {
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

private final class WhisperFakes: @unchecked Sendable {
    let transport = WhisperTransport()
    private let lock = NSLock()
    private var _readCount = 0
    private var _fallbackCount = 0
    var readCount: Int { lock.lock(); defer { lock.unlock() }; return _readCount }
    var fallbackCount: Int { lock.lock(); defer { lock.unlock() }; return _fallbackCount }

    var read: @Sendable (URL) async throws -> Data {
        { [self] _ in
            lock.lock(); _readCount += 1; lock.unlock()
            return Data("fake-audio-bytes".utf8)
        }
    }

    var fallback: @Sendable (URL) async -> String? {
        { [self] _ in
            lock.lock(); _fallbackCount += 1; lock.unlock()
            return "on-device-fallback"
        }
    }
}

private final class WhisperTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private var _statuses: [Int] = []
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    var statuses: [Int] { lock.lock(); defer { lock.unlock() }; return _statuses }

    func queue(statusCodes: [Int]) {
        lock.lock(); _statuses = statusCodes; lock.unlock()
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.lock()
        _requests.append(request)
        let status = _statuses.isEmpty ? 200 : _statuses.removeFirst()
        lock.unlock()
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://whisper.invalid")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        if status == 200 {
            let body = try JSONSerialization.data(withJSONObject: ["text": "你好"])
            return (body, response)
        }
        return (Data("boom".utf8), response)
    }
}

@MainActor
@Suite("VoiceConsentBoundaryTests", .serialized)
struct VoiceConsentBoundaryTests {

    private let sampleURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("voice-consent-\(UUID().uuidString).m4a")

    private func makeVoice(
        consent: AIConsentChecking,
        fakes: WhisperFakes
    ) -> VoiceService {
        let voice = VoiceService()
        voice.transcriptionProviderOverride = .whisper
        voice.transcriptionConsentOverride = consent
        voice.whisperReadOverride = fakes.read
        voice.whisperTransportOverride = fakes.transport
        voice.whisperRetryDelaysNanoseconds = [0]  // 2 attempts, no sleeps
        voice.whisperTestConfiguration = (
            apiKey: "sk-test-only",
            endpoint: URL(string: "https://whisper.invalid/v1/audio/transcriptions")!
        )
        voice.onDeviceFallbackOverride = fakes.fallback
        voice.networkAvailableOverride = true
        return voice
    }

    @Test("First 500 then OFF: exactly one upload and typed terminal exit to local fallback")
    func first500ThenOffUploadsOnceAndFallsBack() async throws {
        let fakes = WhisperFakes()
        fakes.transport.queue(statusCodes: [500])
        let voice = makeVoice(
            consent: ScriptedVoiceConsent([
                .success(()), .success(()), .success(()), .success(()), .failure(.aiDisabled)
            ]),
            fakes: fakes
        )

        let result = await voice.transcribeAudio(at: sampleURL)

        #expect(result == "on-device-fallback", "typed disabled exit routes to the local fallback")
        #expect(fakes.transport.requests.count == 1, "exactly one upload — the retry is refused")
        #expect(fakes.fallbackCount == 1)
    }

    @Test("OFF during the file read: zero uploads, local fallback")
    func flipDuringReadSendsZeroUploads() async throws {
        let fakes = WhisperFakes()
        // Public entry and Whisper entry allow the read; post-read denies.
        let consent = ScriptedVoiceConsent([.success(()), .success(()), .failure(.aiDisabled)])
        let voice = makeVoice(consent: consent, fakes: fakes)

        let result = await voice.transcribeAudio(at: sampleURL)

        #expect(result == "on-device-fallback")
        #expect(fakes.readCount == 1, "the fake read ran")
        #expect(fakes.transport.requests.isEmpty, "zero HTTP sends after the flip")
    }

    @Test("Initial OFF: fake fallback only, zero reads and zero sends")
    func initialOffUsesFakeFallbackAndSendsNothing() async throws {
        let fakes = WhisperFakes()
        let voice = makeVoice(
            consent: ScriptedVoiceConsent([.failure(.aiDisabled)]),
            fakes: fakes
        )

        let result = await voice.transcribeAudio(at: sampleURL)

        #expect(result == "on-device-fallback")
        #expect(fakes.readCount == 0)
        #expect(fakes.transport.requests.isEmpty)
        #expect(fakes.fallbackCount == 1)
    }

    @Test("Allowed positive control: one upload returns the transcript, no fallback")
    func allowedPathTranscribesOnce() async throws {
        let fakes = WhisperFakes()
        let voice = makeVoice(
            consent: ScriptedVoiceConsent([.success(())]),
            fakes: fakes
        )

        let result = await voice.transcribeAudio(at: sampleURL)

        #expect(result == "你好")
        #expect(fakes.transport.requests.count == 1)
        #expect(fakes.fallbackCount == 0)
    }
}
