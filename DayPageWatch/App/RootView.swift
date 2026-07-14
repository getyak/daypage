import SwiftUI
import DayPageServices

// MARK: - RootView

/// Three-page vertical TabView — the Digital Crown scrolls between them:
///
///   ↑ History  ·  ● Record (default)  ·  Settings ↓
///
/// Record is the middle page and the default landing so a recording is always
/// two seconds away (watchOS "glanceable first" principle). History sits above,
/// Settings below. Each page owns its own NavigationStack for drill-downs
/// (settings sub-pickers, future history detail).
struct RootView: View {

    @StateObject private var watchSession = WatchSessionManager.shared
    @StateObject private var settings = WatchSettingsStore.shared
    @StateObject private var history = WatchHistoryStore.shared

    /// Middle page selected by default. `.record` is the app's center of gravity.
    @State private var page: Page = .record

    private enum Page: Hashable {
        case history, record, settings
    }

    var body: some View {
        Group {
            if FeatureFlagStore.shared.isEnabled(.watchCaptureConfig) {
                threePageLayout
            } else {
                // Kill switch: fall back to the original single-screen record.
                NavigationStack { RecordingView() }
            }
        }
        .environmentObject(watchSession)
        .environmentObject(settings)
    }

    private var threePageLayout: some View {
        TabView(selection: $page) {
            NavigationStack {
                WatchHistoryView(history: history)
            }
            .tag(Page.history)

            NavigationStack {
                RecordingView()
            }
            .tag(Page.record)

            NavigationStack {
                WatchSettingsView(settings: settings)
            }
            .tag(Page.settings)
        }
        .tabViewStyle(.verticalPage)
    }
}
