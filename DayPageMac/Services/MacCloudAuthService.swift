import AuthenticationServices
import Foundation
import Supabase
import DayPageServices
import DayPageStorage

@MainActor
final class MacCloudAuthService: NSObject, ObservableObject {
    static let shared = MacCloudAuthService()

    @Published private(set) var session: Session?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var syncErrorMessage: String?

    let client: SupabaseClient

    private let configuration: MacCloudConfiguration
    private var authStateTask: Task<Void, Never>?
    private var pendingAppleNonce: String?

    private override init() {
        let configuration = MacCloudConfiguration.current()
        self.configuration = configuration
        self.client = SupabaseClient(
            supabaseURL: configuration.supabaseURL,
            supabaseKey: configuration.publishableKey
        )
        super.init()

        // Captures may enqueue before auth restoration finishes. Instantiate
        // the fail-closed observer immediately; the session event below swaps
        // in the real uploader and drains the durable backlog.
        _ = SyncQueueObserver.shared
        SyncQueueObserver.shared.clearSession()
        startAuthStateListener()
        Task { await SyncQueueService.shared.reconcileVault() }
    }

    deinit {
        authStateTask?.cancel()
    }

    var accountLabel: String? {
        session?.user.email
    }

    func sendMagicLink(email: String) async throws {
        let normalized = normalizedEmail(email)
        guard isValidEmail(normalized) else { throw MacCloudAuthError.invalidEmail }
        let callbackURL: URL
        do {
            callbackURL = try NativeAuthFlow.callbackURL(for: .macOS)
        } catch {
            throw MacCloudAuthError.invalidCallbackConfiguration
        }

        try await perform {
            try await client.auth.signInWithOTP(
                email: normalized,
                redirectTo: callbackURL,
                shouldCreateUser: true
            )
        }
    }

    /// Signs in with an existing account's email + password credentials.
    ///
    /// The password is passed to the SDK exactly as typed — never trimmed,
    /// normalized, logged or persisted — and is rejected before any request
    /// when missing. The auth-state listener stays the single writer of
    /// `session`, and its existing lease/uploader installation path is
    /// unchanged; the SDK's returned `Session` is discarded here.
    func signInWithPassword(email: String, password: String) async throws {
        guard !isLoading else { throw MacCloudAuthError.requestInFlight }
        let normalized = normalizedEmail(email)
        guard isValidEmail(normalized) else { throw MacCloudAuthError.invalidEmail }
        guard let submission = NativeAuthFlow.passwordSubmission(from: password) else {
            // Missing password is rejected without logging the value.
            throw MacCloudAuthError.missingPassword
        }

        try await perform(rejectIfBusy: true) {
            _ = try await client.auth.signIn(email: normalized, password: submission)
        }
    }

    /// Configures Apple's request and retains the original nonce until the
    /// returned ID token is exchanged with Supabase.
    func prepareAppleSignInRequest(_ request: ASAuthorizationAppleIDRequest) {
        errorMessage = nil
        do {
            let nonce = try NativeAuthFlow.randomNonce()
            pendingAppleNonce = nonce
            request.requestedScopes = [.fullName, .email]
            request.nonce = NativeAuthFlow.sha256(nonce)
            isLoading = true
        } catch {
            pendingAppleNonce = nil
            isLoading = false
            errorMessage = MacCloudAuthError.secureNonceUnavailable.localizedDescription
        }
    }

    func cancelAppleSignIn() {
        pendingAppleNonce = nil
        isLoading = false
    }

    func signInWithApple(authorization: ASAuthorization) async throws {
        guard let nonce = pendingAppleNonce else {
            isLoading = false
            throw MacCloudAuthError.appleRequestNotPrepared
        }
        defer { pendingAppleNonce = nil }

        try await perform {
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let identityToken = String(data: tokenData, encoding: .utf8)
            else {
                throw MacCloudAuthError.missingAppleCredential
            }
            _ = try await client.auth.signInWithIdToken(
                credentials: .init(provider: .apple, idToken: identityToken, nonce: nonce)
            )
        }
    }

    /// Redeems only DayPage Mac's exact callback URL. The Supabase auth-state
    /// listener remains the single writer for `session` and sync installation.
    @discardableResult
    func handleAuthCallback(_ url: URL) async -> Bool {
        guard NativeAuthFlow.isCallback(url, for: .macOS) else { return false }
        do {
            try await perform {
                _ = try await client.auth.session(from: url)
            }
        } catch {
            // `perform` already publishes a privacy-safe recovery message.
        }
        return true
    }

    func signOut() async {
        errorMessage = nil
        do {
            // Account Center promises a device-local sign-out. Keep every
            // other DayPage client online and only clear this Mac's session.
            try await client.auth.signOut(scope: .local)
        } catch {
            // The SDK may already have removed the local session when a
            // follow-up network operation fails. In that case the user's
            // requested outcome is complete and must not be reported as a
            // failed logout.
            guard client.auth.currentSession == nil else {
                errorMessage = userFacingMessage(for: error)
                return
            }
        }

        SyncQueueObserver.shared.clearSession()
        session = nil
    }

    /// Manual retry: passes the typed `.manual` reason so a full metadata
    /// refresh is forced even when the outbox is already empty (#884).
    func retrySync() {
        SyncQueueService.shared.requestFlushIfOnline(reason: .manual)
    }

    func dismissSyncError() {
        syncErrorMessage = nil
    }

