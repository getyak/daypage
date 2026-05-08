import SwiftUI

struct RootView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var nav: AppNavigationModel
    @StateObject private var bannerCenter = BannerCenter.shared
    @ObservedObject private var appSettings = AppSettings.shared
    @State private var hasOnboarded: Bool = UserDefaults.standard.bool(forKey: AppSettings.Keys.hasOnboarded)
    @State private var hasSeenWelcome: Bool = UserDefaults.standard.bool(forKey: "hasSeenWelcome")
    @State private var authSkipped: Bool = UserDefaults.standard.bool(forKey: AppSettings.Keys.authSkipped)
    // Drives the auth fullScreenCover. Kept as @State (not a derived computed property)
    // so SwiftUI reliably dismisses the cover when `authService.session` flips to non-nil
    // — see issue #221, where a derived binding occasionally failed to re-evaluate.
    @State private var showAuthSheet: Bool = {
        let skipped = UserDefaults.standard.bool(forKey: AppSettings.Keys.authSkipped)
        return AuthService.shared.session == nil && !skipped
    }()

    private let sidebarWidth: CGFloat = 280

    private var feedbackPanelWidth: CGFloat {
        min(UIScreen.main.bounds.width * 0.85, 360)
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
                    .fullScreenCover(isPresented: $showAuthSheet) {
                        AuthView(onSkip: {
                            UserDefaults.standard.set(true, forKey: AppSettings.Keys.authSkipped)
                            authSkipped = true
                            showAuthSheet = false
                        })
                    }
                    .onChange(of: authService.session != nil) { hasSession in
                        // Watch the stable boolean rather than session?.user.id.
                        // During Supabase's internal signedIn transition the listener
                        // can emit a transient nil session, causing user.id to flash
                        // nil→UUID→nil→UUID and toggle showAuthSheet twice (RC1).
                        // `session != nil` is monotonically stable per sign-in event.
                        if hasSession {
                            showAuthSheet = false
                        } else {
                            showAuthSheet = !authSkipped
                        }
                    }
                    .onAppear {
                        // The @State initializer captures session synchronously at
                        // view construction time. If AuthService's async listener
                        // hasn't delivered the restored session yet, showAuthSheet
                        // starts as true even for already-signed-in users. Re-check
                        // once the view appears by which time the listener has
                        // typically fired (RC3 — lazy re-check path).
                        if authService.session != nil { showAuthSheet = false }
                    }
                    .onChange(of: authSkipped) { skipped in
                        if skipped { showAuthSheet = false }
                    }
                    .fullScreenCover(isPresented: Binding(
                        get: { !hasSeenWelcome },
                        set: { if !$0 { hasSeenWelcome = true } }
                    )) {
                        WelcomeScreen(hasSeenWelcome: $hasSeenWelcome)
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
                    .animation(Motion.fade, value: nav.selectedTab)
                    .allowsHitTesting(nav.selectedTab == .today && !nav.isSidebarOpen)

                ArchiveView()
                    .opacity(nav.selectedTab == .archive ? 1 : 0)
                    .animation(Motion.fade, value: nav.selectedTab)
                    .allowsHitTesting(nav.selectedTab == .archive && !nav.isSidebarOpen)

                GraphView()
                    .opacity(nav.selectedTab == .graph ? 1 : 0)
                    .animation(Motion.fade, value: nav.selectedTab)
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

            // Right-side feedback panel — overlay + sliding panel
            if nav.isFeedbackPanelOpen {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture { nav.closeFeedbackPanel() }
                    .transition(.opacity)
                    .zIndex(1)
            }

            FeedbackView()
                .frame(width: feedbackPanelWidth)
                .frame(maxHeight: .infinity)
                .shadow(color: Color(hex: "2D1E0A").opacity(0.14), radius: 24, x: -8, y: 0)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .offset(x: nav.isFeedbackPanelOpen ? 0 : feedbackPanelWidth + 40)
                .gesture(
                    DragGesture(minimumDistance: 20)
                        .onEnded { value in
                            if value.translation.width > 60 {
                                nav.closeFeedbackPanel()
                            }
                        }
                )
                .allowsHitTesting(nav.isFeedbackPanelOpen)
                .zIndex(2)

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
