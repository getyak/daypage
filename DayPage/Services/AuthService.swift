import SwiftUI
import Supabase
import AuthenticationServices

// MARK: - AuthService

/// Centralized authentication service. Manages Supabase session lifecycle,
/// exposes sign-in / sign-out methods, and publishes session state to views.
@MainActor
final class AuthService: NSObject, ObservableObject {

    // MARK: Singleton

    static let shared = AuthService()

    // MARK: Published State

    @Published var session: Session?
    @Published var isLoading: Bool = false
    @Published var error: String?

    // MARK: Private

    let supabase: SupabaseClient

    // Continuation for bridging ASAuthorization delegate to async/await
    private var appleSignInContinuation: CheckedContinuation<ASAuthorization, Error>?

    // MARK: Init

    private override init() {
        guard
            let url = URL(string: Secrets.supabaseURL),
            !Secrets.supabaseURL.isEmpty,
            !Secrets.supabaseAnonKey.isEmpty
        else {
            supabase = SupabaseClient(
                supabaseURL: URL(string: "https://placeholder.supabase.co")!,
                supabaseKey: "placeholder"
            )
            super.init()
            return
        }
        supabase = SupabaseClient(supabaseURL: url, supabaseKey: Secrets.supabaseAnonKey)
        super.init()
        Task { await restoreSession() }
    }

    // MARK: - Session Restoration

    private func restoreSession() async {
        do {
            session = try await supabase.auth.session
        } catch {
            session = nil
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
                throw AuthError.missingCredential
            }

            // Persist email on first sign-in (Apple hides it on subsequent sign-ins)
            if let email = appleCredential.email {
                UserDefaults.standard.set(email, forKey: "appleSignInEmail")
            }

            session = try await supabase.auth.signInWithIdToken(
                credentials: .init(provider: .apple, idToken: identityToken)
            )
            isLoading = false
        } catch let asError as ASAuthorizationError where asError.code == .canceled {
            isLoading = false
        } catch {
            isLoading = false
            self.error = error.localizedDescription
            throw error
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

    // MARK: - Magic Link

    func signInWithMagicLink(email: String) async throws {
        isLoading = true
        error = nil
        defer { isLoading = false }
        try await supabase.auth.signInWithOTP(email: email)
    }

    // MARK: - Sign-Out

    func signOut() async throws {
        isLoading = true
        error = nil
        defer { isLoading = false }
        try await supabase.auth.signOut()
        session = nil
    }
}

// MARK: - AuthError

private enum AuthError: LocalizedError {
    case missingCredential

    var errorDescription: String? {
        switch self {
        case .missingCredential: return "Unable to read Apple credential."
        }
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
        // Find the key window for presentation
        let scenes = UIApplication.shared.connectedScenes
        let windowScene = scenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
        return windowScene?.windows.first(where: { $0.isKeyWindow }) ?? UIWindow()
    }
}
