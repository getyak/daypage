import Foundation
import Testing
@testable import DayPageServices

@Suite("Native auth flow")
struct NativeAuthFlowTests {
    @Test("Platform callbacks are distinct and stable")
    func platformCallbacks() throws {
        #expect(try NativeAuthFlow.callbackURL(for: .iOS).absoluteString == "daypage://auth-callback")
        #expect(try NativeAuthFlow.callbackURL(for: .macOS).absoluteString == "daypagemac://auth-callback")
    }

    @Test("Callback validation accepts only the owned authority")
    func callbackValidation() throws {
        let valid = try #require(URL(string: "daypagemac://auth-callback?code=pkce-code"))
        let validFragment = try #require(URL(string: "daypagemac://auth-callback/#access_token=token"))
        let wrongScheme = try #require(URL(string: "daypage://auth-callback?code=pkce-code"))
        let wrongHost = try #require(URL(string: "daypagemac://record?code=pkce-code"))
        let unexpectedPath = try #require(URL(string: "daypagemac://auth-callback/other?code=pkce-code"))

        #expect(NativeAuthFlow.isCallback(valid, for: .macOS))
        #expect(NativeAuthFlow.isCallback(validFragment, for: .macOS))
        #expect(!NativeAuthFlow.isCallback(wrongScheme, for: .macOS))
        #expect(!NativeAuthFlow.isCallback(wrongHost, for: .macOS))
        #expect(!NativeAuthFlow.isCallback(unexpectedPath, for: .macOS))
    }

    @Test("Nonce uses 256 bits and URL-safe Base64")
    func nonceShape() throws {
        let first = try NativeAuthFlow.randomNonce()
        let second = try NativeAuthFlow.randomNonce()
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

        #expect(first.count == 43)
        #expect(first != second)
        #expect(first.unicodeScalars.allSatisfy(allowed.contains))
    }

    @Test("Nonce hashing uses SHA-256 lowercase hex")
    func nonceHash() {
        #expect(
            NativeAuthFlow.sha256("abc")
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    @Test("Nonce rejects an empty entropy request")
    func nonceRejectsEmptyEntropy() {
        #expect(throws: NativeAuthFlow.Error.invalidByteCount) {
            try NativeAuthFlow.randomNonce(byteCount: 0)
        }
    }

    // MARK: - Email Rules

