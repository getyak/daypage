import XCTest
import Foundation
import DayPageStorage
@testable import DayPageServices

// MARK: - Fakes

/// Recording `DerivedArtifactRemote`: counts authoring requests and read
/// fetches. No network, no account, no credentials.
private actor FakeDerivedArtifactRemote: DerivedArtifactRemote {
    private(set) var dailyRequests = 0
    private(set) var weeklyRequests = 0
    private(set) var fetches = 0

    func fetchCanonicalArtifacts(limit: Int) async throws -> [RemoteDerivedArtifact] {
        fetches += 1
        return []
    }

    @discardableResult
    func requestDaily(localDate: String, timezone: String, finalize: Bool, explicitRetry: Bool) async throws -> UUID {
        dailyRequests += 1
        return UUID()
    }

    @discardableResult
    func requestWeekly(weekStart: String, timezone: String, explicitRetry: Bool) async throws -> UUID {
        weeklyRequests += 1
        return UUID()
    }

    var counts: (daily: Int, weekly: Int, fetches: Int) {
        (dailyRequests, weeklyRequests, fetches)
    }
}

/// Recording flush seam: counts flushes and optionally runs a hook (used to
/// flip consent mid-flush). The flush itself never touches a real queue.
private final class FlushRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var hook: (@Sendable () -> Void)?

    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }

    func flush() async {
        lock.lock()
        _count += 1
        let hook = self.hook
        lock.unlock()
        hook?()
    }
}

// MARK: - Suite

/// Issue #928 — backend-first daily/weekly authoring is a NEW AI request: it
/// must check the master switch before the sync flush and again after the
/// awaited flush, before the remote request. OFF means zero flush, zero
/// request, zero scheduled refresh. Legitimate read-only derived refresh and
/// independent account sync stay ungated.
@MainActor
final class BackendIntelligenceConsentTests: XCTestCase {
    private var vault: URL!
    private var previousOverride: URL?

    override func setUpWithError() throws {
        vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("daypage-backend-consent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        previousOverride = VaultInitializer.testOverrideURL
        VaultInitializer.testOverrideURL = vault
    }

    override func tearDownWithError() throws {
        VaultInitializer.testOverrideURL = previousOverride
        if let vault { try? FileManager.default.removeItem(at: vault) }
    }

    private func makeService(
        consent: AIConsentChecking,
        flush: FlushRecorder
    ) -> BackendIntelligenceService {
        BackendIntelligenceService(
            consent: consent,
            syncFlush: { await flush.flush() }
        )
    }

    func testDailyOffCausesZeroFlushZeroRequestZeroSchedule() async throws {
        let flush = FlushRecorder()
        let remote = FakeDerivedArtifactRemote()
        let service = makeService(consent: ScriptedAIConsent([.failure(.aiDisabled)]), flush: flush)
        await service.configure(remote: remote, accountID: UUID())

        do {
            _ = try await service.requestDaily(localDate: "2026-10-13", timezone: "UTC", force: true)
            XCTFail("requestDaily must throw while the master switch is off")
        } catch let error as AIAuthorizationError {
            XCTAssertEqual(error, .aiDisabled)
        }

        XCTAssertEqual(flush.count, 0, "OFF must cause zero flush")
        let counts = await remote.counts
        XCTAssertEqual(counts.daily, 0, "OFF must cause zero remote request")
        let scheduled = await service.isRefreshScheduled
        XCTAssertFalse(scheduled, "OFF must cause zero scheduled refresh")
    }

    func testWeeklyOffCausesZeroFlushZeroRequestZeroSchedule() async throws {
        let flush = FlushRecorder()
        let remote = FakeDerivedArtifactRemote()
        let service = makeService(consent: ScriptedAIConsent([.failure(.aiDisabled)]), flush: flush)
        await service.configure(remote: remote, accountID: UUID())

        do {
            _ = try await service.requestWeekly(weekStart: "2026-10-12", timezone: "UTC", force: false)
            XCTFail("requestWeekly must throw while the master switch is off")
        } catch let error as AIAuthorizationError {
            XCTAssertEqual(error, .aiDisabled)
        }

        XCTAssertEqual(flush.count, 0)
        let counts = await remote.counts
        XCTAssertEqual(counts.weekly, 0)
        let scheduled = await service.isRefreshScheduled
        XCTAssertFalse(scheduled)
    }

    func testOffTransitionDuringFlushCausesZeroRequest() async throws {
        // First check passes; the flush awaits; the user turns the switch off
        // while the flush runs; the second check must refuse BEFORE the remote.
        let flush = FlushRecorder()
        let remote = FakeDerivedArtifactRemote()
        let consent = ScriptedAIConsent([.success(()), .failure(.aiDisabled)])
        let service = makeService(consent: consent, flush: flush)
        await service.configure(remote: remote, accountID: UUID())

        do {
            _ = try await service.requestDaily(localDate: "2026-10-13", timezone: "UTC", force: true)
            XCTFail("requestDaily must surface the mid-flush revocation")
        } catch let error as AIAuthorizationError {
            XCTAssertEqual(error, .aiDisabled)
        }

        XCTAssertEqual(flush.count, 1, "the pre-flush check passed, so exactly one flush ran")
        let counts = await remote.counts
        XCTAssertEqual(counts.daily, 0, "no remote request after the awaited flush when OFF")
        let scheduled = await service.isRefreshScheduled
        XCTAssertFalse(scheduled)
        XCTAssertEqual(consent.calls, 2, "pre-flush + post-flush checks")
    }

    func testAllowedDailyFlushesOnceAndRequestsOnce() async throws {
        let flush = FlushRecorder()
        let remote = FakeDerivedArtifactRemote()
        let service = makeService(consent: AllowAllAIConsent(), flush: flush)
        await service.configure(remote: remote, accountID: UUID())

        _ = try await service.requestDaily(localDate: "2026-10-13", timezone: "UTC", force: true)

        XCTAssertEqual(flush.count, 1)
        let counts = await remote.counts
        XCTAssertEqual(counts.daily, 1)
        let scheduled = await service.isRefreshScheduled
        XCTAssertTrue(scheduled)
    }

    func testAllowedWeeklyFlushesOnceAndRequestsOnce() async throws {
        let flush = FlushRecorder()
        let remote = FakeDerivedArtifactRemote()
        let service = makeService(consent: AllowAllAIConsent(), flush: flush)
        await service.configure(remote: remote, accountID: UUID())

        _ = try await service.requestWeekly(weekStart: "2026-10-12", timezone: "UTC", force: false)

        XCTAssertEqual(flush.count, 1)
        let counts = await remote.counts
        XCTAssertEqual(counts.weekly, 1)
        let scheduled = await service.isRefreshScheduled
        XCTAssertTrue(scheduled)
    }

    func testReadOnlyDerivedRefreshStaysAvailableWhileMasterOff() async throws {
        // The read-only derived projection is not a new AI request: refresh()
        // must keep working with a denying policy and must not flush the sync
        // queue as a side effect.
        let flush = FlushRecorder()
        let remote = FakeDerivedArtifactRemote()
        let service = makeService(consent: ScriptedAIConsent([.failure(.aiDisabled)]), flush: flush)
        await service.configure(remote: remote, accountID: UUID())

        try await service.refresh()

        let counts = await remote.counts
        XCTAssertEqual(counts.fetches, 1, "read-only derived refresh stays legitimate")
        XCTAssertEqual(flush.count, 0, "refresh must not trigger an authoring flush")
    }
}
