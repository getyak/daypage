import SwiftUI
import Supabase
import AuthenticationServices
import CryptoKit
import Sentry
import Network

// MARK: - DPAuthError

/// Typed, user-facing auth errors. Named `DPAuthError` to avoid collision with
/// `Supabase.AuthError`. Views render `errorDescription` directly — no extra
/// string processing required.
enum DPAuthError: LocalizedError, Equatable {
    case missingCredential
    case serviceUnavailable
    case invalidEmail
    /// Client- or server-side rate limit hit. `retryAfter` is the seconds the
    /// caller must wait before making another request.
    case rateLimited(retryAfter: Int)
    case otpExpired
    case otpMismatch
    /// User exceeded the local OTP-attempt budget; UI must lock the screen for
    /// `retryAfter` seconds.
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

/// Centralised auth service. Manages Supabase session lifecycle, exposes
/// sign-in / sign-out methods, and publishes session state to views.
/// Rate-limiting and lockout persistence are delegated to `AuthRateLimiter`.
@MainActor
final class AuthService: NSObject, ObservableObject {

    // MARK: Singleton

    static let shared = AuthService()

    // MARK: Published State

    @Published var session: Session?
    @Published var isLoading: Bool = false
    @Published var error: DPAuthError?
    /// `true` while the network path is unavailable (NWPathMonitor).
    @Published private(set) var isNetworkUnavailable: Bool = false

    // MARK: Derived — Login Provider

    enum LoginProvider {
        case apple
        case emailOTP
        case unknown
    }

    var loginProvider: LoginProvider {
        guard let email = session?.user.email else { return .unknown }
        if let appleEmail = KeychainHelper.get(forKey: Self.appleEmailKey),
           appleEmail == email {
            return .apple
        }
        return .emailOTP
    }

    // MARK: Dependencies

    let supabase: SupabaseClient
    /// `true` when Secrets are missing and we fell back to a non-functional placeholder client.
    let isPlaceholder: Bool

    // MARK: Private

