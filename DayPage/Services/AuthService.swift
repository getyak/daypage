import SwiftUI
import Supabase
import AuthenticationServices
import CryptoKit
import Sentry

// MARK: - DPAuthError

/// 类型化的、面向用户的认证错误。命名为 `DPAuthError` 以避免与
/// `Supabase.AuthError` 冲突。视图层应直接渲染 `errorDescription`
/// — 无需进一步的字符串处理。
enum DPAuthError: LocalizedError, Equatable {
    case missingCredential
    case serviceUnavailable
    case invalidEmail
    /// 在客户端或服务器层触发了速率限制。`retryAfter` 是
    /// 调用者必须等待的秒数才能再次请求。
    case rateLimited(retryAfter: Int)
    case otpExpired
    case otpMismatch
    /// 用户已超出本地 OTP 尝试预算；UI 必须锁定
    /// 页面 `retryAfter` 秒。
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

/// 集中式认证服务。管理 Supabase session 生命周期，
/// 暴露登录/登出方法，向视图发布 session 状态，
/// 并强制执行客户端速率限制 + OTP 锁定。
@MainActor
final class AuthService: NSObject, ObservableObject {

    // MARK: Singleton

    static let shared = AuthService()

    // MARK: Published State

    @Published var session: Session?
    @Published var isLoading: Bool = false
    @Published var error: DPAuthError?

    // MARK: Derived — Login Provider

    enum LoginProvider {
        case apple
        case emailOTP
        case unknown
    }

    private(set) var loginProvider: LoginProvider {
        guard let email = session?.user.email else { return .unknown }
        if let appleEmail = KeychainHelper.get(forKey: Self.appleEmailKey),
           appleEmail == email {
            return .apple
        }
        return .emailOTP
    }

    // MARK: Dependencies

    let supabase: SupabaseClient
    /// 当 Secrets 缺失且我们回退到非功能性占位客户端时为 true。
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

    /// 一次性迁移：如果之前的构建将 `appleSignInEmail` 存储在
    /// UserDefaults 中，将其移至 Keychain 并擦除明文副本。
    /// 幂等 — 可在每次启动时安全调用。
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
                // Apple 只在首次登录时返回 `email`，所以我们
                // 将其持久化到 Keychain（而不是 UserDefaults）以避免 PII 泄露。
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

    /// 清除 `email` 的客户端重新发送冷却，以便下一次
    /// `sendOTP` 调用不会被阻止。仅当服务器确认
    /// 当前验证码已过期时才调用 — 不作为通用绕过。
    func resetResendCooldown(email: String) {
        defaults.removeObject(forKey: resendKey(for: email))
    }

    /// 调用者可以为 `email` 请求新 OTP 之前的剩余秒数。
    /// 如果冷却已完全过期（或从未设置），返回 0。由
    /// UI 使用来初始化其重新发送倒计时，即使在表单关闭/重新打开之间也是如此。
    func resendCooldownRemaining(email: String) -> Int {
        let key = resendKey(for: email)
        let last = defaults.double(forKey: key)
        guard last > 0 else { return 0 }
        let elapsed = Date().timeIntervalSince1970 - last
        let remaining = resendCooldown - elapsed
        return remaining > 0 ? Int(remaining.rounded(.up)) : 0
    }

    /// 请求 6 位邮箱验证码。Supabase 同时发送 magic
    /// link 和一次性令牌；我们通过 `verifyOTP` 兑换令牌。
    ///
    /// 对每个邮箱强制执行 60 秒的客户端冷却，以避免触发
    /// 服务器速率限制。
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

    /// 将 6 位 OTP 兑换为真实的 session。成功后 Supabase
    /// SDK 通过 `authStateChanges` 发出 `signedIn`，这将更新 `session`。
    ///
    /// 强制执行 5 次尝试 → 30 分钟本地锁定以阻止暴力猜测。
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
            // 成功后清除任何残留错误，以便监听器流
            // 可以干净地交接。
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
            // 对于暂时性故障（不匹配 / 过期 / 网络）不要
            // 覆盖 authService.error — 视图对这些拥有 localError。
            // 只发布影响跨视图状态的错误（上面的锁定）。
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
        session = nil   // 监听器会重新确认；本地清除对 UI 立即生效。
        SentrySDK.setUser(nil)
    }

    // MARK: - Error Mapping

    /// 将任何底层错误（Supabase `AuthError`、`URLError` 或
    /// 已类型化的 `DPAuthError`）转换为我们单一的域类型。
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

            // 当 errorCode 无帮助时，回退到 HTTP 状态码。
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

    /// 使用 SHA-256 哈希邮箱，使 UserDefaults 的 key 永远不包含 PII。
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

    /// 如果邮箱当前被锁定，返回剩余锁定秒数，
    /// 否则返回 nil。惰性清除过期的锁定。
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
