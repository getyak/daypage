import SwiftUI
import Supabase

// MARK: - AuthService

/// Centralized authentication service. Manages Supabase session lifecycle,
/// exposes sign-in / sign-out methods, and publishes session state to views.
@MainActor
final class AuthService: ObservableObject {

    // MARK: Singleton

    static let shared = AuthService()

    // MARK: Published State

    @Published var session: Session?
    @Published var isLoading: Bool = false
    @Published var error: String?

    // MARK: Private

    let supabase: SupabaseClient

    // MARK: Init

    private init() {
        guard
            let url = URL(string: Secrets.supabaseURL),
            !Secrets.supabaseURL.isEmpty,
            !Secrets.supabaseAnonKey.isEmpty
        else {
            // Fallback client with placeholder values — auth calls will fail gracefully
            supabase = SupabaseClient(
                supabaseURL: URL(string: "https://placeholder.supabase.co")!,
                supabaseKey: "placeholder"
            )
            return
        }
        supabase = SupabaseClient(supabaseURL: url, supabaseKey: Secrets.supabaseAnonKey)

        // Restore existing session from keychain
        Task { await restoreSession() }
    }

    // MARK: - Session Restoration

    private func restoreSession() async {
        do {
            session = try await supabase.auth.session
        } catch {
            // No stored session — user is logged out, which is expected
            session = nil
        }
    }

    // MARK: - Sign-In Methods

    /// Initiates Apple Sign-In flow. Credential wiring implemented in US-006.
    func signInWithApple() async throws {
        // TODO: Wire ASAuthorizationAppleIDProvider in US-006
    }

    /// Sends a magic link to the given email via Supabase OTP.
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
