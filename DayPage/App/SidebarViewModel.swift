import SwiftUI

// MARK: - SidebarViewModel

/// Derives display-ready account info from the current auth session.
/// Keeps SidebarView free of direct string manipulation on session data.
@MainActor
final class SidebarViewModel: ObservableObject {

    @Published var isLoggedIn: Bool = false
    @Published var accountEmail: String = ""
    @Published var accountInitial: String = "?"

    private var authStateTask: Task<Void, Never>?

    func bind(authService: AuthService) {
        // Reflect current state immediately.
        updateFrom(authService: authService)

        // Stream subsequent changes via authStateChanges so the sidebar
        // stays in sync without polling or Combine.
        authStateTask?.cancel()
        authStateTask = Task { [weak self, weak authService] in
            guard let authService else { return }
            for await (_, session) in authService.supabase.auth.authStateChanges {
                if Task.isCancelled { break }
                let email = session?.user.email ?? ""
                await MainActor.run {
                    self?.isLoggedIn = session != nil
                    self?.accountEmail = email
                    self?.accountInitial = email.first.map { String($0).uppercased() } ?? "?"
                }
            }
        }
    }

    private func updateFrom(authService: AuthService) {
        let email = authService.session?.user.email ?? ""
        isLoggedIn = authService.session != nil
        accountEmail = email
        accountInitial = email.first.map { String($0).uppercased() } ?? "?"
    }

    deinit {
        authStateTask?.cancel()
    }
}
