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

    // Drawer settle uses Motion.panel (spring) instead of Motion.slide
    // (timing curve): springs merge & retarget when interrupted, so a
    // mid-flight reversal (finger catches the drawer) keeps its velocity
    // instead of hard-cutting. Haptics fire only on actual state changes so
    // programmatic re-closes (e.g. navigate while already closed) stay silent.
    func openSidebar() {
        guard !isSidebarOpen else { return }
        Haptics.soft()
        withAnimation(Motion.respectReduceMotion(Motion.panel)) {
            isSidebarOpen = true
        }
    }

    func closeSidebar(haptic: Bool = true) {
        guard isSidebarOpen else { return }
        if haptic { Haptics.soft() }
        withAnimation(Motion.respectReduceMotion(Motion.panel)) {
            isSidebarOpen = false
        }
    }

    func navigate(to tab: AppTab) {
        if selectedTab != tab {
            Haptics.selection()
            selectedTab = tab
        }
        // Drawer close is implied by the tab selection tick — a second
        // impact here would read as a double-buzz.
        closeSidebar(haptic: false)
    }

    /// Switch to Archive and ask ArchiveView to open the DayDetailView for the
    /// given `YYYY-MM-DD` once it appears.
    func openArchive(at dateString: String) {
        pendingArchiveDate = dateString
        selectedTab = .archive
        closeSidebar()
    }

    /// Issue #7 QA (2026-07-03): switch to Archive without pushing a specific
    /// day — lets `daypage://archive` land on the Vault Overview strip.
    func openArchiveOverview() {
        pendingArchiveDate = nil
        selectedTab = .archive
        closeSidebar()
    }

    func openFeedbackPanel() {
        closeSidebar(haptic: false)
        guard !isFeedbackPanelOpen else { return }
        Haptics.soft()
        withAnimation(Motion.respectReduceMotion(Motion.panel)) {
            isFeedbackPanelOpen = true
        }
    }

    func closeFeedbackPanel() {
        guard isFeedbackPanelOpen else { return }
        Haptics.soft()
        withAnimation(Motion.respectReduceMotion(Motion.panel)) {
            isFeedbackPanelOpen = false
        }
    }
}