    private func startAuthStateListener() {
        authStateTask?.cancel()
        authStateTask = Task { [weak self] in
            guard let self else { return }
            for await (_, restoredSession) in client.auth.authStateChanges {
                if Task.isCancelled { break }
                session = restoredSession
                installUploader(for: restoredSession)
            }
        }
    }

    private func installUploader(for restoredSession: Session?) {
        guard restoredSession != nil else {
            // Transient nil events must not clear a latched rejection, and
            // logout/nil invalidates every outstanding install attempt.
            SyncQueueObserver.shared.sessionInstaller.invalidateAllAttempts()
            SyncQueueObserver.shared.clearSession(
                rejectedConfiguration: SyncQueueObserver.shared.isConfigurationRejected
            )
            return
        }
        guard let expectedUserID = restoredSession?.user.id else { return }
        // Synchronous reservation on the auth-listener event BEFORE any Task
        // is queued: the attempt generation starts and the previous session
        // lease is invalidated here, so an older proof continuation resuming
        // before this Task starts is already stale.
        let reservation = SyncQueueObserver.shared.sessionInstaller.reserve(
            expectedUserID: expectedUserID
        )
        let accessTokenProvider: @Sendable () async throws -> String = { [weak self] in
            try await MainActor.run {
                guard let token = self?.session?.accessToken, !token.isEmpty else {
                    throw MemoSyncError.unauthorized
                }
                return token
            }
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Reservation tokens order overlapping refresh/duplicate events;
            // the live auth snapshot is re-checked at completion.
            await SyncQueueObserver.shared.sessionInstaller.install(
                reservation: reservation,
                currentUserID: { [weak self] in self?.session?.user.id },
                prove: {
                    // Same-server user proof BEFORE context installation; the
                    // decoded session JWT alone is never authentication proof.
                    try await SyncSessionVerifier.verifiedSession(
                        configuration: configuration.backend,
                        accessToken: try await accessTokenProvider(),
                        transport: SupabaseSyncTransport.shared(
                            for: configuration.backend.origin
                        ),
                        expectedUserID: expectedUserID
                    )
                },
                makeUploader: { session in
                    SupabaseSyncUploader(
                        session: session,
                        accessTokenProvider: accessTokenProvider
                    )
                },
                makePuller: { session in
                    SupabaseSyncPuller(
                        session: session,
                        accessTokenProvider: accessTokenProvider
                    )
                },
                onSuccess: { _ in
                    self.syncErrorMessage = nil
                },
                onFailure: { error in
                    // The coordinator keeps the rejection latched; a bare
                    // clearSession() would reopen the legacy upload path for a
                    // Vault that failed to bind.
                    self.syncErrorMessage = error.localizedDescription
                },
                onFlush: {
                    // A freshly installed generation requests its INITIAL
                    // pass: forced full metadata even with an empty outbox,
                    // and the demand survives a still-busy stale pass (#884).
                    SyncQueueService.shared.requestFlushIfOnline(reason: .initial)
                }
            )
        }
    }

    private func perform(rejectIfBusy: Bool = false, _ operation: () async throws -> Void) async throws {
        // The check and reservation share one synchronous MainActor turn,
        // including when callers have already queued multiple Tasks.
        guard !rejectIfBusy || !isLoading else { throw MacCloudAuthError.requestInFlight }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await operation()
        } catch let error as ASAuthorizationError where error.code == .canceled {
            return
        } catch {
            let message = userFacingMessage(for: error)
            errorMessage = message
            throw MacCloudAuthError.remote(message)
        }
    }

    private func userFacingMessage(for error: Error) -> String {
        if let local = error as? MacCloudAuthError {
            return local.localizedDescription
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut:
                return "网络暂不可用，本地记录不会丢失，请稍后重试。"
            default:
                break
            }
        }
        if let authError = error as? Supabase.AuthError {
            switch authError.errorCode {
            case .providerDisabled:
                return "Apple 登录尚未在服务器启用，请稍后再试。"
            case .overEmailSendRateLimit, .overRequestRateLimit:
                return "发送过于频繁，请稍后再试。"
            case .otpExpired:
                return "这个登录链接已过期或已使用，请重新发送。"
            case .validationFailed:
                return "请输入有效的邮箱地址。"
            case .invalidCredentials:
                return "邮箱或密码不正确，请重试。"
            case .emailNotConfirmed:
                return "请先打开邮箱中的验证邮件，完成验证后再登录。"
            default:
                break
            }
        }
        return "登录失败，请稍后重试。"
    }

    private func normalizedEmail(_ email: String) -> String {
        NativeAuthFlow.normalizedEmail(email)
    }

    private func isValidEmail(_ email: String) -> Bool {
        NativeAuthFlow.isValidEmail(email)
    }
}

private enum MacCloudAuthError: LocalizedError {
    case invalidEmail
    case missingPassword
    case requestInFlight
    case invalidCallbackConfiguration
    case secureNonceUnavailable
    case appleRequestNotPrepared
    case missingAppleCredential
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .invalidEmail:
            return "请输入有效的邮箱地址。"
        case .missingPassword:
            return "请输入密码。"
        case .requestInFlight:
            return "登录请求正在进行中，请稍候。"
        case .invalidCallbackConfiguration:
            return "登录回调配置无效，请更新 DayPage 后重试。"
        case .secureNonceUnavailable:
            return "无法安全启动 Apple 登录，请稍后重试。"
        case .appleRequestNotPrepared:
            return "Apple 登录请求已失效，请重新发起。"
        case .missingAppleCredential:
            return "无法读取 Apple 登录凭证。"
        case .remote(let message):
            return message
        }
    }
}
