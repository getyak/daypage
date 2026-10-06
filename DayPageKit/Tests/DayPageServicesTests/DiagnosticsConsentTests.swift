import Foundation
import Testing
import DayPageStorage
@testable import DayPageServices

// MARK: - Test spies

/// Records consent-change notifications without any app/Sentry dependency.
private final class ConsentChangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Bool] = []

    var values: [Bool] {
        lock.lock(); defer { lock.unlock() }
        return _values
    }

    func record(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        _values.append(value)
    }
}

/// Counts everything forwarded across the `SentryAdapter` boundary.
private final class SpySentryAdapter: DayPageStorage.SentryAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var _breadcrumbs = 0
    private var _errors = 0
    private var _operationalEvents = 0
    private var _transactions = 0

    var isEnabled: Bool { true }

    var breadcrumbs: Int { lock.lock(); defer { lock.unlock() }; return _breadcrumbs }
    var errors: Int { lock.lock(); defer { lock.unlock() }; return _errors }
    var operationalEvents: Int { lock.lock(); defer { lock.unlock() }; return _operationalEvents }
    var transactions: Int { lock.lock(); defer { lock.unlock() }; return _transactions }

    func breadcrumb(category: String, level: SentryLevel, message: String) {
        lock.lock(); _breadcrumbs += 1; lock.unlock()
    }

    func captureError(_ error: Error) {
        lock.lock(); _errors += 1; lock.unlock()
    }

    func captureOperationalEvent(_ event: OperationalEvent) {
        lock.lock(); _operationalEvents += 1; lock.unlock()
    }

    func startTransaction(name: String, operation: String) -> SentrySpan? {
        lock.lock(); _transactions += 1; lock.unlock()
        return SpySentrySpan()
    }
}

private final class SpySentrySpan: SentrySpan, @unchecked Sendable {
    func setTag(_ value: String, key: String) {}
    func finish() {}
}

private struct SpyError: Error {}

/// Counts gate consultations (a @Sendable closure may not mutate a captured var).
private final class GateCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    func increment() { lock.lock(); _count += 1; lock.unlock() }
}

/// Wraps the thread-safe `UserDefaults` for capture in @Sendable gate closures.
private final class ConsentStoreBox: @unchecked Sendable {
    let store: UserDefaults
    init(_ store: UserDefaults) { self.store = store }
}

// MARK: - Suite

/// Issue #922 — crash diagnostics must be a persisted, default-OFF opt-in, and
/// revoking consent must block every future event at the transport boundary.
@Suite("Crash diagnostics consent (issue #922)", .serialized)
struct DiagnosticsConsentTests {

    private func makeStore() throws -> (store: UserDefaults, suite: String) {
        let suite = "DiagnosticsConsentTests.\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: suite))
        store.removePersistentDomain(forName: suite)
        return (store, suite)
    }

    // MARK: Default & persistence

    @Test("Consent defaults to false when the key is unset (fail closed)")
    func defaultsToOptedOut() throws {
        let (store, suite) = try makeStore()
        defer { store.removePersistentDomain(forName: suite) }
        #expect(store.object(forKey: DiagnosticsConsent.defaultsKey) == nil)
        #expect(!DiagnosticsConsent.isOptedIn(in: store))
        #expect(!DiagnosticsConsent.isOptedIn)
    }

    @Test("Opt-in persists and survives a re-read through a fresh store handle")
    func optInPersists() throws {
        let (store, suite) = try makeStore()
        defer { store.removePersistentDomain(forName: suite) }
        DiagnosticsConsent.setOptedIn(true, in: store)
        #expect(DiagnosticsConsent.isOptedIn(in: store))

        let reloaded = try #require(UserDefaults(suiteName: suite))
        #expect(DiagnosticsConsent.isOptedIn(in: reloaded))
    }

    @Test("A corrupted non-boolean value can never opt the user in")
    func corruptedValueFailsClosed() throws {
        let (store, suite) = try makeStore()
        defer { store.removePersistentDomain(forName: suite) }
        store.set("yes", forKey: DiagnosticsConsent.defaultsKey)
        #expect(!DiagnosticsConsent.isOptedIn(in: store))
        store.set(1, forKey: DiagnosticsConsent.defaultsKey)
        #expect(!DiagnosticsConsent.isOptedIn(in: store))
    }

