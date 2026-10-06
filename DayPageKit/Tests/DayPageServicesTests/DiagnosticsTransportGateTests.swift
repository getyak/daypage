import Foundation
import Testing
@testable import DayPageServices

/// Each URLProtocol instance resolves a retained recorder for its unique host.
/// A late callback can never be counted in the next test's fixture.
private final class DiagnosticForwardingFixture: @unchecked Sendable {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: DiagnosticForwardingFixture] = [:]
    let endpoint: URL
    let hold: Bool
    private let condition = NSCondition()
    private var registered: Set<UUID> = []
    private var completed: Set<UUID> = []
    private var received: [UUID: URLRequest] = [:]
    private var started: Set<UUID> = []
    private var stopped: Set<UUID> = []
    private var finished: Set<UUID> = []
    private var responseNotifications: Set<UUID> = []
    private var controlledStop: (@Sendable () -> Void)?
    private var activeCallbacks = 0
    private var admissionsClosed = false
    private var finalized = false
    private var problems: [String] = []
    private var delayStart: Bool
    private var startReleased: Bool

    init(hold: Bool = false, delayStart: Bool = false) throws {
        let host = "fixture-\(UUID().uuidString.lowercased()).diagnostics.invalid"
        endpoint = try #require(URL(string: "https://\(host)/api/1/envelope/"))
        self.hold = hold
        self.delayStart = delayStart
        startReleased = !delayStart
        Self.registryLock.lock(); Self.registry[host] = self; Self.registryLock.unlock()
    }
    static func recorder(for request: URLRequest) -> DiagnosticForwardingFixture? {
        registryLock.lock(); defer { registryLock.unlock() }
        return request.url?.host.flatMap { registry[$0] }
    }
    static var priorProblems: [String] {
        registryLock.lock(); let fixtures = Array(registry.values); registryLock.unlock()
        return fixtures.flatMap { $0.failures }
    }
    func observe(_ event: DiagnosticsTransportGate.ForwardingTaskEvent) {
        condition.lock(); defer { condition.broadcast(); condition.unlock() }
        switch event {
        case .registered(let id):
            if admissionsClosed || !registered.insert(id).inserted { problems.append("Invalid task registration") }
        case .completed(let id):
            if !registered.contains(id) || !completed.insert(id).inserted { problems.append("Unpaired task completion") }
        }
    }
    func closeAdmissions() {
        condition.lock(); admissionsClosed = true; condition.unlock()
    }
    var taskIDs: Set<UUID> { condition.lock(); defer { condition.unlock() }; return registered }
    var completedIDs: Set<UUID> { condition.lock(); defer { condition.unlock() }; return completed }
    var requests: [URLRequest] { condition.lock(); defer { condition.unlock() }; return Array(received.values) }
    var successfulResponseCount: Int { condition.lock(); defer { condition.unlock() }; return responseNotifications.count }
    var cancellationCount: Int { condition.lock(); defer { condition.unlock() }; return stopped.count }
    var failures: [String] { condition.lock(); defer { condition.unlock() }; return problems }
    func beginStart(_ id: UUID, stop: @escaping @Sendable () -> Void) {
        condition.lock(); defer { condition.broadcast(); condition.unlock() }
        activeCallbacks += 1
        controlledStop = stop
        if finalized { problems.append("Late start after terminal barrier") }
        if !started.insert(id).inserted { problems.append("Duplicate protocol start") }
    }
    func stopEnteredStart() -> Bool {
        condition.lock(); let action = controlledStop; condition.unlock()
        guard let action else { return false }
        action(); return true
    }
    func willSendSuccessfulResponse(_ id: UUID) {
        condition.lock(); responseNotifications.insert(id); condition.unlock()
    }
    func awaitStartRelease() {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(3)
        while !startReleased {
            if !condition.wait(until: deadline) { problems.append("Controlled start release timed out"); return }
        }
    }
    func releaseStart() {
        condition.lock(); startReleased = true; condition.broadcast(); condition.unlock()
    }
    func record(_ request: URLRequest, id: UUID) {
        condition.lock(); defer { condition.broadcast(); condition.unlock() }
        received[id] = request
    }
    func endStart(_ id: UUID, finished: Bool) {
        condition.lock(); defer { condition.broadcast(); condition.unlock() }
        if finished { self.finished.insert(id) }
        activeCallbacks -= 1
    }
    func stop(_ id: UUID) {
        condition.lock(); defer { condition.broadcast(); condition.unlock() }
        if finalized { problems.append("Late stop after terminal barrier") }
        stopped.insert(id)
    }
    private func wait(_ predicate: @escaping @Sendable (DiagnosticForwardingFixture) -> Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                self.condition.lock()
                let deadline = Date().addingTimeInterval(3)
                while !predicate(self) {
                    if !self.condition.wait(until: deadline) { break }
                }
                let ready = predicate(self)
                self.condition.unlock()
                continuation.resume(returning: ready)
            }
        }
    }
    func waitForRequest() async -> Bool { await wait { !$0.received.isEmpty } }
    func waitForEnteredStart() async -> Bool { await wait { !$0.started.isEmpty } }
    func waitForTerminal() async -> Bool {
        await wait { $0.registered == $0.completed && $0.activeCallbacks == 0 && $0.started.isSubset(of: $0.stopped.union($0.finished)) }
    }
    func finalize() {
        condition.lock(); defer { condition.unlock() }
        if registered != completed || activeCallbacks != 0 || !started.isSubset(of: stopped.union(finished)) {
            problems.append("Finalization without paired task/protocol terminals")
        }
        finalized = true
    }
}

