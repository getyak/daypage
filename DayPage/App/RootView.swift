import SwiftUI

struct RootView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var nav: AppNavigationModel
    @StateObject private var bannerCenter = BannerCenter.shared
    @State private var hasOnboarded: Bool = UserDefaults.standard.bool(forKey: "hasOnboarded")
    @State private var authSkipped: Bool = UserDefaults.standard.bool(forKey: "authSkipped")

    private let sidebarWidth: CGFloat = 280

    private var showAuth: Bool {
        authService.session == nil && !authSkipped
    }

    var body: some View {
        Group {
            if hasOnboarded {
                mainContent
                    .fullScreenCover(isPresented: Binding(
                        get: { showAuth },
                        set: { if !$0 { authSkipped = UserDefaults.standard.bool(forKey: "authSkipped") } }
                    )) {
                        AuthView(onSkip: {
                            UserDefaults.standard.set(true, forKey: "authSkipped")
                            authSkipped = true
                        })
                    }
            } else {
                OnboardingView(hasOnboarded: $hasOnboarded)
            }
        }
    }

    // MARK: - Main Content with Sidebar Overlay

    private var mainContent: some View {
        ZStack(alignment: .leading) {
            // Tab content — all three kept alive to preserve ViewModel state
            ZStack {
                TodayView()
                    .opacity(nav.selectedTab == .today ? 1 : 0)
                    .allowsHitTesting(nav.selectedTab == .today && !nav.isSidebarOpen)

                ArchiveView()
                    .opacity(nav.selectedTab == .archive ? 1 : 0)
                    .allowsHitTesting(nav.selectedTab == .archive && !nav.isSidebarOpen)

                GraphView()
                    .opacity(nav.selectedTab == .graph ? 1 : 0)
                    .allowsHitTesting(nav.selectedTab == .graph && !nav.isSidebarOpen)
            }

            // Backdrop — tap or drag-left to close
            if nav.isSidebarOpen {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture { nav.closeSidebar() }
                    .gesture(
                        DragGesture(minimumDistance: 20)
                            .onEnded { value in
                                if value.translation.width < -30 { nav.closeSidebar() }
                            }
                    )
                    .transition(.opacity)
            }

            // Sidebar panel
            SidebarView()
                .frame(width: sidebarWidth)
                .frame(maxHeight: .infinity)
                .ignoresSafeArea()
                .shadow(color: Color.black.opacity(0.10), radius: 20, x: 6, y: 0)
                .offset(x: nav.isSidebarOpen ? 0 : -sidebarWidth)
        }
        // Edge-swipe to open: only fires when drag starts within 40pt of left edge
        .gesture(
            DragGesture(minimumDistance: 20, coordinateSpace: .local)
                .onEnded { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    guard abs(dx) > abs(dy) * 1.2 else { return }
                    if dx > 40, value.startLocation.x < 40, !nav.isSidebarOpen {
                        nav.openSidebar()
                    } else if dx < -40, nav.isSidebarOpen {
                        nav.closeSidebar()
                    }
                }
        )
    }
}
