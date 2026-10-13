import XCTest
import Foundation
@testable import DayPageServices

/// Issue #928 — the deferred raw-crash admission gap: a raw crash captured
/// under an earlier consent epoch can be converted and admitted into a NEW
/// epoch's Hub after revoke→regrant. The pure admission helper requires live
/// consent, matching epochs, a non-nil finite timestamp, and the timestamp at
/// or after the persistent epoch-start floor. No SDK start, no disk crash or
/// cache reads — synthetic timestamps only.
final class DiagnosticsEventGateTests: XCTestCase {

    private let floor = Date(timeIntervalSince1970: 30.3)
    private let epoch = UUID()

    private func snapshot(startedAt: Date? = nil, id: UUID? = nil) -> DiagnosticsConsent.EpochSnapshot {
        DiagnosticsConsent.EpochSnapshot(id: id ?? epoch, startedAt: startedAt ?? floor)
    }

    func testCurrentTimestampIsAdmitted() {
        XCTAssertTrue(DiagnosticsEventGate.admit(
            timestamp: Date(timeIntervalSince1970: 35),
            snapshot: snapshot(),
            currentEpoch: epoch,
            isOptedIn: true
        ))
    }

    func testExactFloorIsAdmitted() {
        XCTAssertTrue(DiagnosticsEventGate.admit(
            timestamp: floor,
            snapshot: snapshot(),
            currentEpoch: epoch,
            isOptedIn: true
        ))
    }

    func testPreFloorTimestampIsRejectedWithoutGraceWindow() {
        // The SDK truncates crash times to whole seconds: floor 30.3 means a
        // timestamp of 30 is BEFORE the floor and must be conservatively
        // rejected — no pre-floor grace window.
        XCTAssertFalse(DiagnosticsEventGate.admit(
            timestamp: Date(timeIntervalSince1970: 30),
            snapshot: snapshot(),
            currentEpoch: epoch,
            isOptedIn: true
        ))
    }

    func testOldEpochCrashIsRejectedAfterRegrant() {
        // The confirmed interleaving: crash time tC belongs to the revoked
        // epoch; after revoke→regrant the sink converts it in the NEW epoch.
        XCTAssertFalse(DiagnosticsEventGate.admit(
            timestamp: Date(timeIntervalSince1970: 15),
            snapshot: snapshot(startedAt: Date(timeIntervalSince1970: 40)),
            currentEpoch: UUID(),
            isOptedIn: true
        ))
    }

    func testNilTimestampIsRejected() {
        XCTAssertFalse(DiagnosticsEventGate.admit(
            timestamp: nil,
            snapshot: snapshot(),
            currentEpoch: epoch,
            isOptedIn: true
        ))
    }

    func testNilSnapshotIsRejected() {
        XCTAssertFalse(DiagnosticsEventGate.admit(
            timestamp: Date(timeIntervalSince1970: 35),
            snapshot: nil,
            currentEpoch: epoch,
            isOptedIn: true
        ))
    }

    func testEpochMismatchIsRejected() {
        XCTAssertFalse(DiagnosticsEventGate.admit(
            timestamp: Date(timeIntervalSince1970: 35),
            snapshot: snapshot(),
            currentEpoch: UUID(),
            isOptedIn: true
        ))
    }

    func testConsentOffIsRejectedRegardlessOfTimestamp() {
        XCTAssertFalse(DiagnosticsEventGate.admit(
            timestamp: Date(timeIntervalSince1970: 35),
            snapshot: snapshot(),
            currentEpoch: epoch,
            isOptedIn: false
        ))
    }

    func testNonFiniteTimestampIsRejected() {
        XCTAssertFalse(DiagnosticsEventGate.admit(
            timestamp: Date(timeIntervalSince1970: .nan),
            snapshot: snapshot(),
            currentEpoch: epoch,
            isOptedIn: true
        ))
    }

    func testContinuousConsentPriorLaunchCrashStaysEligible() {
        // Continuous consent, same epoch: a crash from a PREVIOUS launch but
        // after the persistent floor must remain eligible — the floor is the
        // epoch creation time, never the SDK start time.
        let launchTime = Date(timeIntervalSince1970: 90)
        XCTAssertTrue(DiagnosticsEventGate.admit(
            timestamp: Date(timeIntervalSince1970: 20).addingTimeInterval(20), // t = 40 ≥ floor 30.3
            snapshot: snapshot(),
            currentEpoch: epoch,
            isOptedIn: true
        ))
        XCTAssertFalse(launchTime < floor, "sanity: the launch is after the floor")
    }
}
