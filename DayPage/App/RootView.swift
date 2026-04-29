import SwiftUI

struct RootView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var nav: AppNavigationModel
    @StateObject private var bannerCenter = BannerCenter.shared
    @ObservedObject private var appSettings = AppSettings.shared
    @State private var hasOnboarded: Bool = UserDefaults.standard.bool(forKey: AppSettings.Keys.hasOnboarded)
    @State private var authSkipped: Bool = UserDefaults.standard.bool(forKey: AppSettings.Keys.authSkipped)

    private let sidebarWidth: CGFloat = 280

    private var showAuth: Bool {
        authService.session == nil && !authSkipped
    }

    /// Resolve preferredColorScheme from AppSettings.
    private var resolvedColorScheme: ColorScheme? {
        switch appSettings.themeMode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var body: some View {
        Group {
            if hasOnboarded {
                mainContent
                    .fullScreenCover(isPresented: Binding(
                        get: { showAuth },
                        set: { if !$0 { authSkipped = UserDefaults.standard.bool(forKey: AppSettings.Keys.authSkipped) } }
                    )) {
                        AuthView(onSkip: {
                            UserDefaults.standard.set(true, forKey: AppSettings.Keys.authSkipped)
                            authSkipped = true
                        })
                    }
            } else {
                OnboardingView(hasOnboarded: $hasOnboarded)
            }
        }
        .preferredColorScheme(resolvedColorScheme)
        // Apply user-selected accent color to all SwiftUI tintable controls
        // (Button highlight, Toggle, Picker selection, TextField cursor) app-wide.
        // AppSettings.accentColor setter calls objectWillChange.send(), so RootView
        // re-renders immediately when the user changes this in Settings.
        .tint(appSettings.accentColor.color)
    }

    // MARK: - Main Content with Sidebar Overlay

    private var mainContent: some View {
        ZStack(alignment: .leading) {
            // 标签页内容 — 三个页面全部保持存活以保留 ViewModel 状态
            ZStack {
                TodayView()
                    .opacity(nav.selectedTab == .today ? 1 : 0)
                    .allowsHitTesting(nav.selectedTab == .today && !nav.isSidebarOpen)

                ArchiveView()
                    .opacity(nav.selectedTab == .archive ? 1 : 0)
                    .allowsHitTesting(nav.selectedTab == .archive && !nav.isSidebarOpen)

                FeedbackView()
                    .opacity(nav.selectedTab == .feedback ? 1 : 0)
                    .allowsHitTesting(nav.selectedTab == .feedback && !nav.isSidebarOpen)

                GraphView()
                    .opacity(nav.selectedTab == .graph ? 1 : 0)
                    .allowsHitTesting(nav.selectedTab == .graph && !nav.isSidebarOpen)
            }

            // 背景遮罩 — 点击或左滑关闭
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
        // 边缘滑动打开：仅在拖动从左侧 40pt 以内开始时触发
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