    @Test("Email normalization follows only the existing app rule")
    func emailNormalization() {
        #expect(NativeAuthFlow.normalizedEmail("  User.Name+tag@Example.COM \n") == "user.name+tag@example.com")
        #expect(NativeAuthFlow.normalizedEmail("\t a@b.co ") == "a@b.co")
        #expect(NativeAuthFlow.normalizedEmail("") == "")
        // Interior characters are never rewritten.
        #expect(NativeAuthFlow.normalizedEmail("first.last@sub.example.co.uk")
            == "first.last@sub.example.co.uk")
    }

    @Test("Email validation accepts the synthetic everyday shapes")
    func emailValidationAccepts() {
        for candidate in [
            "user@example.com",
            "user.name+tag@sub.example.co.uk",
            "  padded@example.com  ",   // accepted only after normalization
            "USER@EXAMPLE.COM",
        ] {
            #expect(NativeAuthFlow.isValidEmail(candidate), "expected valid: \(candidate)")
        }
    }

    @Test("Email validation rejects boundary and malformed shapes")
    func emailValidationRejects() {
        for candidate in [
            "",
            "   ",
            "user",
            "user@localhost",
            "user@",
            "@example.com",
            "user@@example.com",
            "user name@example.com",
            "user@exam ple.com",
            "user@example.",
            "user@example.c om",
        ] {
            #expect(!NativeAuthFlow.isValidEmail(candidate), "expected invalid: \(candidate)")
        }
    }

    @Test("Email validation boundary: existing pattern quirks are preserved")
    func emailValidationExistingPatternQuirks() {
        // The app's existing pattern accepts a leading-dot domain label. This
        // batch must not impose stricter email policy than the app already
        // had, so the quirk is pinned as behavior, not "fixed" here.
        #expect(NativeAuthFlow.isValidEmail("user@.example.com"))
    }

    // MARK: - Password Preservation

    @Test("Passwords are submitted exactly as typed")
    func passwordPreservation() {
        let raw = "  p@ss word \n"
        #expect(NativeAuthFlow.passwordSubmission(from: raw) == raw)
        let unicode = "密码🔑Ünicode"
        #expect(NativeAuthFlow.passwordSubmission(from: unicode) == unicode)
        let single = "x"
        #expect(NativeAuthFlow.passwordSubmission(from: single) == single)
    }

    @Test("Password boundary: empty is missing, whitespace-only is preserved")
    func passwordBoundary() {
        // Missing password is rejected without ever being normalized.
        #expect(NativeAuthFlow.passwordSubmission(from: "") == nil)
        // A whitespace-only value is a real password value: never trimmed away.
        #expect(NativeAuthFlow.passwordSubmission(from: " ") == " ")
        #expect(NativeAuthFlow.passwordSubmission(from: "\t\n") == "\t\n")
    }

    // MARK: - QA Session Namespace Resolver

    @Test("QA namespace resolver covers normal, unknown, nil and main QA IDs")
    func qaNamespaceResolverCoverage() {
        // Normal production identities keep the SDK default service (nil).
        #expect(NativeAuthFlow.qaSessionStorageServiceName(
            bundleIdentifier: "com.daypage.app", isDebugBuild: true) == nil)
        #expect(NativeAuthFlow.qaSessionStorageServiceName(
            bundleIdentifier: "com.daypage.mac", isDebugBuild: true) == nil)
        // Unknown non-QA identities and nil/empty identities also stay default.
        #expect(NativeAuthFlow.qaSessionStorageServiceName(
            bundleIdentifier: "org.example.other", isDebugBuild: true) == nil)
        #expect(NativeAuthFlow.qaSessionStorageServiceName(
            bundleIdentifier: nil, isDebugBuild: true) == nil)
        #expect(NativeAuthFlow.qaSessionStorageServiceName(
            bundleIdentifier: "", isDebugBuild: true) == nil)
        // Near-miss prefixes must not isolate anything.
        #expect(NativeAuthFlow.qaSessionStorageServiceName(
            bundleIdentifier: "com.daypage.app.qa", isDebugBuild: true) == nil)
        #expect(NativeAuthFlow.qaSessionStorageServiceName(
            bundleIdentifier: "com.daypage.app.qax-unit", isDebugBuild: true) == nil)
        // Unrecognized QA variants are namespaced too: they must never read or
        // delete a familiar (production or sibling QA) session.
        #expect(NativeAuthFlow.qaSessionStorageServiceName(
            bundleIdentifier: "com.daypage.app.qa-mystery", isDebugBuild: true)
            == "com.daypage.app.qa-mystery.supabase.gotrue.swift")
    }

    @Test("QA namespace resolver covers unit and numbered suffix IDs")
    func qaNamespaceResolverIDs() {
        #expect(NativeAuthFlow.qaSessionStorageServiceName(
            bundleIdentifier: "com.daypage.app.qa-unit", isDebugBuild: true)
            == "com.daypage.app.qa-unit.supabase.gotrue.swift")
        #expect(NativeAuthFlow.qaSessionStorageServiceName(
            bundleIdentifier: "com.daypage.app.qa-ui", isDebugBuild: true)
            == "com.daypage.app.qa-ui.supabase.gotrue.swift")
        let first = NativeAuthFlow.qaSessionStorageServiceName(
            bundleIdentifier: "com.daypage.app.qa-ui-928", isDebugBuild: true)
        let second = NativeAuthFlow.qaSessionStorageServiceName(
            bundleIdentifier: "com.daypage.app.qa-ui-929", isDebugBuild: true)
        #expect(first == "com.daypage.app.qa-ui-928.supabase.gotrue.swift")
        #expect(second == "com.daypage.app.qa-ui-929.supabase.gotrue.swift")
        #expect(first != second)
    }

    @Test("QA namespace resolver keeps Release builds on the default service")
    func qaNamespaceResolverRelease() {
        for identity in [
            "com.daypage.app",
            "com.daypage.app.qa-unit",
            "com.daypage.app.qa-ui-928",
            "com.daypage.app.qa-mystery",
        ] {
            #expect(NativeAuthFlow.qaSessionStorageServiceName(
                bundleIdentifier: identity, isDebugBuild: false) == nil,
                "expected default service in Release for: \(identity)")
        }
    }
}
