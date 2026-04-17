import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            TodayView()
                .tabItem {
                    Label("Today", systemImage: "square.and.pencil")
                }

            ArchiveView()
                .tabItem {
                    Label("Archive", systemImage: "archivebox")
                }

            GraphView()
                .tabItem {
                    Label("Graph", systemImage: "point.3.connected.trianglepath.dotted")
                }
        }
        .tint(DSColor.primary)
        .onAppear {
            // Remove default tab bar background to apply custom styling
            let appearance = UITabBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = UIColor(DSColor.surface)
            UITabBar.appearance().standardAppearance = appearance
            UITabBar.appearance().scrollEdgeAppearance = appearance
        }
    }
}
