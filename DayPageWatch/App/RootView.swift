import SwiftUI

struct RootView: View {

    @StateObject private var watchSession = WatchSessionManager.shared

    var body: some View {
        NavigationStack {
            RecordingView()
        }
        .environmentObject(watchSession)
    }
}