    private var appleSignInContinuation: CheckedContinuation<ASAuthorization, Error>?
    private var authStateTask: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "com.daypage.auth.pathmonitor", qos: .utility)

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
        migrateRateLimiterToKeychain()
        startAuthStateListener()
        startNetworkMonitor()
    }

    /// One-time migration: move `appleSignInEmail` from UserDefaults to Keychain.
    /// Idempotent — safe to call on every launch.
    private func migrateAppleEmailToKeychain() {
        let defaults = UserDefaults.standard
        guard let legacy = defaults.string(forKey: Self.appleEmailKey),
              !legacy.isEmpty else { return }
        if KeychainHelper.get(forKey: Self.appleEmailKey) == nil {
            KeychainHelper.set(legacy, forKey: Self.appleEmailKey)
        }
        defaults.removeObject(forKey: Self.appleEmailKey)
    }

    /// One-time migration: move UserDefaults-based rate-limiter keys to Keychain.
    /// Keys are hashed so we cannot enumerate all emails — we migrate the two
    /// well-known un-hashed legacy keys and the generic prefix pattern we can find.
    private func migrateRateLimiterToKeychain() {
        let defaults = UserDefaults.standard
        let prefixes = ["auth.otp.lastSentAt.", "auth.otp.failureCount.", "auth.otp.lockUntil."]
        for (key, value) in defaults.dictionaryRepresentation() {
            guard prefixes.contains(where: { key.hasPrefix($0) }) else { continue }
            if let str = value as? String {
                if KeychainHelper.get(forKey: key) == nil {
                    KeychainHelper.set(str, forKey: key)
                }
            } else if let dbl = value as? Double {
                if KeychainHelper.get(forKey: key) == nil {
                    KeychainHelper.set(String(dbl), forKey: key)
                }
            }
            defaults.removeObject(forKey: key)
        }
    }

    deinit {
        authStateTask?.cancel()
        pathMonitor.cancel()
    }

    // MARK: - Network Monitor

    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let unavailable = path.status == .unsatisfied
            Task { @MainActor [weak self] in
                self?.isNetworkUnavailable = unavailable
                if unavailable {
                    DayPageLogger.log(level: "WARN", message: "[AuthService] Network path unsatisfied")
                }
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    // MARK: - Auth State Listener

    private func startAuthStateListener() {
        guard !isPlaceholder else { return }
        authStateTask?.cancel()
        authStateTask = Task { [weak self] in
            guard let self else { return }
            for await (event, session) in self.supabase.auth.authStateChanges {
                if Task.isCancelled { break }
                await MainActor.run {
                    self.session = session
                    if let session {
                        // User authenticated — clear the "skip" flag so the sync
                        // banner doesn't persist from pre-login state (GH #251).
                        UserDefaults.standard.set(false, forKey: AppSettings.Keys.authSkipped)
                        let sentryUser = Sentry.User(userId: session.user.id.uuidString)
                        SentrySDK.setUser(sentryUser)
                        DayPageLogger.shared.info("[AuthService] Auth event: \(String(describing: event)), session expires: \(session.expiresAt)")
                    } else {
                        SentrySDK.setUser(nil)
                        DayPageLogger.shared.info("[AuthService] Auth event: \(String(describing: event)), session cleared")
                    }
                }
            }
        }
    }

    // MARK: - Apple Sign-In

    func signInWithApple() async throws {
        guard !isNetworkUnavailable else {
            let err = DPAuthError.networkUnavailable
            self.error = err
            throw err
        }
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
                // Apple only returns `email` on first sign-in, so persist it to
                // Keychain (not UserDefaults) to avoid PII leakage.
                KeychainHelper.set(email, forKey: Self.appleEmailKey)
            }

            // Do NOT assign to self.session here. The authStateChanges listener
            // is the single source of truth for session state; assigning directly
            // would create a second write path that races with the listener's
            // nil→session→nil flash during Supabase's internal state transition (RC1).
            // Clear isLoading before the listener's session update triggers SwiftUI
            // diffing so the ProgressView overlay is already gone when onChange fires (RC3).
            isLoading = false
            _ = try await supabase.auth.signInWithIdToken(
                credentials: .init(provider: .apple, idToken: identityToken)
            )
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

    /// Clears the resend cooldown for `email` so the next `sendOTP` call is not
    /// blocked. Only call when the server confirms the current code has expired.
    func resetResendCooldown(email: String) {
        AuthRateLimiter.shared.resetResendCooldown(email: email)
    }

    /// Seconds the caller must wait before requesting a new OTP for `email`.
    /// Returns 0 when fully expired (or never set). Used by UI to seed its
    /// resend countdown even after the form is closed and reopened.
    func resendCooldownRemaining(email: String) -> Int {
        AuthRateLimiter.shared.resendCooldownRemaining(email: email)
    }

    /// Requests a 6-digit email OTP. Enforces a 60-second client-side cooldown
    /// per email to avoid triggering server rate limits.
    func sendOTP(email: String) async throws {
        guard !isPlaceholder else {
            let err = DPAuthError.serviceUnavailable
            self.error = err
            throw err
        }
        guard !isNetworkUnavailable else {
            let err = DPAuthError.networkUnavailable
            self.error = err
            throw err
        }

        let remaining = AuthRateLimiter.shared.resendCooldownRemaining(email: email)
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
            AuthRateLimiter.shared.recordOTPSent(email: email)
            DayPageLogger.shared.info("[AuthService] OTP sent successfully")
        } catch {
            let mapped = mapSupabaseError(error)
            self.error = mapped
            throw mapped
        }
    }

    /// Redeems a 6-digit OTP for a real session. On success the Supabase SDK
    /// emits `signedIn` via `authStateChanges`, which updates `session`.
    /// Enforces 5-attempt → 30-minute local lockout to deter brute-force.
    func verifyOTP(email: String, token: String) async throws {
        guard !isPlaceholder else {
            let err = DPAuthError.serviceUnavailable
            self.error = err
            throw err
        }
        guard !isNetworkUnavailable else {
            let err = DPAuthError.networkUnavailable
            self.error = err
            throw err
        }

        if let lockedFor = AuthRateLimiter.shared.otpLockRemaining(email: email) {
            let err = DPAuthError.otpLocked(retryAfter: lockedFor)
            self.error = err
            throw err
        }

        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            _ = try await supabase.auth.verifyOTP(email: email, token: token, type: .email)
            AuthRateLimiter.shared.resetOTPFailures(email: email)
            self.error = nil
            DayPageLogger.shared.info("[AuthService] OTP verified successfully")
        } catch {
            let mapped = mapSupabaseError(error)
            if mapped == .otpMismatch || mapped == .otpExpired {
                AuthRateLimiter.shared.incrementOTPFailures(email: email)
                if let lockedFor = AuthRateLimiter.shared.otpLockRemaining(email: email) {
                    let lockErr = DPAuthError.otpLocked(retryAfter: lockedFor)
                    self.error = lockErr   // lockout is service-level; publish it
                    throw lockErr
                }
            }
            // Transient failures (mismatch / expired / network) are owned by the
            // view — don't overwrite cross-view service error state.
            throw mapped
        }
    }

    // MARK: - Sign-Out

    func signOut() async throws {
        isLoading = true
        error = nil
        defer { isLoading = false }
        try await supabase.auth.signOut()
        session = nil   // listener will confirm; local clear takes effect immediately in UI
        SentrySDK.setUser(nil)
        DayPageLogger.shared.info("[AuthService] User signed out")
    }

    // MARK: - Error Mapping

    /// Converts any underlying error (Supabase `AuthError`, `URLError`, or an
    /// already-typed `DPAuthError`) into our single domain type.
    private func mapSupabaseError(_ error: Error) -> DPAuthError {
        if let already = error as? DPAuthError { return already }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost,
                 .timedOut, .dataNotAllowed, .internationalRoamingOff:
                return .networkUnavailable
            default:
                return .unknown(message: "请求失败，请稍后再试")
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

            // Fall back to HTTP status codes when errorCode isn't informative.
            if case let .api(_, _, _, response) = sbError {
                if response.statusCode == 429 {
                    let retry = parseRetryAfter(from: sbError) ?? 60
                    return .rateLimited(retryAfter: retry)
                }
                if response.statusCode == 422 { return .otpMismatch }
                if response.statusCode == 400 {
                    let msg = sbError.message.lowercased()
                    if msg.contains("expired") { return .otpExpired }
                    if msg.contains("otp") || msg.contains("token") { return .otpMismatch }
                }
            }

            // Log the raw server message privately but never surface it to the user.
            DayPageLogger.shared.error("[AuthService] Unmapped auth error (private)")
            return .unknown(message: "请求失败，请稍后再试")
        }

        DayPageLogger.shared.error("[AuthService] Unknown error type (private)")
        return .unknown(message: "请求失败，请稍后再试")
    }

    private func parseRetryAfter(from sbError: Supabase.AuthError) -> Int? {
        guard case let .api(_, _, _, response) = sbError else { return nil }
        if let header = response.value(forHTTPHeaderField: "Retry-After"),
           let seconds = Int(header) {
            return seconds
        }
        return nil
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
        guard let windowScene = scenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
            ?? scenes.compactMap({ $0 as? UIWindowScene }).first
        else {
            return UIWindow()
        }
        return windowScene.windows.first(where: { $0.isKeyWindow })
            ?? windowScene.windows.first
            ?? UIWindow(windowScene: windowScene)
    }
}
