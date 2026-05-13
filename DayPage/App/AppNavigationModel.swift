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

    /// Deep-link target for ArchiveView. When set, ArchiveView opens its
    /// DayDetailView for this date the next time it observes the change.
    /// Cleared by ArchiveView once consumed so re-tapping the same row in the
    /// sidebar still triggers the navigation.
    @Published var pendingArchiveDate: String? = nil

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

    /// Switch to Archive and ask ArchiveView to open the DayDetailView for the
    /// given `YYYY-MM-DD` once it appears.
    func openArchive(at dateString: String) {
        pendingArchiveDate = dateString
        selectedTab = .archive
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