    // MARK: Consent lifecycle notifications

    @Test("Opt-in and revocation fire the change handler with the new value")
    func changeHandlerFiresOnBothEdges() throws {
        let (store, suite) = try makeStore()
        defer { store.removePersistentDomain(forName: suite) }
        let recorder = ConsentChangeRecorder()
        DiagnosticsConsent.changeHandler = { recorder.record($0) }
        defer { DiagnosticsConsent.changeHandler = nil }

        DiagnosticsConsent.setOptedIn(true, in: store)
        #expect(recorder.values == [true])
        DiagnosticsConsent.setOptedIn(false, in: store)
        #expect(recorder.values == [true, false])
        #expect(!DiagnosticsConsent.isOptedIn(in: store))
    }

    // MARK: Transport guard (SentryReporter event gate)

    @MainActor
    @Test("Events flow only while consent is on; revocation blocks every future event")
    func revocationBlocksFutureEventsAtTransportBoundary() throws {
        let (store, suite) = try makeStore()
        defer { store.removePersistentDomain(forName: suite) }
        let spy = SpySentryAdapter()
        SentryReporter.adapter = spy
        let storeBox = ConsentStoreBox(store)
        SentryReporter.setEventsGate { DiagnosticsConsent.isOptedIn(in: storeBox.store) }
        defer {
            SentryReporter.adapter = NoopSentryAdapter()
            SentryReporter.setEventsGate(nil)
        }

        let event = OperationalEvent(
            area: "sync",
            stage: "push",
            code: "server_error",
            correlationID: UUID()
        )

        func recordEverything() {
            SentryReporter.breadcrumb(category: "private-note", level: .info, message: "private transcript unmatched-secret")
            SentryReporter.captureError(NSError(domain: "private-account", code: 7,
                userInfo: [NSLocalizedDescriptionKey: "private note and credential", "transcript": "private recording"]))
            SentryReporter.captureOperationalEvent(event)
            _ = SentryReporter.startTransaction(name: "test", operation: "op")
        }

        // Default state: consent unset → nothing may leave the device.
        recordEverything()
        #expect(spy.breadcrumbs == 0)
        #expect(spy.errors == 0)
        #expect(spy.operationalEvents == 0)
        #expect(spy.transactions == 0)
        #expect(!SentryReporter.isSentryEnabled)

        // Opted in → events flow.
        DiagnosticsConsent.setOptedIn(true, in: store)
        recordEverything()
        #expect(spy.breadcrumbs == 0)
        #expect(spy.errors == 0)
        #expect(spy.operationalEvents == 1)
        #expect(spy.transactions == 0)
        #expect(SentryReporter.isSentryEnabled)

        // Revoked → the gate is re-evaluated per event and refuses everything,
        // even though the adapter itself is still enabled.
        DiagnosticsConsent.setOptedIn(false, in: store)
        recordEverything()
        #expect(spy.breadcrumbs == 0)
        #expect(spy.errors == 0)
        #expect(spy.operationalEvents == 1)
        #expect(spy.transactions == 0)
        #expect(!SentryReporter.isSentryEnabled)
    }

    @MainActor
    @Test("The consent gate is consulted live, not latched at registration")
    func gateIsEvaluatedPerEvent() throws {
        let (store, suite) = try makeStore()
        defer { store.removePersistentDomain(forName: suite) }
        let spy = SpySentryAdapter()
        SentryReporter.adapter = spy
        let gateCalls = GateCallCounter()
        let storeBox = ConsentStoreBox(store)
        SentryReporter.setEventsGate {
            gateCalls.increment()
            return DiagnosticsConsent.isOptedIn(in: storeBox.store)
        }
        defer {
            SentryReporter.adapter = NoopSentryAdapter()
            SentryReporter.setEventsGate(nil)
        }

        DiagnosticsConsent.setOptedIn(true, in: store)
        SentryReporter.captureOperationalEvent(OperationalEvent(area: "sync", stage: "push", code: "unexpected", correlationID: UUID()))
        DiagnosticsConsent.setOptedIn(false, in: store)
        SentryReporter.captureOperationalEvent(OperationalEvent(area: "sync", stage: "push", code: "unexpected", correlationID: UUID()))

        #expect(spy.operationalEvents == 1)
        #expect(gateCalls.count >= 2)
    }

