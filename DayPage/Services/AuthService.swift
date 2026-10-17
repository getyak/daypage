import SwiftUI
import Supabase
import AuthenticationServices
import CryptoKit
import Sentry
import Network
import DayPageStorage
import DayPageServices

// MARK: - DPAuthError

/// Typed, user-facing auth errors. Named `DPAuthError` to avoid collision with
/// `Supabase.AuthError`. Views render `errorDescription` directly — no extra
/// string processing required.
enum DPAuthError: LocalizedError, Equatable {
    case missingCredential
    case missingPassword
    case invalidCredentials
    case emailConfirmationRequired
    case requestInFlight
    case serviceUnavailable
    case invalidEmail
    /// Client- or server-side rate limit hit. `retryAfter` is the seconds the
    /// caller must wait before making another request.
    case rateLimited(retryAfter: Int)
    case linkExpired
    case networkUnavailable
    case unknown(message: String)

    var errorDescription: String? {
        switch self {
        case .missingCredential:
            return "无法读取 Apple 凭证"
        case .missingPassword:
            return "请输入密码"
        case .invalidCredentials:
            return "邮箱或密码不正确"
        case .emailConfirmationRequired:
            return "请先打开邮箱中的验证邮件，完成验证后再登录"
        case .requestInFlight:
            return "登录请求正在进行中，请稍候"
        case .serviceUnavailable:
            return "登录服务未配置，请稍后再试"
        case .invalidEmail:
            return "邮箱地址无效"
        case .rateLimited(let seconds):
            return "请求过于频繁，请 \(seconds) 秒后再试"
        case .linkExpired:
            return "登录链接已过期或已使用，请重新发送"
        case .networkUnavailable:
            return "网络连接异常，请检查网络"
        case .unknown(let message):
            return message.isEmpty ? "请求失败，请稍后再试" : message
        }
    }

    var diagnosticCode: String {
        switch self {
        case .missingCredential: return "missing_credential"
        case .missingPassword: return "missing_password"
        case .invalidCredentials: return "invalid_credentials"
        case .emailConfirmationRequired: return "email_confirmation_required"
        case .requestInFlight: return "request_in_flight"
        case .serviceUnavailable: return "service_unavailable"
        case .invalidEmail: return "invalid_email"
        case .rateLimited: return "rate_limited"
        case .linkExpired: return "link_expired"
        case .networkUnavailable: return "network_unavailable"
        case .unknown: return "unknown"
        }
    }
}

/// The last content-free authentication failure retained for user support.
/// Email, tokens, Apple credentials, and provider response text are excluded.
struct AuthFailureDiagnostic: Codable, Equatable {
    let occurredAt: Date
    let provider: String
    let stage: String
    let code: String
    let httpStatus: Int?
    let networkState: String
    let correlationID: String
}

private enum AuthFailureDiagnosticStore {
    private static let key = "auth.lastFailureDiagnostic.v1"

