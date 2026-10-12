import Testing
import Foundation
import DayPageModels
import DayPageStorage
import DayPageServices
@testable import DayPage

// Issue #928 — Doubao ASR request boundaries. Everything below runs against
// recording fakes: no microphone, no speech permission, no provider traffic,
// no credential/keychain lookups (synthetic connection configs only).

/// Scripted authorization fake: verdicts pop in order; the last repeats.
private final class ScriptedASRConsent: AIConsentChecking, @unchecked Sendable {
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

/// Recording transport + gated read seam for the file ASR boundary.
private final class FileASRFakes: @unchecked Sendable {
    let transport = RecordingASRTransport()
    private let lock = NSLock()
    private var _readCount = 0
    var readCount: Int { lock.lock(); defer { lock.unlock() }; return _readCount }

    var read: @Sendable (URL) async throws -> Data {
        { [self] _ in
            lock.lock(); _readCount += 1; lock.unlock()
            return Data("fake-audio".utf8)
        }
    }
}

private final class RecordingASRTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.lock(); _requests.append(request); lock.unlock()
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://doubao.invalid")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["X-Api-Status-Code": "20000000"]
        )!
        let body = try JSONSerialization.data(withJSONObject: ["result": ["text": "你好"]])
        return (body, response)
    }
}

/// Recording fake socket: records every frame written to the wire and counts
/// cancels, so "zero frames", "close once", and "sticky latch" are provable.
private final class FakeStreamSocket: DoubaoStreamSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var _frames: [Data] = []
    private var _cancelCount = 0
    var frames: [Data] { lock.lock(); defer { lock.unlock() }; return _frames }
    var cancelCount: Int { lock.lock(); defer { lock.unlock() }; return _cancelCount }

    func sendFrame(_ data: Data) {
        lock.lock(); _frames.append(data); lock.unlock()
    }

    func receiveFrame() async throws -> Data? { nil }

    func cancel() {
        lock.lock(); _cancelCount += 1; lock.unlock()
    }
}

/// Socket factory recorder: proves whether an OPENED socket was created.
private final class SocketFactoryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    let socket = FakeStreamSocket()
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }

    var factory: @Sendable (URLRequest) -> any DoubaoStreamSocket {
        { [self] _ in
            lock.lock(); _count += 1; lock.unlock()
            return socket
        }
    }
}

/// Synthetic connection config — zero credential lookup, inert values.
private let syntheticStreamConfig = DoubaoStreamConnectionConfig(
    hasCredentials: true,
    streamURL: "https://doubao.invalid/stream",
    resourceID: "test-resource",
    accessToken: "test-token",
    appID: "test-app",
    modelName: "test-model"
)

private let syntheticFileConfig = DoubaoFileConnectionConfig(
    hasCredentials: true,
    fileSubmitURL: "https://doubao.invalid/file",
    appID: "test-app",
    accessToken: "test-token",
    fileResourceID: "test-resource",
    modelName: "test-model"
)

@Suite("DoubaoConsentBoundaryTests", .serialized)
struct DoubaoConsentBoundaryTests {

    private let sampleURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("doubao-consent-\(UUID().uuidString).m4a")

    // MARK: File ASR

    @Test("File ASR: initial OFF performs zero reads and zero uploads")
    func fileDeniedEntryReachesNothing() async throws {
        let fakes = FileASRFakes()
        do {
            _ = try await DoubaoFileASRClient.transcribe(
                at: sampleURL,
                consent: ScriptedASRConsent([.failure(.aiDisabled)]),
                read: fakes.read,
                transport: fakes.transport,
                connectionConfig: syntheticFileConfig
            )
            Issue.record("transcribe must refuse when the master switch is off")
        } catch let error as AIAuthorizationError {
            #expect(error == .aiDisabled)
        }
        #expect(fakes.readCount == 0)
        #expect(fakes.transport.requests.isEmpty)
    }

    @Test("File ASR: OFF during the awaited read blocks the upload (zero HTTP)")
    func fileDeniedAfterReadReachesZeroTransport() async throws {
        let fakes = FileASRFakes()
        do {
            _ = try await DoubaoFileASRClient.transcribe(
                at: sampleURL,
                consent: ScriptedASRConsent([.success(()), .failure(.aiDisabled)]),
                read: fakes.read,
                transport: fakes.transport,
                connectionConfig: syntheticFileConfig
            )
            Issue.record("transcribe must refuse after the read when the switch turned off")
        } catch let error as AIAuthorizationError {
            #expect(error == .aiDisabled)
        }
        #expect(fakes.readCount == 1, "the read completed before the denial")
        #expect(fakes.transport.requests.isEmpty, "zero HTTP sends after denial")
    }

