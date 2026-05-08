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
        withAnimation(Motion.slide) {
            isSidebarOpen = true
        }
    }

    func closeSidebar() {
        withAnimation(Motion.slide) {
            isSidebarOpen = false
        }
    }

    func navigate(to tab: AppTab) {
        selectedTab = tab
        closeSidebar()
    }

    func openFeedbackPanel() {
        closeSidebar()
        withAnimation(Motion.slide) {
            isFeedbackPanelOpen = true
        }
    }

    func closeFeedbackPanel() {
        withAnimation(Motion.slide) {
            isFeedbackPanelOpen = false
        }
    }
}
