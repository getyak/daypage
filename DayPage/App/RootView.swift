import SwiftUI

struct RootView: View {
    @StateObject private var bannerCenter = BannerCenter.shared
    @State private var hasOnboarded: Bool = UserDefaults.standard.bool(forKey: "hasOnboarded")

    var body: some View {
        if hasOnboarded {
            mainTabView
        } else {
            OnboardingView(hasOnboarded: $hasOnboarded)
        }
    }

    private var mainTabView: some View {
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
