import SwiftUI
import Supabase
import AuthenticationServices
import CryptoKit
import Sentry

// MARK: - DPAuthError

/// Typed, user-facing auth errors. Named `DPAuthError` to avoid colliding
/// with `Supabase.AuthError`. View layer should render `errorDescription`
/// directly — no further string massaging required.
enum DPAuthError: LocalizedError, Equatable {
    case missingCredential
    case serviceUnavailable
    case invalidEmail
    /// Rate limited at the client or server layer. `retryAfter` is the
    /// number of seconds the caller must wait before another request.
    case rateLimited(retryAfter: Int)
    case otpExpired
    case otpMismatch
    /// User has exceeded the local OTP attempt budget; UI must lock the
    /// screen for `retryAfter` seconds.
    case otpLocked(retryAfter: Int)
    case networkUnavailable
    case unknown(message: String)

    var errorDescription: String? {
        switch self {
        case .missingCredential:
            return "无法读取 Apple 凭证"
        case .serviceUnavailable:
            return "登录服务未配置，请稍后再试"
        case .invalidEmail:
            return "邮箱地址无效"
        case .rateLimited(let seconds):
            return "请求过于频繁，请 \(seconds) 秒后再试"
        case .otpExpired:
            return "验证码已过期，请重新获取"
        case .otpMismatch:
            return "验证码错误，请重试"
        case .otpLocked(let seconds):
            let minutes = max(1, Int((Double(seconds) / 60.0).rounded(.up)))
            return "验证失败次数过多，请 \(minutes) 分钟后再试"
        case .networkUnavailable:
            return "网络连接异常，请检查网络"
        case .unknown(let message):
            return message.isEmpty ? "请求失败，请稍后再试" : message
        }
    }
}

// MARK: - AuthService

/// Centralized authentication service. Manages Supabase session lifecycle,
/// exposes sign-in / sign-out methods, publishes session state to views,
/// and enforces client-side rate limiting + OTP lockout.
@MainActor
final class AuthService: NSObject, ObservableObject {

    // MARK: Singleton

    static let shared = AuthService()

    // MARK: Published State

    @Published var session: Session?
    @Published var isLoading: Bool = false
    @Published var error: DPAuthError?

    // MARK: Dependencies

    let supabase: SupabaseClient
    /// True when Secrets are missing and we fell back to a non-functional placeholder client.
    let isPlaceholder: Bool

    // MARK: Private

    private var appleSignInContinuation: CheckedContinuation<ASAuthorization, Error>?
    private var authStateTask: Task<Void, Never>?

    private let defaults: UserDefaults = .standard
    private let resendCooldown: TimeInterval = 60
    private let otpFailureLimit: Int = 5
    private let otpLockDuration: TimeInterval = 30 * 60  // 30 min

    fileprivate static let appleEmailKey = "appleSignInEmail"

    // MARK: Init

    private override init() {
        guard
            let url = URL(string: Secrets.supabaseURL),
            !Secrets.supabaseURL.isEmpty,
            !Secrets.supabaseAnonKey.isEmpty
        else {
            let fallback = URL(string: "https://placeholder.supabase.co") ?? URL(fileURLWithPath: "/")
            supabase = SupabaseClient(supabaseURL: fallback, supabaseKey: "placeholder")
            isPlaceholder = true
            super.init()
            return
        }
        supabase = SupabaseClient(supabaseURL: url, supabaseKey: Secrets.supabaseAnonKey)
        isPlaceholder = false
        super.init()
        migrateAppleEmailToKeychain()
        startAuthStateListener()
    }

    /// One-shot migration: if a previous build stored `appleSignInEmail` in
    /// UserDefaults, move it into Keychain and wipe the plaintext copy.
    /// Idempotent — safe to call on every launch.
    private func migrateAppleEmailToKeychain() {
        guard let legacy = defaults.string(forKey: Self.appleEmailKey),
              !legacy.isEmpty else { return }
        if KeychainHelper.get(forKey: Self.appleEmailKey) == nil {
            KeychainHelper.set(legacy, forKey: Self.appleEmailKey)
        }
        defaults.removeObject(forKey: Self.appleEmailKey)
    }

    deinit {
        authStateTask?.cancel()
    }

    // MARK: - Auth State Listener

    private func startAuthStateListener() {
        guard !isPlaceholder else { return }
        authStateTask?.cancel()
        authStateTask = Task { [weak self] in
            guard let self else { return }
            for await (_, session) in self.supabase.auth.authStateChanges {
                if Task.isCancelled { break }
                await MainActor.run {
                    self.session = session
                    if let session {
                        let sentryUser = Sentry.User(userId: session.user.id.uuidString)
                        SentrySDK.setUser(sentryUser)
                    } else {
                        SentrySDK.setUser(nil)
                    }
                }
            }
        }
    }