private final class DiagnosticForwardingStub: URLProtocol, @unchecked Sendable {
    private let invocationID = UUID()
    private let lifecycleLock = NSRecursiveLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = DiagnosticForwardingFixture.recorder(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let id = invocationID
        fixture.beginStart(id, stop: { [weak self] in self?.stopLoading() })
        var finished = false
        defer { fixture.endStart(id, finished: finished) }
        fixture.awaitStartRelease()
        var received = request
        received.httpBody = DiagnosticsTransportGate.body(of: request)
        fixture.record(received, id: id)
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        guard !stopped, !fixture.hold, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:]) else { return }
        fixture.willSendSuccessfulResponse(id)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        guard !stopped else { return }
        client?.urlProtocolDidFinishLoading(self)
        finished = true
    }
    override func stopLoading() {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        stopped = true
        // The host never changes; retain the same recorder even if stop arrives
        // before this instance's startLoading body has progressed.
        DiagnosticForwardingFixture.recorder(for: request)?.stop(invocationID)
    }
}

private final class ChangedConsentSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private let store: UserDefaults
    private var first = true
    init(store: UserDefaults) { self.store = store }
    func allowed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let value = DiagnosticsConsent.isOptedIn(in: store)
        if first { first = false; store.set(false, forKey: DiagnosticsConsent.defaultsKey) }
        return value
    }
}

