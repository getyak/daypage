import SwiftUI

struct RootView: View {
    @EnvironmentObject private var authService: AuthService
    @StateObject private var bannerCenter = BannerCenter.shared
    @State private var hasOnboarded: Bool = UserDefaults.standard.bool(forKey: "hasOnboarded")
    @State private var authSkipped: Bool = UserDefaults.standard.bool(forKey: "authSkipped")
    @State private var selectedTab: Int = 0

    private let tabCount = 3

    private var showAuth: Bool {
        authService.session == nil && !authSkipped
    }

    var body: some View {
        Group {
            if hasOnboarded {
                mainTabView
                    .fullScreenCover(isPresented: .constant(showAuth)) {
                        AuthView()
                            .onDisappear {
                                authSkipped = UserDefaults.standard.bool(forKey: "authSkipped")
                            }
                    }
            } else {
                OnboardingView(hasOnboarded: $hasOnboarded)
            }
        }
    }

    private var mainTabView: some View {
        TabView(selection: $selectedTab) {
            TodayView()
                .tag(0)
                .tabItem {
                    Label("Today", systemImage: "square.and.pencil")
                }
                // No swipeTabGesture here — Today uses swipe gestures on memo cards

            ArchiveView()
                .tag(1)
                .tabItem {
                    Label("Archive", systemImage: "archivebox")
                }
                .swipeTabGesture(selectedTab: $selectedTab, tabIndex: 1, tabCount: tabCount)

            GraphView()
                .tag(2)
                .tabItem {
                    Label("Graph", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .swipeTabGesture(selectedTab: $selectedTab, tabIndex: 2, tabCount: tabCount)
        }
        .tint(DSColor.primary)
        .onAppear {
            let appearance = UITabBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = UIColor(DSColor.surface)
            UITabBar.appearance().standardAppearance = appearance
            UITabBar.appearance().scrollEdgeAppearance = appearance
        }
    }
}

// MARK: - Swipe Tab Gesture

private extension View {
    /// Adds a horizontal drag gesture that switches tabs on significant swipe.
    /// The gesture requires a horizontal translation > 60pt and a horizontal/vertical
    /// ratio > 1.5 so it doesn't interfere with vertical scrolling inside tabs.
    func swipeTabGesture(selectedTab: Binding<Int>, tabIndex: Int, tabCount: Int) -> some View {
        self.gesture(
            DragGesture(minimumDistance: 30, coordinateSpace: .local)
                .onEnded { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    guard abs(dx) > 60, abs(dx) > abs(dy) * 1.5 else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        if dx < 0 {
                            selectedTab.wrappedValue = min(tabIndex + 1, tabCount - 1)
                        } else {
                            selectedTab.wrappedValue = max(tabIndex - 1, 0)
                        }
                    }
                },
            including: .gesture
        )
    }
}
