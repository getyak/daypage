import SwiftUI
import DayPageServices

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

    @Published var selectedTab: AppTab = AppNavigationModel.initialTab()
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

    /// Pre-filled search query delivered via `daypage://search?q=…` (e.g. from
    /// `AskTodayIntent`). ArchiveView observes this, presents SearchView with
    /// the query pre-populated, and clears it so re-tapping the same shortcut
    /// re-fires the navigation.
    @Published var pendingSearchQuery: String? = nil

    /// Pre-filled question delivered via `daypage://ask?q=…` (from `AskTodayIntent`).
    /// RootView observes this, presents the "和过去对话" chat sheet seeded with the
    /// question, and clears it so re-firing the same shortcut re-opens the sheet.
    /// This is the D1 entry point (research doc §3 D1); kept separate from
    /// `pendingSearchQuery` so the Shortcuts surface can route to either the
    /// keyword search (Archive) or the memory-chat agent without ambiguity.
    @Published var pendingAskQuery: String? = nil

    init() {}

    private static func initialTab() -> AppTab {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-selectedTab"),
              args.indices.contains(index + 1) else {
            return .today
        }

        switch args[index + 1].lowercased() {
        case "archive": return .archive
        case "graph": return .graph
        default: return .today
        }
    }

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