@Suite("Diagnostics final URLSession consent gate", .serialized)
struct DiagnosticsTransportGateTests {
    private func withFixture(hold: Bool = false, delayStart: Bool = false,
                             _ body: (DiagnosticForwardingFixture, DiagnosticsTransportGate) async throws -> Void) async throws {
        #expect(DiagnosticForwardingFixture.priorProblems.isEmpty)
        let fixture = try DiagnosticForwardingFixture(hold: hold, delayStart: delayStart)
        let gate = DiagnosticsTransportGate(innerConfiguration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [DiagnosticForwardingStub.self]
            return configuration
        }, taskObserver: { fixture.observe($0) })
        do {
            try await body(fixture, gate)
        } catch {
            gate.revoke(); fixture.closeAdmissions(); fixture.releaseStart()
            #expect(await fixture.waitForTerminal())
            fixture.finalize(); #expect(fixture.failures.isEmpty)
            throw error
        }
        gate.revoke(); fixture.closeAdmissions(); fixture.releaseStart()
        #expect(await fixture.waitForTerminal())
        fixture.finalize(); #expect(fixture.failures.isEmpty)
        #expect(fixture.taskIDs == fixture.completedIDs)
        #expect(DiagnosticForwardingFixture.priorProblems.isEmpty)
    }
    private func request(_ fixture: DiagnosticForwardingFixture, gzip: Bool = false, level: String = "error") throws -> URLRequest {
        var request = URLRequest(url: fixture.endpoint)
        request.httpMethod = "POST"
        let body = try diagnosticEnvelope(["level": level, "message": ["formatted": "PRIVATE_NOTE_TRANSCRIPT_SECRET"], "user": ["id": "PRIVATE_ACCOUNT"]])
        request.httpBody = gzip ? try diagnosticGzip(body) : body
        if gzip { request.setValue("gzip", forHTTPHeaderField: "Content-Encoding") }
        request.setValue("Bearer PRIVATE_AUTH", forHTTPHeaderField: "Authorization")
        request.setValue("PRIVATE_HEADER", forHTTPHeaderField: "X-Custom")
        return request
    }
    private func send(_ request: URLRequest, on session: URLSession) async -> Bool {
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }
    private func eventLevel(_ request: URLRequest) throws -> String {
        let lines = (request.httpBody ?? Data()).split(separator: 10, omittingEmptySubsequences: false)
        try #require(lines.count == 4)
        let event = try #require(try JSONSerialization.jsonObject(with: Data(lines[2])) as? [String: Any])
        return try #require(event["level"] as? String)
    }

    @Test("Actual forwarding sanitizes plain and SDK gzip envelopes and headers")
    func actualSessionForwarding() async throws {
        try await withFixture { (fixture: DiagnosticForwardingFixture, gate: DiagnosticsTransportGate) async throws -> Void in
            let session = gate.makeSession(endpoint: fixture.endpoint, authHeader: "Sentry sentry_key=test-config", consent: { true })
            defer { session.invalidateAndCancel() }
            #expect(await send(try request(fixture), on: session))
            #expect(await send(try request(fixture, gzip: true), on: session))
            #expect(fixture.requests.count == 2)
            #expect(fixture.successfulResponseCount == 2)
            for request in fixture.requests {
                let safe = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                #expect(!safe.contains("PRIVATE")); #expect(safe.contains("DayPage diagnostics"))
                for header in ["Authorization", "X-Custom", "Content-Encoding", "X-DayPage-Diagnostics-Generation"] {
                    #expect(request.value(forHTTPHeaderField: header) == nil)
                }
                #expect(request.value(forHTTPHeaderField: "X-Sentry-Auth") == "Sentry sentry_key=test-config")
            }
        }
    }
    @Test("An initial true snapshot cannot resume after live consent becomes false")
    func finalConsentReadRefusesStaleSnapshot() async throws {
        try await withFixture { (fixture: DiagnosticForwardingFixture, gate: DiagnosticsTransportGate) async throws -> Void in
            let suite = "FinalDiagnosticsConsent.\(UUID().uuidString)"
            let store = try #require(UserDefaults(suiteName: suite))
            defer { store.removePersistentDomain(forName: suite) }
            store.set(true, forKey: DiagnosticsConsent.defaultsKey)
            let snapshot = ChangedConsentSnapshot(store: store)
            let session = gate.makeSession(endpoint: fixture.endpoint, authHeader: "configured", consent: { snapshot.allowed() })
            defer { session.invalidateAndCancel() }
            #expect(!(await send(try request(fixture, gzip: true), on: session)))
            #expect(!DiagnosticsConsent.isOptedIn(in: store)); #expect(fixture.requests.isEmpty)
        }
    }
    @Test("Revocation blocks queue and SDK close flush; re-opt-in rejects old generation")
    func flushAndOldEpochCannotSend() async throws {
        try await withFixture { (fixture: DiagnosticForwardingFixture, gate: DiagnosticsTransportGate) async throws -> Void in
            let old = gate.makeSession(endpoint: fixture.endpoint, authHeader: "configured", consent: { true })
            defer { old.invalidateAndCancel() }
            #expect(await send(try request(fixture), on: old))
            gate.revoke()
            #expect(!(await send(try request(fixture), on: old)))
            #expect(!(await send(try request(fixture, gzip: true), on: old)))
            #expect(fixture.requests.count == 1)
            let fresh = gate.makeSession(endpoint: fixture.endpoint, authHeader: "configured", consent: { true })
            defer { fresh.invalidateAndCancel() }
            #expect(!(await send(try request(fixture), on: old)))
            #expect(await send(try request(fixture), on: fresh)); #expect(fixture.requests.count == 2)
        }
    }
    @Test("Revocation cancels already resumed inner URLSession task")
    func cancelsInflight() async throws {
        try await withFixture(hold: true) { (fixture: DiagnosticForwardingFixture, gate: DiagnosticsTransportGate) async throws -> Void in
            let session = gate.makeSession(endpoint: fixture.endpoint, authHeader: "configured", consent: { true })
            defer { session.invalidateAndCancel() }
            let prepared = try request(fixture)
            let pending = Task { await send(prepared, on: session) }
            #expect(await fixture.waitForRequest()); gate.revoke(); fixture.closeAdmissions()
            #expect(!(await pending.value)); #expect(await fixture.waitForTerminal())
            #expect(fixture.cancellationCount == 1)
            #expect(!(await send(prepared, on: session))); #expect(fixture.requests.count == 1)
        }
    }
    @Test("Live consent, wrong endpoint and malformed envelope fail without forwarding")
    func invalidRequestsFailClosed() async throws {
        try await withFixture { (fixture: DiagnosticForwardingFixture, gate: DiagnosticsTransportGate) async throws -> Void in
            let refused = gate.makeSession(endpoint: fixture.endpoint, authHeader: "configured", consent: { false })
            #expect(!(await send(try request(fixture), on: refused))); refused.invalidateAndCancel()
            let allowed = gate.makeSession(endpoint: fixture.endpoint, authHeader: "configured", consent: { true })
            defer { allowed.invalidateAndCancel() }
            var query = try request(fixture)
            var components = URLComponents(url: fixture.endpoint, resolvingAgainstBaseURL: false)
            components?.query = "private-secret"; query.url = components?.url
            #expect(!(await send(query, on: allowed)))
            var bad = try request(fixture); bad.httpBody = Data("malformed PRIVATE".utf8)
            #expect(!(await send(bad, on: allowed)))
            var oversized = try request(fixture); oversized.httpBody = nil
            oversized.httpBodyStream = InputStream(data: Data(repeating: 120, count: DiagnosticsEnvelopeSanitizer.maximumBytes + 1))
            #expect(!(await send(oversized, on: allowed))); #expect(fixture.requests.isEmpty)
        }
    }
    @Test("Concurrent forwarding and revoke cancel every registered request")
    func concurrentForwardingCutoff() async throws {
        try await withFixture(hold: true) { (fixture: DiagnosticForwardingFixture, gate: DiagnosticsTransportGate) async throws -> Void in
            let session = gate.makeSession(endpoint: fixture.endpoint, authHeader: "configured", consent: { true })
            defer { session.invalidateAndCancel() }
            let prepared = try request(fixture, gzip: true)
            let pending = Task {
                await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
                    for _ in 0..<32 { group.addTask { await send(prepared, on: session) } }
                    var results: [Bool] = []
                    for await result in group { results.append(result) }
                    return results
                }
            }
            #expect(await fixture.waitForRequest()); gate.revoke(); fixture.closeAdmissions()
            let admitted = fixture.taskIDs
            let results = await pending.value
            #expect(results.count == 32); #expect(results.allSatisfy { !$0 })
            #expect(await fixture.waitForTerminal()); #expect(fixture.completedIDs == admitted)
            let frozenCount = fixture.requests.count
            #expect(frozenCount > 0); #expect(fixture.cancellationCount == frozenCount)
            let afterCutoff = try request(fixture, gzip: true, level: "warning")
            for _ in 0..<10 { #expect(!(await send(afterCutoff, on: session))) }
            #expect(fixture.taskIDs == admitted); #expect(fixture.requests.count == frozenCount)
            for received in fixture.requests { #expect(try eventLevel(received) == "error") }
        }
    }
    @Test("A held inner start after revoke joins its original fixture before completion")
    func controlledLateStartDrainsOriginalFixture() async throws {
        try await withFixture(hold: true, delayStart: true) { (fixture: DiagnosticForwardingFixture, gate: DiagnosticsTransportGate) async throws -> Void in
            let session = gate.makeSession(endpoint: fixture.endpoint, authHeader: "configured", consent: { true })
            defer { session.invalidateAndCancel() }
            let prepared = try request(fixture)
            let pending = Task { await send(prepared, on: session) }
            #expect(await fixture.waitForEnteredStart()); #expect(fixture.requests.isEmpty)
            gate.revoke(); fixture.closeAdmissions()
            let admitted = fixture.taskIDs; #expect(admitted.count == 1)
            fixture.releaseStart()
            #expect(!(await pending.value)); #expect(await fixture.waitForTerminal())
            #expect(fixture.taskIDs == admitted); #expect(fixture.completedIDs == admitted)
            #expect(fixture.requests.count == 1); #expect(fixture.cancellationCount == 1)
            #expect(try eventLevel(try #require(fixture.requests.first)) == "error")
            #expect(!(await send(try request(fixture, level: "warning"), on: session)))
            #expect(fixture.requests.count == 1)
        }
    }
    @Test("A stopped delayed inner protocol never reports a successful response")
    func stoppedDelayedProtocolDoesNotNotifySuccess() async throws {
        try await withFixture(delayStart: true) { (fixture: DiagnosticForwardingFixture, gate: DiagnosticsTransportGate) async throws -> Void in
            let session = gate.makeSession(endpoint: fixture.endpoint, authHeader: "configured", consent: { true })
            defer { session.invalidateAndCancel() }
            let prepared = try request(fixture)
            let pending = Task { await send(prepared, on: session) }
            #expect(await fixture.waitForEnteredStart())
            #expect(fixture.stopEnteredStart())
            gate.revoke(); fixture.closeAdmissions(); fixture.releaseStart()
            #expect(!(await pending.value)); #expect(await fixture.waitForTerminal())
            #expect(fixture.taskIDs.count == 1); #expect(fixture.completedIDs == fixture.taskIDs)
            #expect(fixture.requests.count == 1); #expect(fixture.cancellationCount == 1)
            #expect(fixture.successfulResponseCount == 0)
        }
    }
    @Test("Concurrent start and revocation leave all old sessions blocked")
    func concurrentSessions() async throws {
        try await withFixture { (fixture: DiagnosticForwardingFixture, gate: DiagnosticsTransportGate) async throws -> Void in
            let sessions = await withTaskGroup(of: URLSession.self, returning: [URLSession].self) { group in
                for _ in 0..<32 {
                    group.addTask {
                        let session = gate.makeSession(endpoint: fixture.endpoint, authHeader: "configured", consent: { true })
                        gate.revoke(); return session
                    }
                }
                var sessions: [URLSession] = []
                for await session in group { sessions.append(session) }
                return sessions
            }
            gate.revoke()
            for session in sessions {
                #expect(!(await send(try request(fixture), on: session))); session.invalidateAndCancel()
            }
            #expect(fixture.requests.isEmpty)
        }
    }
}
