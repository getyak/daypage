import XCTest
import Foundation
@testable import DayPageServices

/// Issue #928 — the master AI switch is the frozen policy: it must gate every
/// new AI request at attempt time, while preserving current defaults (master
/// ON when unset, screenshot cloud OFF when unset) and the reachable consent
/// UI. No v2 explicit-grant/version requirement is introduced.
///
/// Every test uses an explicitly isolated UserDefaults suite; ambient
/// `.standard` is never read or mutated.
final class AIRequestConsentTests: XCTestCase {
    private var suiteName: String!
    private var store: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "AIRequestConsentTests.\(UUID().uuidString)"
        store = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        store.removePersistentDomain(forName: suiteName)
    }

    // MARK: Defaults preserved

    func testMissingKeyKeepsMasterDefaultOn() {
        XCTAssertTrue(AppSettings.aiFeaturesEnabled(in: store))
        XCTAssertNoThrow(try AIRequestConsent.authorize(in: store))
    }

    func testMissingKeyKeepsScreenshotCloudDefaultOff() {
        // Even with the master switch on, screenshot cloud analysis is a
        // separate explicit opt-in that defaults to off.
        store.set(true, forKey: AppSettings.Keys.aiFeaturesEnabled)
        XCTAssertFalse(AppSettings.screenshotCloudAnalysisEnabled(in: store))
    }

    // MARK: Master switch enforcement

    func testMasterOffBlocksAuthorization() {
        store.set(false, forKey: AppSettings.Keys.aiFeaturesEnabled)
        XCTAssertFalse(AppSettings.aiFeaturesEnabled(in: store))
        XCTAssertThrowsError(try AIRequestConsent.authorize(in: store)) { error in
            XCTAssertEqual(error as? AIAuthorizationError, .aiDisabled)
        }
        XCTAssertFalse(AIRequestConsent.isAuthorized(in: store))
    }

    func testMasterOnAllowsAuthorization() {
        store.set(true, forKey: AppSettings.Keys.aiFeaturesEnabled)
        XCTAssertNoThrow(try AIRequestConsent.authorize(in: store))
        XCTAssertTrue(AIRequestConsent.isAuthorized(in: store))
    }

    func testLiveToggleTakesEffectOnTheVeryNextAttempt() {
        store.set(true, forKey: AppSettings.Keys.aiFeaturesEnabled)
        XCTAssertNoThrow(try AIRequestConsent.authorize(in: store))
        store.set(false, forKey: AppSettings.Keys.aiFeaturesEnabled)
        XCTAssertThrowsError(try AIRequestConsent.authorize(in: store))
    }

    // MARK: Screenshot cloud policy

    func testScreenshotCloudRequiresBothSwitches() {
        store.set(true, forKey: AppSettings.Keys.aiFeaturesEnabled)
        store.set(true, forKey: AppSettings.Keys.screenshotCloudAnalysisEnabled)
        XCTAssertTrue(AppSettings.screenshotCloudAnalysisEnabled(in: store))
        XCTAssertNoThrow(try AIRequestConsent.authorizeScreenshotCloud(in: store))

        store.set(false, forKey: AppSettings.Keys.aiFeaturesEnabled)
        XCTAssertFalse(AppSettings.screenshotCloudAnalysisEnabled(in: store))
        XCTAssertThrowsError(try AIRequestConsent.authorizeScreenshotCloud(in: store)) { error in
            XCTAssertEqual(error as? AIAuthorizationError, .aiDisabled)
        }
    }

    func testScreenshotKeyWithoutMasterIsNotConsent() {
        store.set(false, forKey: AppSettings.Keys.aiFeaturesEnabled)
        store.set(true, forKey: AppSettings.Keys.screenshotCloudAnalysisEnabled)
        XCTAssertFalse(AppSettings.screenshotCloudAnalysisEnabled(in: store))
        XCTAssertThrowsError(try AIRequestConsent.authorizeScreenshotCloud(in: store))
    }

    func testScreenshotKeyOffIsTerminalEvenWithMasterOn() {
        store.set(true, forKey: AppSettings.Keys.aiFeaturesEnabled)
        XCTAssertThrowsError(try AIRequestConsent.authorizeScreenshotCloud(in: store)) { error in
            XCTAssertEqual(error as? AIAuthorizationError, .screenshotCloudDisabled)
        }
    }

    // MARK: Injectable policies

    func testAllowAllPolicyNeverRefuses() {
        XCTAssertNoThrow(try AllowAllAIConsent().authorize())
    }

    func testScriptedPolicyControlsEachAttemptIndependently() throws {
        let policy = ScriptedAIConsent([.success(()), .failure(.aiDisabled)])
        XCTAssertNoThrow(try policy.authorize())
        XCTAssertThrowsError(try policy.authorize()) { error in
            XCTAssertEqual(error as? AIAuthorizationError, .aiDisabled)
        }
    }
}

/// Scripted authorization fake: each `authorize()` pops the next verdict.
/// The last verdict repeats once the queue is exhausted.
final class ScriptedAIConsent: AIConsentChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var verdicts: [Result<Void, AIAuthorizationError>]
    private var _calls = 0

    init(_ verdicts: [Result<Void, AIAuthorizationError>]) {
        self.verdicts = verdicts
    }

    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }

    func authorize() throws {
        lock.lock()
        _calls += 1
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