    @Test("File ASR: allowed path performs exactly one read and one upload")
    func fileAllowedSendsExactlyOnce() async throws {
        let fakes = FileASRFakes()
        let text = try await DoubaoFileASRClient.transcribe(
            at: sampleURL,
            consent: ScriptedASRConsent([.success(())]),
            read: fakes.read,
            transport: fakes.transport,
            connectionConfig: syntheticFileConfig
        )
        #expect(text == "你好")
        #expect(fakes.readCount == 1)
        #expect(fakes.transport.requests.count == 1)
    }

    // MARK: Stream ASR — opened fake socket

    @Test("Stream ASR: initial OFF opens zero sockets")
    func streamInitialOffOpensZeroSockets() async throws {
        let recorder = SocketFactoryRecorder()
        let client = DoubaoStreamASRClient(
            consent: ScriptedASRConsent([.failure(.aiDisabled)]),
            connectionConfig: syntheticStreamConfig,
            socketFactory: recorder.factory
        )
        do {
            try await client.start()
            Issue.record("start must refuse while the master switch is off")
        } catch let error as AIAuthorizationError {
            #expect(error == .aiDisabled)
        }
        #expect(recorder.count == 0, "no socket may be opened while OFF")
    }

    @Test("Stream ASR: opened socket sends config, then OFF refuses frames and closes once")
    func streamFramesRefuseAfterOffAndCloseOnce() async throws {
        let recorder = SocketFactoryRecorder()
        // start/config allowed, then every frame denied.
        let client = DoubaoStreamASRClient(
            consent: ScriptedASRConsent([.success(()), .success(()), .failure(.aiDisabled)]),
            connectionConfig: syntheticStreamConfig,
            socketFactory: recorder.factory
        )
        try await client.start()
        #expect(recorder.count == 1)
        #expect(recorder.socket.frames.count == 1, "the config frame reached the wire")

        // First frame after OFF is refused with the typed terminal error and
        // closes the connection exactly once.
        do {
            try await client.send(audio: Data([0x01]))
            Issue.record("audio frames must refuse after OFF")
        } catch let error as AIAuthorizationError {
            #expect(error == .aiDisabled)
        }
        #expect(recorder.socket.frames.count == 1, "no audio frame reached the wire after OFF")
        #expect(recorder.socket.cancelCount == 1, "closed exactly once on denial")

        // Terminal frame also refuses; the close is still exactly once.
        do {
            try await client.send(audio: Data(), isLast: true)
            Issue.record("the terminal frame must refuse after OFF")
        } catch {
            #expect(error is DoubaoStreamASRClient.StreamError)
        }
        #expect(recorder.socket.frames.count == 1)
        #expect(recorder.socket.cancelCount == 1, "never closed twice")
    }

    @Test("Stream ASR: sticky denial latch cannot resume after the toggle turns ON")
    func streamDeniedLatchCannotResume() async throws {
        let recorder = SocketFactoryRecorder()
        let client = DoubaoStreamASRClient(
            consent: ScriptedASRConsent([.failure(.aiDisabled)]),
            connectionConfig: syntheticStreamConfig,
            socketFactory: recorder.factory
        )
        do {
            try await client.start()
            Issue.record("start must refuse while OFF")
        } catch let error as AIAuthorizationError {
            #expect(error == .aiDisabled)
        }
        // Toggle back ON (allowing policy, same client): the latch holds.
        let resumed = DoubaoStreamASRClient(
            consent: ScriptedASRConsent([.success(())]),
            connectionConfig: syntheticStreamConfig,
            socketFactory: recorder.factory
        )
        _ = resumed  // a fresh client is inert until start()
        do {
            try await client.start()
            Issue.record("a denied stream client must never restart")
        } catch {
            #expect(error is DoubaoStreamASRClient.StreamError)
        }
        #expect(recorder.count == 0, "no socket ever opened for the denied client")
    }
}