    static func load() -> AuthFailureDiagnostic? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(AuthFailureDiagnostic.self, from: data)
    }

    static func save(_ diagnostic: AuthFailureDiagnostic) {
        guard let data = try? JSONEncoder().encode(diagnostic) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

// MARK: - AuthService

/// Centralised auth service. Manages Supabase session lifecycle, exposes
/// sign-in / sign-out methods, and publishes session state to views.
/// Email-link resend throttling is delegated to `AuthRateLimiter`.
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
    @Published private(set) var lastFailureDiagnostic = AuthFailureDiagnosticStore.load()

    // MARK: Derived — Login Provider

    enum LoginProvider {
        case apple
        case emailLink
        case unknown
    }

    var loginProvider: LoginProvider {
        guard let email = session?.user.email else { return .unknown }
        if let appleEmail = KeychainHelper.get(forKey: Self.appleEmailKey),
           appleEmail == email {
            return .apple
        }
        return .emailLink
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
        // Auth storage options are resolved BEFORE the SDK initializes so a
        // DEBUG QA bundle's session namespace is fixed before any session
        // read/write, for the real client and the placeholder alike (GH #884).
        let clientOptions = Self.makeClientOptions()
        guard
            let url = URL(string: Secrets.supabaseURL),
            !Secrets.supabaseURL.isEmpty,
            !Secrets.supabasePublishableKey.isEmpty
        else {
            let fallback = URL(string: "https://placeholder.supabase.co") ?? URL(fileURLWithPath: "/")
            supabase = SupabaseClient(supabaseURL: fallback, supabaseKey: "placeholder", options: clientOptions)
            isPlaceholder = true
            super.init()
            return
        }
        supabase = SupabaseClient(
            supabaseURL: url,
            supabaseKey: Secrets.supabasePublishableKey,
            options: clientOptions
        )
        isPlaceholder = false
        super.init()
        migrateAppleEmailToKeychain()
        migrateRateLimiterToKeychain()
        startAuthStateListener()
        startNetworkMonitor()
    }

    /// Pure decision made before `SupabaseClient` initializes. DEBUG iOS QA
    /// bundles (`com.daypage.app.qa-*`) namespace the auth Keychain service so
    /// concurrent QA apps never read or delete each other's or production's
    /// session; production and Release builds keep the SDK default options
    /// (service `supabase.gotrue.swift`). No session migration, enumeration or
    /// deletion happens here, and no Keychain call is made in tests.
    private static func makeClientOptions() -> SupabaseClientOptions {
        #if DEBUG
        let isDebugBuild = true
        #else
        let isDebugBuild = false
        #endif
        guard let qaService = NativeAuthFlow.qaSessionStorageServiceName(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            isDebugBuild: isDebugBuild
        ) else {
            return SupabaseClientOptions()
        }
        return SupabaseClientOptions(
            auth: .init(storage: KeychainLocalStorage(service: qaService, accessGroup: nil))
        )
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
                    SyncQueueObserver.shared.sessionInstaller.authSessionWillChange(
                        previousUserID: self.session?.user.id,
                        previousAccessToken: self.session?.accessToken,
                        userID: session?.user.id,
                        accessToken: session?.accessToken
                    )
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
                let mustClearSystemActions = event == .signedOut
                    || event == .userDeleted
                    || (event == .initialSession && session == nil)
                if mustClearSystemActions {
                    do {
                        try await SystemActionRuntime.shared.clearForSignOut()
                    } catch {
                        // The account boundary has already entered durable
                        // quarantine. Do not restore the old session or expose
                        // underlying framework/account details from this
                        // asynchronous auth-state path.
                        DayPageLogger.shared.error("[AuthService] System action sign-out cleanup remains quarantined")
                    }
                }
            }
        }
    }

    // MARK: - Apple Sign-In

    func signInWithApple() async throws {
        let correlationID = UUID()
        guard !isNetworkUnavailable else {
            let err = DPAuthError.networkUnavailable
            self.error = err
            reportAuthFailure(
                provider: "apple",
                stage: "preflight",
                mappedError: err,
                sourceError: nil,
                correlationID: correlationID
            )
            throw err
        }
        isLoading = true
        error = nil
        var stage = "authorize"

        do {
            let (authorization, nonce) = try await requestAppleAuthorization()
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
            stage = "exchange"
            _ = try await supabase.auth.signInWithIdToken(
                credentials: .init(provider: .apple, idToken: identityToken, nonce: nonce)
            )
        } catch let asError as ASAuthorizationError where asError.code == .canceled {
            isLoading = false
        } catch {
            isLoading = false
            let mapped = mapSupabaseError(error)
            self.error = mapped
            reportAuthFailure(
                provider: "apple",
                stage: stage,
                mappedError: mapped,
                sourceError: error,
                correlationID: correlationID
            )
            throw mapped
        }
    }

    private func requestAppleAuthorization() async throws -> (ASAuthorization, String) {
        let nonce: String
        do {
            nonce = try NativeAuthFlow.randomNonce()
        } catch {
            throw DPAuthError.serviceUnavailable
        }

        let authorization = try await withCheckedThrowingContinuation { continuation in
            self.appleSignInContinuation = continuation
            let provider = ASAuthorizationAppleIDProvider()
            let request = provider.createRequest()
            request.requestedScopes = [.fullName, .email]
            request.nonce = NativeAuthFlow.sha256(nonce)
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
        return (authorization, nonce)
    }

    // MARK: - Email Magic Link

    /// Seconds the caller must wait before requesting another magic link for `email`.
    /// Returns 0 when fully expired (or never set). Used by UI to seed its
    /// resend countdown even after the form is closed and reopened.
    func resendCooldownRemaining(email: String) -> Int {
        AuthRateLimiter.shared.resendCooldownRemaining(email: email)
    }

    /// Requests the magic link configured by DayPage's Supabase email template.
    /// The PKCE callback must be opened on the same device that requested it.
    func sendMagicLink(email: String) async throws {
        let correlationID = UUID()
        guard !isPlaceholder else {
            let err = DPAuthError.serviceUnavailable
            self.error = err
            reportAuthFailure(
                provider: "email_link",
                stage: "send",
                mappedError: err,
                sourceError: nil,
                correlationID: correlationID
            )
            throw err
        }
        guard !isNetworkUnavailable else {
            let err = DPAuthError.networkUnavailable
            self.error = err
            reportAuthFailure(
                provider: "email_link",
                stage: "send",
                mappedError: err,
                sourceError: nil,
                correlationID: correlationID
            )
            throw err
        }

        let normalizedEmail = NativeAuthFlow.normalizedEmail(email)
        guard NativeAuthFlow.isValidEmail(normalizedEmail) else {
            let err = DPAuthError.invalidEmail
            self.error = err
            reportAuthFailure(
                provider: "email_link",
                stage: "send",
                mappedError: err,
                sourceError: nil,
                correlationID: correlationID
            )
            throw err
        }

        let callbackURL: URL
        do {
            callbackURL = try NativeAuthFlow.callbackURL(for: .iOS)
        } catch {
            let err = DPAuthError.serviceUnavailable
            self.error = err
            reportAuthFailure(
                provider: "email_link",
                stage: "send",
                mappedError: err,
                sourceError: error,
                correlationID: correlationID
            )
            throw err
        }

        let remaining = AuthRateLimiter.shared.resendCooldownRemaining(email: normalizedEmail)
        if remaining > 0 {
            let err = DPAuthError.rateLimited(retryAfter: remaining)
            self.error = err
            reportAuthFailure(
                provider: "email_link",
                stage: "send",
                mappedError: err,
                sourceError: nil,
                correlationID: correlationID
            )
            throw err
        }

        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            try await supabase.auth.signInWithOTP(
                email: normalizedEmail,
                redirectTo: callbackURL,
                shouldCreateUser: true
            )
            AuthRateLimiter.shared.recordOTPSent(email: normalizedEmail)
            DayPageLogger.shared.info("[AuthService] Magic link sent successfully")
        } catch {
            let mapped = mapSupabaseError(error)
            self.error = mapped
            reportAuthFailure(
                provider: "email_link",
                stage: "send",
                mappedError: mapped,
                sourceError: error,
                correlationID: correlationID
            )
            throw mapped
        }
    }

    /// Redeems only DayPage's exact iOS auth callback. Authentication state is
    /// still published exclusively by `authStateChanges`.
    @discardableResult
    func handleAuthCallback(_ url: URL) async -> Bool {
        let correlationID = UUID()
        guard NativeAuthFlow.isCallback(url, for: .iOS) else { return false }
        guard !isPlaceholder else {
            let err = DPAuthError.serviceUnavailable
            self.error = err
            reportAuthFailure(
                provider: "email_link",
                stage: "callback",
                mappedError: err,
                sourceError: nil,
                correlationID: correlationID
            )
            return true
        }
        guard !isNetworkUnavailable else {
            let err = DPAuthError.networkUnavailable
            self.error = err
            reportAuthFailure(
                provider: "email_link",
                stage: "callback",
                mappedError: err,
                sourceError: nil,
                correlationID: correlationID
            )
            return true
        }

        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            _ = try await supabase.auth.session(from: url)
        } catch {
            let mapped = mapSupabaseError(error)
            self.error = mapped
            reportAuthFailure(
                provider: "email_link",
                stage: "callback",
                mappedError: mapped,
                sourceError: error,
                correlationID: correlationID
            )
        }
        return true
    }

    // MARK: - Email Password Sign-In

    /// Signs in with an existing account's email + password credentials.
    ///
    /// - The password is passed to the SDK exactly as typed: never trimmed,
    ///   normalized, logged, persisted, or echoed into UI/telemetry.
    /// - Email is normalized only by the existing app rule.
    /// - Missing password is rejected before any request leaves the device.
    /// - `authStateChanges` remains the single writer of session state and the
    ///   sync realm installer; the SDK's returned `Session` is discarded here.
    func signInWithPassword(email: String, password: String) async throws {
        let correlationID = UUID()
        guard !isLoading else {
            // Re-entrancy check: one auth request at a time.
            throw DPAuthError.requestInFlight
        }
        guard !isPlaceholder else {
            let err = DPAuthError.serviceUnavailable
            self.error = err
            reportAuthFailure(
                provider: "email_password",
                stage: "sign_in",
                mappedError: err,
                sourceError: nil,
                correlationID: correlationID
            )
            throw err
        }
        guard !isNetworkUnavailable else {
            let err = DPAuthError.networkUnavailable
            self.error = err
            reportAuthFailure(
                provider: "email_password",
                stage: "sign_in",
                mappedError: err,
                sourceError: nil,
                correlationID: correlationID
            )
            throw err
        }

        let normalizedEmail = NativeAuthFlow.normalizedEmail(email)
        guard NativeAuthFlow.isValidEmail(normalizedEmail) else {
            let err = DPAuthError.invalidEmail
            self.error = err
            reportAuthFailure(
                provider: "email_password",
                stage: "sign_in",
                mappedError: err,
                sourceError: nil,
                correlationID: correlationID
            )
            throw err
        }

        guard let submission = NativeAuthFlow.passwordSubmission(from: password) else {
            // Missing password: rejected before any request. The value is never
            // logged, reported, or attached to diagnostics.
            let err = DPAuthError.missingPassword
            self.error = err
            reportAuthFailure(
                provider: "email_password",
                stage: "sign_in",
                mappedError: err,
                sourceError: nil,
                correlationID: correlationID
            )
            throw err
        }

        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            // The returned Session is intentionally discarded: the
            // authStateChanges listener publishes session state and drives the
            // existing realm installer exactly once (RC1).
            _ = try await supabase.auth.signIn(email: normalizedEmail, password: submission)
            DayPageLogger.shared.info("[AuthService] Password sign-in completed")
        } catch {
            let mapped = mapPasswordSignInError(error)
            self.error = mapped
            reportAuthFailure(
                provider: "email_password",
                stage: "sign_in",
                mappedError: mapped,
                sourceError: error,
                correlationID: correlationID
            )
            throw mapped
        }
    }

    // MARK: - Verified sync session

    /// Proves the live session user against the SAME Supabase origin and
    /// publishable key pair before any sync context is installed (initial
    /// login, token refresh or identity change). A decoded JWT is only a
    /// routing/identity pre-check; the backend's own `/auth/v1/user` answer is
    /// the authentication proof.
    func makeVerifiedSyncSession(expectedUserID: UUID? = nil) async throws -> SyncSession {
        guard !isPlaceholder,
              !Secrets.supabaseURL.isEmpty,
              !Secrets.supabasePublishableKey.isEmpty,
              let url = URL(string: Secrets.supabaseURL) else {
            throw MemoSyncError.notConfigured
        }
        let configuration = try SyncBackendConfiguration(
            url: url,
            publishableKey: Secrets.supabasePublishableKey
        )
        guard let accessToken = session?.accessToken, !accessToken.isEmpty else {
            throw MemoSyncError.unauthorized
        }
        return try await SyncSessionVerifier.verifiedSession(
            configuration: configuration,
            accessToken: accessToken,
            transport: SupabaseSyncTransport.shared(for: configuration.origin),
            expectedUserID: expectedUserID ?? session?.user.id
        )
    }

    // MARK: - Sign-Out

    func signOut() async throws {
        let correlationID = UUID()
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            // Close the action coordinator while this account's token is still
            // present. A lost claim or unconfirmed lease must block logout
            // before Supabase revokes the only identity that can reconcile it.
            try await SystemActionRuntime.shared.beginSignOutTransition()
        } catch {
            let cleanupError = DPAuthError.unknown(
                message: "系统动作仍有待确认的执行记录，请联网完成同步后再退出登录。"
            )
            self.error = cleanupError
            throw cleanupError
        }

        do {
            // "Sign out" is intentionally device-local. Other DayPage clients
            // continue syncing, matching the wording in Account Center.
            try await supabase.auth.signOut(scope: .local)
        } catch {
            // Supabase clears its local session before attempting server-side
            // refresh-token invalidation. When that request fails offline the
            // user is still safely signed out on this device, so do not trap
            // them behind a misleading error. If a local session remains, the
            // logout genuinely failed and should be recoverable in the UI.
            guard supabase.auth.currentSession == nil else {
                await SystemActionRuntime.shared.cancelSignOutTransition()
                let mapped = mapSupabaseError(error)
                self.error = mapped
                reportAuthFailure(
                    provider: "session",
                    stage: "sign_out",
                    mappedError: mapped,
                    sourceError: error,
                    correlationID: correlationID
                )
                throw mapped
            }
            DayPageLogger.shared.info("[AuthService] Local sign-out completed; remote token invalidation deferred")
        }

        // Sign-out invalidates every pending install attempt at this
        // synchronous boundary (before the delayed SwiftUI nil onChange), so
        // an old suspended proof can not reinstall after logout.
        SyncQueueObserver.shared.sessionInstaller.invalidateAllAttempts()
        SyncQueueObserver.shared.clearSession()
        session = nil   // listener will confirm; local clear takes effect immediately in UI
        SentrySDK.setUser(nil)
        do {
            try await SystemActionRuntime.shared.finishSignOutTransition()
        } catch {
            // The runtime persists a quarantine before attempting cleanup, so
            // a later account cannot execute or sync the previous account's
            // ledger/outbox. Surface a bounded recovery error without exposing
            // framework or account details.
            let cleanupError = DPAuthError.unknown(message: "已退出登录，但本机系统动作数据尚未完成清理。重新登录前将保持停用。")
            self.error = cleanupError
            throw cleanupError
        }
        DayPageLogger.shared.info("[AuthService] User signed out")
    }

    // MARK: - Error Mapping

    /// Typed, privacy-safe mapping for password sign-in failures.
    ///
    /// Unlike `mapSupabaseError`, this path never reads or routes the raw
    /// provider message: only machine-readable codes, HTTP status and system
    /// error codes are considered, and no provider payload text reaches the
    /// UI, logs or telemetry. User-facing copy is fixed and typed.
    private func mapPasswordSignInError(_ error: Error) -> DPAuthError {
        if let already = error as? DPAuthError { return already }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost,
                 .timedOut, .dataNotAllowed, .internationalRoamingOff:
                return .networkUnavailable
            default:
                return .unknown(message: debugFallbackMessage(suffix: "URL \(urlError.code.rawValue)"))
            }
        }

        if let sbError = error as? Supabase.AuthError {
            let code = sbError.errorCode
            if code == .invalidCredentials { return .invalidCredentials }
            if code == .emailNotConfirmed { return .emailConfirmationRequired }
            if code == .validationFailed { return .invalidEmail }
            if code == .overRequestRateLimit || code == .overEmailSendRateLimit {
                return .rateLimited(retryAfter: parseRetryAfter(from: sbError) ?? 60)
            }
            if code == .providerDisabled || code == .emailProviderDisabled {
                return .serviceUnavailable
            }
            if case let .api(_, _, _, response) = sbError,
               response.statusCode == 400 || response.statusCode == 401 {
                // The password grant reports credential rejections as a bare
                // 400/401 when no machine-readable code is attached.
                return .invalidCredentials
            }
            let httpStatus: Int? = {
                if case let .api(_, _, _, response) = sbError { return response.statusCode }
                return nil
            }()
            // Machine-readable code and status only — never `sbError.message`.
            return .unknown(
                message: debugFallbackMessage(
                    suffix: "code=\(code.rawValue) http=\(httpStatus.map(String.init) ?? "-")"
                )
            )
        }

        return .unknown(message: debugFallbackMessage(suffix: "type=\(type(of: error))"))
    }

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
                DayPageLogger.shared.error("[AuthService] URLError code=\(urlError.code.rawValue) desc=\(urlError.localizedDescription)")
                return .unknown(message: debugFallbackMessage(suffix: "URL \(urlError.code.rawValue)"))
            }
        }

        if let sbError = error as? Supabase.AuthError {
            let code = sbError.errorCode
            if code == .otpExpired { return .linkExpired }
            if code == .overEmailSendRateLimit
                || code == .overRequestRateLimit
                || code == .overSMSSendRateLimit {
                let retry = parseRetryAfter(from: sbError) ?? 60
                return .rateLimited(retryAfter: retry)
            }
            if code == .validationFailed { return .invalidEmail }
            if code == .providerDisabled || code == .emailProviderDisabled {
                return .serviceUnavailable
            }

            // Fall back to HTTP status codes when errorCode isn't informative.
            if case let .api(_, _, _, response) = sbError {
                if response.statusCode == 429 {
                    let retry = parseRetryAfter(from: sbError) ?? 60
                    return .rateLimited(retryAfter: retry)
                }
                if response.statusCode == 400 {
                    let msg = sbError.message.lowercased()
                    if msg.contains("expired") { return .linkExpired }
                }
            }

            // Log the raw server message privately, and in DEBUG also surface a
            // short diagnostic suffix so failures like a misconfigured Apple
            // provider are visible during development without digging Sentry.
            let httpStatus: Int? = {
                if case let .api(_, _, _, response) = sbError { return response.statusCode }
                return nil
            }()
            DayPageLogger.shared.error("[AuthService] Unmapped auth error code=\(code.rawValue) http=\(httpStatus.map(String.init) ?? "-")")
            let suffix = "code=\(code.rawValue) http=\(httpStatus.map(String.init) ?? "-")"
            return .unknown(message: debugFallbackMessage(suffix: suffix))
        }

        DayPageLogger.shared.error("[AuthService] Unknown error type: \(type(of: error))")
        return .unknown(message: debugFallbackMessage(suffix: "type=\(type(of: error))"))
    }

    private func reportAuthFailure(
        provider: String,
        stage: String,
        mappedError: DPAuthError,
        sourceError: Error?,
        correlationID: UUID
    ) {
        let status = sourceError.flatMap(authHTTPStatus)
        let networkState: OperationalEvent.NetworkState = isNetworkUnavailable ? .offline : .online
        let event = OperationalEvent(
            area: "auth",
            stage: stage,
            code: mappedError.diagnosticCode,
            correlationID: correlationID,
            level: mappedError.diagnosticCode == "unknown" ? .error : .warning,
            provider: provider,
            httpStatus: status,
            networkState: networkState
        )
        let diagnostic = AuthFailureDiagnostic(
            occurredAt: Date(),
            provider: event.provider ?? "unknown",
            stage: event.stage,
            code: event.code,
            httpStatus: event.httpStatus,
            networkState: event.networkState.rawValue,
            correlationID: event.correlationID
        )
        lastFailureDiagnostic = diagnostic
        AuthFailureDiagnosticStore.save(diagnostic)

        let safeMessage = "provider=\(diagnostic.provider) stage=\(diagnostic.stage) code=\(diagnostic.code) correlation=\(diagnostic.correlationID)"
        DayPageLogger.shared.warn("[Auth] \(safeMessage)")
        SentryReporter.breadcrumb(
            category: "auth",
            level: .warning,
            message: safeMessage
        )
        SentryReporter.captureOperationalEvent(event)
    }

    private func authHTTPStatus(from error: Error) -> Int? {
        guard let authError = error as? Supabase.AuthError,
              case let .api(_, _, _, response) = authError else { return nil }
        return response.statusCode
    }

    /// Release builds never leak server detail to users. DEBUG builds append a
    /// short diagnostic suffix so failures like a misconfigured Apple provider
    /// are visible without digging through Sentry / Console.app.
    private func debugFallbackMessage(suffix: String) -> String {
        let base = "请求失败，请稍后再试"
        #if DEBUG
        return "\(base) [\(suffix)]"
        #else
        return base
        #endif
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