    @Test("Revocation changes the persisted cache epoch; repeated opt-in preserves it")
    func epochsAreBoundToConsent() throws {
        let (store, suite) = try makeStore()
        defer { store.removePersistentDomain(forName: suite) }
        #expect(DiagnosticsConsent.prepareEpoch(in: store) == nil)
        DiagnosticsConsent.setOptedIn(true, in: store)
        let first = try #require(DiagnosticsConsent.epoch(in: store))
        DiagnosticsConsent.setOptedIn(true, in: store)
        #expect(DiagnosticsConsent.epoch(in: store) == first)
        DiagnosticsConsent.setOptedIn(false, in: store)
        #expect(DiagnosticsConsent.epoch(in: store) == nil)
        DiagnosticsConsent.setOptedIn(true, in: store)
        #expect(DiagnosticsConsent.epoch(in: store) != first)
    }

    @Test("Concurrent mutation notifications observe the persisted transition")
    func transitionsAreSerialized() throws {
        let (store, suite) = try makeStore()
        defer { store.removePersistentDomain(forName: suite) }
        let storeBox = ConsentStoreBox(store)
        let mismatches = GateCallCounter()
        DiagnosticsConsent.changeHandler = { value in
            if DiagnosticsConsent.isOptedIn(in: storeBox.store) != value { mismatches.increment() }
        }
        defer { DiagnosticsConsent.changeHandler = nil }
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            DiagnosticsConsent.setOptedIn(index.isMultiple(of: 2), in: storeBox.store)
        }
        #expect(mismatches.count == 0)
    }

    @Test("Session and final-forward permits cannot overlap persisted revocation")
    func permitsSerializeWithRevocation() throws {
        let (store, suite) = try makeStore()
        defer { store.removePersistentDomain(forName: suite); DiagnosticsConsent.changeHandler = nil }
        let box = ConsentStoreBox(store)
        for startup in [true, false] {
            DiagnosticsConsent.changeHandler = nil
            DiagnosticsConsent.setOptedIn(true, in: store)
            let recorder = ConsentChangeRecorder()
            DiagnosticsConsent.changeHandler = { recorder.record($0) }
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let permitFinished = DispatchSemaphore(value: 0)
            let mutationAttempted = DispatchSemaphore(value: 0)
            let mutationFinished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                let operation = {
                    recorder.record(true)
                    entered.signal()
                    _ = release.wait(timeout: .now() + 2)
                    // Consent is still true throughout registration/resume.
                    recorder.record(DiagnosticsConsent.isOptedIn(in: box.store))
                }
                if startup { DiagnosticsConsent.withCurrentEpoch(in: box.store) { _ in operation() } }
                else { DiagnosticsConsent.withSerializedTransition(operation) }
                permitFinished.signal()
            }
            #expect(entered.wait(timeout: .now() + 2) == .success)
            DispatchQueue.global().async {
                mutationAttempted.signal()
                DiagnosticsConsent.setOptedIn(false, in: box.store)
                mutationFinished.signal()
            }
            #expect(mutationAttempted.wait(timeout: .now() + 2) == .success)
            #expect(mutationFinished.wait(timeout: .now() + 0.02) == .timedOut)
            release.signal()
            #expect(permitFinished.wait(timeout: .now() + 2) == .success)
            #expect(mutationFinished.wait(timeout: .now() + 2) == .success)
            #expect(recorder.values == [true, true, false])
            #expect(!DiagnosticsConsent.isOptedIn(in: store))
            let calls = GateCallCounter()
            DiagnosticsConsent.withCurrentEpoch(in: store) { _ in calls.increment() }
            #expect(calls.count == 0)
        }
    }
}
