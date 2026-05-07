import SwiftUI

// MARK: - AuthViewModel

/// Owns loading and error state for AuthView so the view doesn't bind
/// directly to AuthService's service-level error channel.
@MainActor
final class AuthViewModel: ObservableObject {

    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    private weak var authService: AuthService?

    func bind(authService: AuthService) {
        self.authService = authService
    }

    // MARK: - Actions

    func signInWithApple() async {
        guard let authService else { return }
        isLoading = true
        errorMessage = nil
        do {
            try await authService.signInWithApple()
            isLoading = false
        } catch let err as DPAuthError {
            isLoading = false
            errorMessage = err.errorDescription
            #if canImport(UIKit)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            #endif
        } catch {
            isLoading = false
            // ASAuthorizationError.canceled is already silenced inside AuthService;
            // anything reaching here is a genuine failure mapped through DPAuthError.
            errorMessage = "登录失败，请稍后再试"
            #if canImport(UIKit)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            #endif
        }
    }

    func clearError() {
        errorMessage = nil
    }
}
