import SwiftUI

// Single enum driving which full-screen modal is presented, replacing three
// independent @State bools that could race and produce a blank launch screen.
private enum AppPhase: Equatable {
    case onboarding
    case welcome
    case auth
    case ready
}

struct RootView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var nav: AppNavigationModel
    @StateObject private var bannerCenter = BannerCenter.shared
    @StateObject private var sidebarVM = SidebarViewModel()
    @ObservedObject private var appSettings = AppSettings.shared

    @State private var phase: AppPhase = RootView.initialPhase()

    private static func initialPhase() -> AppPhase {
        let hasOnboarded = UserDefaults.standard.bool(forKey: AppSettings.Keys.hasOnboarded)
        guard hasOnboarded else { return .onboarding }
        let hasSeenWelcome = UserDefaults.standard.bool(forKey: "hasSeenWelcome")
        guard hasSeenWelcome else { return .welcome }
        let authSkipped = UserDefaults.standard.bool(forKey: AppSettings.Keys.authSkipped)
        if AuthService.shared.session == nil && !authSkipped { return .auth }
        return .ready
    }

    private let sidebarWidth: CGFloat = 280

    private var feedbackPanelWidth: CGFloat {
        min(UIScreen.main.bounds.width * 0.85, 360)
    }

    private var resolvedColorScheme: ColorScheme? {
        switch appSettings.themeMode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var body: some View {
        mainContent
            .environmentObject(sidebarVM)
            .fullScreenCover(isPresented: Binding(
                get: { phase != .ready },
                set: { _ in }   // dismissal is handled by the content view callbacks
            )) {
                phaseContent
            }
            .onChange(of: authService.session != nil) { hasSession in
                // Supabase's signedIn transition can emit a transient nil session
                // (RC1). Only act when we're in auth phase or already signed in.
                if hasSession {
                    if phase == .auth { phase = .ready }
                } else {
                    let skipped = UserDefaults.standard.bool(forKey: AppSettings.Keys.authSkipped)
                    if phase == .ready && !skipped { phase = .auth }
                }
            }
            .onAppear {
                // Async session restoration: re-evaluate once the view appears in
                // case AuthService's listener fires after @State initialisation (RC3).
                if phase == .auth && authService.session != nil { phase = .ready }

                // R6: force the SyncQueueObserver singleton to instantiate so it
                // registers its `.syncQueueFlushRequested` NotificationCenter
                // observer. Without this the flush trigger SyncQueueService posts
                // when the network returns would land on no listener and the
                // pending banner would never drain. Idempotent — subsequent
                // .onAppear calls hit the already-initialised shared instance.
                _ = SyncQueueObserver.shared
            }
            .preferredColorScheme(resolvedColorScheme)
            .tint(appSettings.accentColor.color)
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch phase {
        case .onboarding:
            OnboardingView(hasOnboarded: Binding(
                get: { false },
                set: { completed in if completed { advanceFromOnboarding() } }
            ))
        case .welcome:
            WelcomeScreen(hasSeenWelcome: Binding(
                get: { false },
                set: { seen in if seen { advanceFromWelcome() } }
            ))
        case .auth:
            AuthView(onSkip: {
                UserDefaults.standard.set(true, forKey: AppSettings.Keys.authSkipped)
                phase = .ready
            })
        case .ready:
            EmptyView()
        }
    }

    private func advanceFromOnboarding() {
        let hasSeenWelcome = UserDefaults.standard.bool(forKey: "hasSeenWelcome")
        if !hasSeenWelcome {
            phase = .welcome
        } else {
            let authSkipped = UserDefaults.standard.bool(forKey: AppSettings.Keys.authSkipped)
            phase = (authService.session == nil && !authSkipped) ? .auth : .ready
        }
    }

    private func advanceFromWelcome() {
        let authSkipped = UserDefaults.standard.bool(forKey: AppSettings.Keys.authSkipped)
        phase = (authService.session == nil && !authSkipped) ? .auth : .ready
    }

    // MARK: - Main Content with Sidebar Overlay

    // Width of the left-edge strip that opens the sidebar via swipe-from-edge.
    // Kept narrow so the rest of the screen is free for horizontal gestures
    // inside child views (e.g. SwipeableMemoCard's UIKit pan). Previously the
    // open-sidebar DragGesture was attached to the entire ZStack with a 20pt
    // minimumDistance, which fought UIKit's 10pt direction-lock inside
    // SwipeableMemoCard and effectively froze left/right swipe-to-reveal.
    private let edgeSwipeWidth: CGFloat = 20

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

            // Right-side feedback panel — same scrim treatment as the sidebar
            // so both drawers feel like they belong to the same elevation tier.
            if nav.isFeedbackPanelOpen {
                Rectangle()
                    .fill(Color.black.opacity(0.42))
                    .background(.ultraThinMaterial)
                    .ignoresSafeArea()
                    .onTapGesture { nav.closeFeedbackPanel() }
                    .transition(.opacity)
                    .zIndex(1)
            }

            // Feedback panel — always mounted so the in-memory draft (input
            // text, pending images) survives close/reopen. The shadow is gated
            // on `isFeedbackPanelOpen` and the offset includes a 60pt cushion
            // so the 24pt blur + 8pt x-offset never bleeds back onto the
            // timeline (previously surfaced as a chevron-shaped sliver on the
            // right edge of memo cards).
            //
            // Math: shadow extends `radius(24) + |x|(8) = 32pt` past the
            // panel's left edge. Offsetting the panel by `width + 60` parks
            // its left edge 60pt off-screen, leaving 28pt of margin over the
            // max shadow extent. If the shadow params ever grow, bump 60 too.
            FeedbackView()
                .frame(width: feedbackPanelWidth)
                .frame(maxHeight: .infinity)
                .shadow(
                    color: Color(hex: "2D1E0A").opacity(nav.isFeedbackPanelOpen ? 0.14 : 0),
                    radius: 24, x: -8, y: 0
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
                .offset(x: nav.isFeedbackPanelOpen ? 0 : feedbackPanelWidth + 60)
                // Close-by-swipe only attached while the panel is open.
                // Previously the gesture was always installed; SwiftUI keeps
                // such gestures in arbitration even when allowsHitTesting is
                // false, which interfered with horizontal pans inside the
                // timeline (memo cards' UIKit pan recognizer).
                .modifier(
                    FeedbackCloseSwipeModifier(
                        isOpen: nav.isFeedbackPanelOpen,
                        onClose: { nav.closeFeedbackPanel() }
                    )
                )
                .allowsHitTesting(nav.isFeedbackPanelOpen)
                .zIndex(2)

            // Edge-swipe trigger: only the leftmost `edgeSwipeWidth` strip can
            // open the sidebar. By scoping the gesture to a narrow strip we
            // stop SwiftUI's DragGesture from competing with UIKit pan
            // recognizers (SwipeableMemoCard) across the entire screen.
            // simultaneousGesture keeps siblings active, so vertical timeline
            // scroll and horizontal card swipes are no longer blocked while
            // SwiftUI is still in the "Possible" arbitration window.
            if !nav.isSidebarOpen {
                Color.clear
                    .frame(width: edgeSwipeWidth)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 12, coordinateSpace: .local)
                            .onEnded { value in
                                let dx = value.translation.width
                                let dy = value.translation.height
                                guard abs(dx) > abs(dy) * 1.2 else { return }
                                if dx > 30 { nav.openSidebar() }
                            }
                    )
                    .allowsHitTesting(true)
                    .accessibilityHidden(true)
            }
        }
        // D1「和过去对话」chat sheet. Driven by `nav.pendingAskQuery`
        // (set by AskTodayIntent → daypage://ask). Wrapping the query in an
        // Identifiable lets `.sheet(item:)` present once and auto-clear the
        // pending value on dismissal so re-firing the shortcut re-opens it.
        .sheet(item: askSheetBinding) { item in
            AskPastView(seedQuestion: item.query) {
                nav.pendingAskQuery = nil
            }
        }
    }

    /// Bridges the optional `pendingAskQuery` string to a `.sheet(item:)`
    /// binding: presents AskPastView while the query is non-nil, and clears it
    /// on dismissal.
    private var askSheetBinding: Binding<AskQuery?> {
        Binding(
            get: { nav.pendingAskQuery.map(AskQuery.init) },
            set: { if $0 == nil { nav.pendingAskQuery = nil } }
        )
    }
}

// MARK: - AskQuery

/// Identifiable wrapper so a seed question can drive `.sheet(item:)`.
private struct AskQuery: Identifiable {
    let query: String
    var id: String { query }
}

// MARK: - FeedbackCloseSwipeModifier
//
// Conditionally attaches the swipe-right-to-close gesture only while the
// FeedbackView is open. Keeping it permanently attached (even with
// allowsHitTesting=false) leaves the gesture in SwiftUI's arbitration pool
// and competes with horizontal gestures elsewhere on screen (notably the
// UIKit pan inside SwipeableMemoCard).
private struct FeedbackCloseSwipeModifier: ViewModifier {
    let isOpen: Bool
    let onClose: () -> Void

    func body(content: Content) -> some View {
        if isOpen {
            content.gesture(
                DragGesture(minimumDistance: 20)
                    .onEnded { value in
                        if value.translation.width > 60 { onClose() }
                    }
            )
        } else {
            content
        }
    }
}
