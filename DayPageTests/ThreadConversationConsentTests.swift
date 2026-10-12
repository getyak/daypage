import Testing
import Foundation
import DayPageModels
import DayPageStorage
import DayPageServices
@testable import DayPage

/// Issue #928 — the Daily thread conversation must route through the guarded
/// client seam: an OFF master switch surfaces the typed terminal denial with
/// zero provider traffic, while allowed replies keep the existing prompt,
/// streaming, and vault persistence behavior. Parent-run native suite.
@MainActor
@Suite("ThreadConversationConsentTests", .serialized)
struct ThreadConversationConsentTests {

    private let tempDir: URL

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadConsent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    @Test("OFF switch: zero provider calls, typed denial surfaced, no assistant message")
    func deniedReplyProducesNoAssistantMessage() async throws {
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let recorder = ThreadStreamRecorder(verdict: .failure(.aiDisabled))
        let vm = ThreadConversationViewModel(
            question: "今天怎么样？",
            compiledPageText: "今天在西湖边走了很久。",
            date: Date(),
            streamReplyHandler: recorder.handler,
            vaultRoot: tempDir
        )

        await vm.send(userMessage: "能再说说吗？")

        #expect(recorder.callCount == 1, "the guarded boundary refuses at request time")
        #expect(vm.messages.filter { $0.role == "assistant" }.isEmpty)
        #expect(vm.error != nil, "the typed denial is surfaced, not swallowed")
    }

    @Test("Allowed reply streams through the seam and persists once")
    func allowedReplyPersistsExactlyOnce() async throws {
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let recorder = ThreadStreamRecorder(verdict: .success("听起来很放松。"))
        let vm = ThreadConversationViewModel(
            question: "今天怎么样？",
            compiledPageText: "今天在西湖边走了很久。",
            date: Date(),
            streamReplyHandler: recorder.handler,
            vaultRoot: tempDir
        )

        await vm.send(userMessage: "能再说说吗？")

        let assistant = vm.messages.filter { $0.role == "assistant" }
        #expect(assistant.count == 1)
        #expect(assistant.first?.text == "听起来很放松。")

        // The system prompt carries the compiled page context (behavior kept).
        let first = try #require(recorder.firstMessage)
        #expect(first.role == .system)
        #expect(first.content.contains("今天在西湖边走了很久。"))

        // Exactly one durable threads block for this question.
        let threadsFile = tempDir
            .appendingPathComponent("threads")
            .appendingPathComponent("\(DateFormatters.isoDate.string(from: Date())).md")
        let content = try String(contentsOf: threadsFile, encoding: .utf8)
        #expect(content.components(separatedBy: "question: 今天怎么样？").count == 2)
    }
}

/// Recording stream seam: one scripted verdict per conversation.
private final class ThreadStreamRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let verdict: Result<String, AIAuthorizationError>
    private var _callCount = 0
    private var _firstMessage: LLMMessage?

    init(verdict: Result<String, AIAuthorizationError>) {
        self.verdict = verdict
    }

    var callCount: Int { lock.lock(); defer { lock.unlock() }; return _callCount }
    var firstMessage: LLMMessage? { lock.lock(); defer { lock.unlock() }; return _firstMessage }

    var handler: ThreadConversationViewModel.ThreadStreamReply {
        { [self] messages, onDelta in
            lock.lock()
            _callCount += 1
            if _firstMessage == nil { _firstMessage = messages.first }
            lock.unlock()
            switch verdict {
            case .failure(let error):
                throw error
            case .success(let text):
                for character in text {
                    await onDelta(String(character))
                }
                return text
            }
        }
    }
}

// MARK: - Actual guarded-client route

/// Recording transport counting every LLM request the default route builds.
private final class RecordingLLMTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.lock(); _count += 1; lock.unlock()
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://llm.invalid")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data("{}".utf8), response)
    }
}

/// Terminal URLProtocol standing in for the SSE endpoint at the VM's actual
/// streaming boundary. Serves a canned event stream — no network.
private final class ThreadCannedSSEProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var starts = 0
    static var startCount: Int { lock.lock(); defer { lock.unlock() }; return starts }
    static func reset() { lock.lock(); starts = 0; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock(); Self.starts += 1; Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://llm.invalid")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"guarded\"}}]}\n\ndata: [DONE]\n\n"
        client?.urlProtocol(self, didLoad: Data(sse.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
@Suite("ThreadGuardedClientRouteTests", .serialized)
struct ThreadGuardedClientRouteTests {

    private let tempDir: URL

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadGuarded-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    private func makeClient(
        transport: HTTPTransport,
        consent: AIConsentChecking,
        session: URLSession = .shared
    ) -> LLMClient {
        LLMClient(
            config: .init(
                baseURL: "https://llm.invalid/v1",
                apiKey: "sk-test-only",
                model: "test-model",
                maxTokens: 16,
                temperature: 0,
                timeout: 5
            ),
            spanName: "thread.test",
            transport: transport,
            consent: consent,
            streamSession: session
        )
    }

    @Test("Default route through the guarded client: OFF means zero LLM requests")
    func defaultRouteIsGuarded() async throws {
        defer { try? FileManager.default.removeItem(at: tempDir) }
        ThreadCannedSSEProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ThreadCannedSSEProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let transport = RecordingLLMTransport()
        let vm = ThreadConversationViewModel(
            question: "今天怎么样？",
            compiledPageText: "今天在西湖边走了很久。",
            date: Date(),
            vaultRoot: tempDir
        )
        vm.llmClientOverride = makeClient(
            transport: transport,
            consent: ScriptedThreadConsent([.failure(.aiDisabled)]),
            session: session
        )

        await vm.send(userMessage: "能再说说吗？")

        #expect(transport.count == 0, "the guarded client refuses before any request")
        #expect(ThreadCannedSSEProtocol.startCount == 0)
        #expect(vm.messages.filter { $0.role == "assistant" }.isEmpty)
        #expect(vm.error == AIAuthorizationError.aiDisabled.localizedDescription)
    }

    @Test("Allowed default route streams through the guarded client and persists")
    func allowedDefaultRouteStreams() async throws {
        defer { try? FileManager.default.removeItem(at: tempDir) }
        ThreadCannedSSEProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ThreadCannedSSEProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let transport = RecordingLLMTransport()
        let vm = ThreadConversationViewModel(
            question: "今天怎么样？",
            compiledPageText: "今天在西湖边走了很久。",
            date: Date(),
            vaultRoot: tempDir
        )
        vm.llmClientOverride = makeClient(
            transport: transport,
            consent: AllowAllAIConsent(),
            session: session
        )

        await vm.send(userMessage: "能再说说吗？")

        let assistant = vm.messages.filter { $0.role == "assistant" }
        #expect(assistant.count == 1)
        #expect(assistant.first?.text == "guarded")
        #expect(ThreadCannedSSEProtocol.startCount == 1)
        #expect(transport.count == 0, "SSE traffic flows through the injected session, not the transport")
    }
}

/// Scripted policy for the guarded-route suites.
private final class ScriptedThreadConsent: AIConsentChecking, @unchecked Sendable {
    private let verdict: Result<Void, AIAuthorizationError>
    init(_ verdicts: [Result<Void, AIAuthorizationError>]) {
        self.verdict = verdicts.first ?? .success(())
    }
    func authorize() throws { try verdict.get() }
}