    // MARK: - Apple Sign-In

    func signInWithApple() async throws {
        isLoading = true
        error = nil

        do {
            let authorization = try await requestAppleAuthorization()
            guard let appleCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let identityTokenData = appleCredential.identityToken,
                  let identityToken = String(data: identityTokenData, encoding: .utf8)
            else {
                isLoading = false
                throw DPAuthError.missingCredential
            }

            if let email = appleCredential.email {
                // Apple only returns `email` on the very first sign-in, so we
                // persist it in Keychain (not UserDefaults) to avoid PII leaks.
                KeychainHelper.set(email, forKey: Self.appleEmailKey)
            }

            session = try await supabase.auth.signInWithIdToken(
                credentials: .init(provider: .apple, idToken: identityToken)
            )
            isLoading = false
        } catch let asError as ASAuthorizationError where asError.code == .canceled {
            isLoading = false
        } catch {
            isLoading = false
            let mapped = mapSupabaseError(error)
            self.error = mapped
            throw mapped
        }
    }

    private func requestAppleAuthorization() async throws -> ASAuthorization {
        try await withCheckedThrowingContinuation { continuation in
            self.appleSignInContinuation = continuation
            let provider = ASAuthorizationAppleIDProvider()
            let request = provider.createRequest()
            request.requestedScopes = [.fullName, .email]
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    // MARK: - Email OTP

    /// Clears the client-side resend cooldown for `email` so the next
    /// `sendOTP` call is not blocked. Call only when the server has confirmed
    /// the current code is expired — not as a general bypass.
    func resetResendCooldown(email: String) {
        defaults.removeObject(forKey: resendKey(for: email))
    }

    /// Seconds remaining before the caller may request a new OTP for `email`.
    /// Returns 0 if cooldown has fully elapsed (or was never set). Used by the
    /// UI to initialize its resend countdown even across sheet dismiss/reopen.
    func resendCooldownRemaining(email: String) -> Int {
        let key = resendKey(for: email)
        let last = defaults.double(forKey: key)
        guard last > 0 else { return 0 }
        let elapsed = Date().timeIntervalSince1970 - last
        let remaining = resendCooldown - elapsed
        return remaining > 0 ? Int(remaining.rounded(.up)) : 0
    }

    /// Request a 6-digit email verification code. Supabase sends both a magic
    /// link and a one-time token; we redeem the token via `verifyOTP`.
    ///
    /// Enforces a 60-second client-side cooldown per email to avoid hitting
    /// the server rate limit.
    func sendOTP(email: String) async throws {
        guard !isPlaceholder else {
            let err = DPAuthError.serviceUnavailable
            self.error = err
            throw err
        }

        let remaining = resendCooldownRemaining(email: email)
        if remaining > 0 {
            let err = DPAuthError.rateLimited(retryAfter: remaining)
            self.error = err
            throw err
        }

        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            try await supabase.auth.signInWithOTP(email: email, shouldCreateUser: true)
            defaults.set(Date().timeIntervalSince1970, forKey: resendKey(for: email))
        } catch {
            let mapped = mapSupabaseError(error)
            self.error = mapped
            throw mapped
        }
    }

    /// Exchange the 6-digit OTP for a real session. On success the Supabase
    /// SDK emits `signedIn` via `authStateChanges`, which updates `session`.
    ///
    /// Enforces a 5-attempt → 30-min local lockout to blunt brute-force guessing.
    func verifyOTP(email: String, token: String) async throws {
        guard !isPlaceholder else {
            let err = DPAuthError.serviceUnavailable
            self.error = err
            throw err
        }

        if let lockedFor = otpLockRemaining(email: email) {
            let err = DPAuthError.otpLocked(retryAfter: lockedFor)
            self.error = err
            throw err
        }

        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            _ = try await supabase.auth.verifyOTP(email: email, token: token, type: .email)
            resetOTPFailures(email: email)
            // Clear any lingering error on success so the listener stream
            // can hand off cleanly.
            self.error = nil
        } catch {
            let mapped = mapSupabaseError(error)
            if mapped == .otpMismatch || mapped == .otpExpired {
                incrementOTPFailures(email: email)
                if let lockedFor = otpLockRemaining(email: email) {
                    let lockErr = DPAuthError.otpLocked(retryAfter: lockedFor)
                    self.error = lockErr   // lockout IS service-level; publish it
                    throw lockErr
                }
            }
            // For transient failures (mismatch / expired / network) don't
            // clobber authService.error — the view owns localError for those.
            // Only publish errors that affect cross-view state (lockout above).
            throw mapped
        }
    }

    // MARK: - Legacy Magic-Link (kept for deep-link callbacks)

    func signInWithMagicLink(email: String) async throws {
        try await sendOTP(email: email)
    }

    // MARK: - Sign-Out

