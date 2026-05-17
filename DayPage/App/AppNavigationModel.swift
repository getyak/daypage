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

    /// Bumped to a new UUID by system-level entry points (URL scheme,
    /// AppIntent, Widget, ControlWidget, Siri) that want to immediately
    /// open the voice recorder on Today. TodayView observes the change and
    /// flips its `isShowingVoiceRecorder` flag. We use a UUID instead of a
    /// bool so repeated triggers from the same widget tap re-fire.
    @Published var pendingRecordingTrigger: UUID? = nil

    /// Pre-filled draft text delivered via `daypage://memo/new?text=…`.
    /// TodayView consumes this once and resets it to nil.
    @Published var pendingDraftText: String? = nil

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
