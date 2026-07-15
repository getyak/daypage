import Testing
import Foundation
import DayPageStorage
@testable import DayPage

/// End-to-end resolution test for the Doubao credential chain:
/// Keychain → `Secrets.resolvedDoubaoASR*` → `DoubaoASRConfig.hasCredentials`.
///
/// This is the seam the whole feature hangs off: if `hasCredentials` reports
/// false, `VoiceService` silently routes to on-device recognition and the user
/// never sees a Doubao transcript — with no error anywhere. A unit test is the
/// only place this is checkable, because the iOS Simulator cannot write to the
/// Keychain under `CODE_SIGNING_ALLOWED=NO` (`errSecMissingEntitlement`,
/// -34018), which is also why the assertions below tolerate that failure the
/// same way `KeychainHelperTests` does.
@Suite("Doubao credential resolution", .serialized)
struct DoubaoASRResolutionTests {

    private static let appIDKey = "doubaoASRAppID"
    private static let tokenKey = "doubaoASRAccessToken"

    private func clear() {
        KeychainHelper.deleteAPIKey(for: Self.appIDKey)
        KeychainHelper.deleteAPIKey(for: Self.tokenKey)
    }

    /// Both halves of the pair are required: an App ID with no Access Token
    /// cannot authenticate, and reporting `hasCredentials == true` would send
    /// every request into a guaranteed 403 instead of falling back cleanly.
    @Test("hasCredentials requires BOTH app ID and access token")
    func requiresBothHalves() throws {
        clear()
        defer { clear() }

        #expect(!DoubaoASRConfig.hasCredentials)

        KeychainHelper.setAPIKey("test-app-id", for: Self.appIDKey)
        guard KeychainHelper.getAPIKey(for: Self.appIDKey) != nil else {
            // Keychain unavailable (unsigned test run) — nothing to assert.
            return
        }
        // App ID alone must not count as configured.
        #expect(!DoubaoASRConfig.hasCredentials)

        KeychainHelper.setAPIKey("test-token", for: Self.tokenKey)
        #expect(DoubaoASRConfig.hasCredentials)
    }

    /// Values written under the `ApiKeyKind` identifiers (what Settings → API
    /// Keys persists) must be the exact values the ASR clients read back. A
    /// mismatch here is invisible until a live request 403s.
    @Test("Settings-written keys resolve back through Secrets")
    func settingsKeysResolve() throws {
        clear()
        defer { clear() }

        KeychainHelper.setAPIKey("app-id-42", for: ApiKeyKind.doubaoASRAppID.rawValue)
        KeychainHelper.setAPIKey("token-99", for: ApiKeyKind.doubaoASRAccessToken.rawValue)

        guard KeychainHelper.getAPIKey(for: ApiKeyKind.doubaoASRAppID.rawValue) != nil else {
            return  // Keychain unavailable in this run.
        }
        #expect(Secrets.resolvedDoubaoASRAppID == "app-id-42")
        #expect(Secrets.resolvedDoubaoASRAccessToken == "token-99")
        #expect(DoubaoASRConfig.appID == "app-id-42")
        #expect(DoubaoASRConfig.accessToken == "token-99")
    }

    /// The Settings rows and the purge-all-data button both iterate
    /// `ApiKeyKind.allCases`; if a Doubao case were missing, its credential
    /// would survive a "delete all local data" — a privacy defect.
    @Test("all Doubao keys are covered by ApiKeyKind")
    func apiKeyKindCoverage() {
        let raws = Set(ApiKeyKind.allCases.map(\.rawValue))
        #expect(raws.contains("doubaoASRAppID"))
        #expect(raws.contains("doubaoASRAccessToken"))
        #expect(raws.contains("doubaoASRSecretKey"))
    }
}