    func signOut() async throws {
        isLoading = true
        error = nil
        defer { isLoading = false }
        try await supabase.auth.signOut()
        session = nil   // listener will re-confirm; local clear is immediate for UI.
        SentrySDK.setUser(nil)
    }

    // MARK: - Error Mapping

    /// Translate any underlying error (Supabase `AuthError`, `URLError`, or
    /// an already-typed `DPAuthError`) into our single domain type.
    private func mapSupabaseError(_ error: Error) -> DPAuthError {
        if let already = error as? DPAuthError { return already }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost,
                 .timedOut, .dataNotAllowed, .internationalRoamingOff:
                return .networkUnavailable
            default:
                return .unknown(message: urlError.localizedDescription)
            }
        }

        if let sbError = error as? Supabase.AuthError {
            let code = sbError.errorCode
            if code == .otpExpired { return .otpExpired }
            if code == .invalidCredentials { return .otpMismatch }
            if code == .overEmailSendRateLimit
                || code == .overRequestRateLimit
                || code == .overSMSSendRateLimit {
                let retry = parseRetryAfter(from: sbError) ?? 60
                return .rateLimited(retryAfter: retry)
            }
            if code == .validationFailed { return .invalidEmail }

            // Fallback on HTTP status code when errorCode is unhelpful.
            if case let .api(_, _, _, response) = sbError {
                if response.statusCode == 429 {
                    let retry = parseRetryAfter(from: sbError) ?? 60
                    return .rateLimited(retryAfter: retry)
                }
                if response.statusCode == 422 { return .otpMismatch }
                // 400 with "expired" in message → otpExpired; other 400 OTP
                // errors (invalid_otp_state, token mismatch, etc.) → otpMismatch
                // so we never falsely tell a user their code has expired.
                if response.statusCode == 400 {
                    let msg = sbError.message.lowercased()
                    if msg.contains("expired") { return .otpExpired }
                    if msg.contains("otp") || msg.contains("token") { return .otpMismatch }
                }
            }

            return .unknown(message: sbError.message)
        }

        return .unknown(message: error.localizedDescription)
    }

    private func parseRetryAfter(from sbError: Supabase.AuthError) -> Int? {
        guard case let .api(_, _, _, response) = sbError else { return nil }
        if let header = response.value(forHTTPHeaderField: "Retry-After"),
           let seconds = Int(header) {
            return seconds
        }
        return nil
    }

    // MARK: - Persistent Rate Limit / Lockout Storage

    /// Hash the email with SHA-256 so UserDefaults keys never contain PII.
    private func emailHash(_ email: String) -> String {
        let normalized = email.lowercased().trimmingCharacters(in: .whitespaces)
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func resendKey(for email: String) -> String {
        "auth.otp.lastSentAt.\(emailHash(email))"
    }

    private func failureCountKey(for email: String) -> String {
        "auth.otp.failureCount.\(emailHash(email))"
    }

    private func lockUntilKey(for email: String) -> String {
        "auth.otp.lockUntil.\(emailHash(email))"
    }

    /// Returns remaining lockout seconds if the email is currently locked,
    /// otherwise nil. Lazily clears stale lockouts.
    private func otpLockRemaining(email: String) -> Int? {
        let key = lockUntilKey(for: email)
        let lockUntil = defaults.double(forKey: key)
        guard lockUntil > 0 else { return nil }
        let remaining = lockUntil - Date().timeIntervalSince1970
        if remaining <= 0 {
            defaults.removeObject(forKey: key)
            defaults.removeObject(forKey: failureCountKey(for: email))
            return nil
        }
        return Int(remaining.rounded(.up))
    }

    private func incrementOTPFailures(email: String) {
        let key = failureCountKey(for: email)
        let next = defaults.integer(forKey: key) + 1
        defaults.set(next, forKey: key)
        if next >= otpFailureLimit {
            let unlockAt = Date().timeIntervalSince1970 + otpLockDuration
            defaults.set(unlockAt, forKey: lockUntilKey(for: email))
        }
    }

    private func resetOTPFailures(email: String) {
        defaults.removeObject(forKey: failureCountKey(for: email))
        defaults.removeObject(forKey: lockUntilKey(for: email))
    }
}

// MARK: - ASAuthorizationControllerDelegate

extension AuthService: ASAuthorizationControllerDelegate {

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        Task { @MainActor in
            appleSignInContinuation?.resume(returning: authorization)
            appleSignInContinuation = nil
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        Task { @MainActor in
            appleSignInContinuation?.resume(throwing: error)
            appleSignInContinuation = nil
        }
    }
}

// MARK: - ASAuthorizationControllerPresentationContextProviding

extension AuthService: ASAuthorizationControllerPresentationContextProviding {

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes
        let windowScene = scenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
        return windowScene?.windows.first(where: { $0.isKeyWindow }) ?? UIWindow()
    }
}
