import SwiftUI

// MARK: - AppTab

enum AppTab: Equatable {
    case today
    case archive
    case feedback
    case graph
}

// MARK: - AppNavigationModel

@MainActor
final class AppNavigationModel: ObservableObject {

    @Published var selectedTab: AppTab = .today
    @Published var isSidebarOpen: Bool = false
    @Published var isFeedbackPanelOpen: Bool = false

    init() {}

    func openSidebar() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            isSidebarOpen = true
        }
    }

    func closeSidebar() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.90)) {
            isSidebarOpen = false
        }
    }

    func navigate(to tab: AppTab) {
        selectedTab = tab
        closeSidebar()
    }

    func openFeedbackPanel() {
        closeSidebar()
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            isFeedbackPanelOpen = true
        }
    }

    func closeFeedbackPanel() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.90)) {
            isFeedbackPanelOpen = false
        }
    }
}
