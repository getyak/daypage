import Testing
import Foundation
import Sentry
import DayPageStorage
import DayPageServices
@testable import DayPage

/// Issue #928 — the REAL beforeSend construction (the same factory SentryLive
/// installs as `options.beforeSend`) must reject old/nil timestamps from
/// deferred raw-crash conversions BEFORE the unchanged field scrubber. Only
/// in-memory synthetic events are delivered: no SDK start and no disk
/// crash/cache reads. Parent-run native suite.
@MainActor
@Suite("DiagnosticsEventWiringTests", .serialized)
struct DiagnosticsEventWiringTests {

    private func makeSnapshot(
        id: UUID = UUID(),
        floor: Date = Date(timeIntervalSince1970: 100)
    ) -> DiagnosticsConsent.EpochSnapshot {
        DiagnosticsConsent.EpochSnapshot(id: id, startedAt: floor)
    }

    @Test("Pre-floor and nil timestamps are rejected by the actual beforeSend")
    func oldAndNilTimestampsAreRejected() throws {
        let snapshot = makeSnapshot()
        let beforeSend = SentryLive.makeBeforeSend(
            capturedSnapshot: snapshot,
            currentEpoch: { snapshot.id },
            isOptedIn: { true }
        )

        let old = Sentry.Event(level: .error)
        old.timestamp = Date(timeIntervalSince1970: 40)
        #expect(beforeSend(old) == nil)

        let missing = Sentry.Event(level: .error)
        missing.timestamp = nil
        #expect(beforeSend(missing) == nil)

        // No pre-floor grace window: truncated-second timestamps before the
        // floor are conservatively rejected.
        let truncated = Sentry.Event(level: .error)
        truncated.timestamp = snapshot.startedAt.addingTimeInterval(-0.3)
        #expect(beforeSend(truncated) == nil)
    }

    @Test("Current events pass and keep the existing field scrubber")
    func currentEventIsAdmittedAndScrubbed() throws {
        let snapshot = makeSnapshot()
        let beforeSend = SentryLive.makeBeforeSend(
            capturedSnapshot: snapshot,
            currentEpoch: { snapshot.id },
            isOptedIn: { true }
        )
        let event = Sentry.Event(level: .error)
        event.timestamp = snapshot.startedAt.addingTimeInterval(25)
        event.extra = ["note": "private text"]
        event.serverName = "personal-host"

        let admitted = try #require(beforeSend(event))
        #expect(admitted === event)
        #expect(admitted.message == nil)
        #expect(admitted.extra == nil, "the current field scrubber is preserved")
        #expect(admitted.serverName == nil)
        #expect(admitted.user == nil)
    }

    @Test("Epoch mismatch and revoked consent reject every timestamp")
    func epochAndConsentStillGate() {
        let snapshot = makeSnapshot()
        let foreign = Sentry.Event(level: .error)
        foreign.timestamp = snapshot.startedAt.addingTimeInterval(50)

        let wrongEpoch = SentryLive.makeBeforeSend(
            capturedSnapshot: snapshot,
            currentEpoch: { UUID() },
            isOptedIn: { true }
        )
        #expect(wrongEpoch(foreign) == nil)

        let revoked = SentryLive.makeBeforeSend(
            capturedSnapshot: snapshot,
            currentEpoch: { snapshot.id },
            isOptedIn: { false }
        )
        #expect(revoked(foreign) == nil)
    }

    @Test("Continuous-consent prior-launch crash stays eligible")
    func priorLaunchCrashAfterFloorIsEligible() {
        let snapshot = makeSnapshot()
        let beforeSend = SentryLive.makeBeforeSend(
            capturedSnapshot: snapshot,
            currentEpoch: { snapshot.id },
            isOptedIn: { true }
        )
        // The crash happened in a PREVIOUS launch (after the persistent floor,
        // long before this SDK start).
        let priorLaunch = Sentry.Event(level: .error)
        priorLaunch.timestamp = snapshot.startedAt.addingTimeInterval(5)
        #expect(beforeSend(priorLaunch) != nil)
    }
}
