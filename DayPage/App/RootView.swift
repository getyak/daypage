import SwiftUI
import DayPageStorage
import DayPageServices

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

                // #785: install the real iOS→web uploader when the user has
                // configured a web endpoint + API key under Settings → 同步.
                // When unconfigured this leaves the Noop double in place so the
                // queue still drains locally instead of pretending forever.
                SyncQueueObserver.shared.installConfiguredUploader()
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

    // MARK: - Interactive drawer drag

    /// Non-nil while a finger is actively dragging the sidebar — from the
    /// edge strip (opening) or the scrim (closing). Drives 1:1 tracking so
    /// the drawer follows the finger instead of playing a canned animation
    /// after the gesture ends.
    @State private var sidebarDragTranslation: CGFloat? = nil

    /// Current drawer x-offset: settled base plus live drag, clamped to the
    /// drawer's travel range (it can never overshoot fully-open).
    private var sidebarOffset: CGFloat {
        let base: CGFloat = nav.isSidebarOpen ? 0 : -sidebarWidth
        guard let drag = sidebarDragTranslation else { return base }
        return min(0, max(-sidebarWidth, base + drag))
    }

    /// 0 = fully closed, 1 = fully open. Lets the scrim's opacity track the
    /// finger during a drag instead of snapping on state change.
    private var sidebarProgress: CGFloat {
        1 + sidebarOffset / sidebarWidth
    }

    /// Resolves a finished drawer drag: commit toward whichever side the
    /// *predicted* resting offset (translation + flick momentum) lands on.
    /// The settle runs on Motion.panel so it inherits gesture velocity.
    private func settleSidebar(predictedTranslation: CGFloat) {
        guard sidebarDragTranslation != nil else { return }
        let base: CGFloat = nav.isSidebarOpen ? 0 : -sidebarWidth
        let projected = min(0, max(-sidebarWidth, base + predictedTranslation))
        let shouldOpen = projected > -sidebarWidth / 2
        withAnimation(Motion.respectReduceMotion(Motion.panel)) {
            sidebarDragTranslation = nil
        }
        if shouldOpen { nav.openSidebar() } else { nav.closeSidebar() }
    }

    private var mainContent: some View {
        ZStack(alignment: .leading) {
            // Persistent tab hosts — three pages stay alive to preserve
            // ViewModel state. The scrim on top intercepts taps while the
            // sidebar is open, so `.allowsHitTesting` only depends on the
            // active tab. Dropping `nav.isSidebarOpen` from this expression
            // removes a false animatable dependency that made the whole
            // ZStack invalidate (and briefly flicker) every time the sidebar
            // slide animation started or ended.
            ZStack {
                TodayView()
                    .opacity(nav.selectedTab == .today ? 1 : 0)
                    .allowsHitTesting(nav.selectedTab == .today)

                ArchiveView()
                    .opacity(nav.selectedTab == .archive ? 1 : 0)
                    .allowsHitTesting(nav.selectedTab == .archive)

                GraphView()
                    .opacity(nav.selectedTab == .graph ? 1 : 0)
                    .allowsHitTesting(nav.selectedTab == .graph)
            }
            // Scope the crossfade to tab swaps ONLY. Attaching on the outer
            // ZStack (instead of per-child .animation) keeps SwiftUI from
            // reinterpreting the fade every time a sibling modifier (e.g.
            // sidebar offset) animates on the same render pass.
            .animation(Motion.fade, value: nav.selectedTab)

            // 背景遮罩 — 点击关闭；左滑时 1:1 跟手拖回抽屉。
            // Mounted while dragging too, so the scrim fades in under the
            // finger during an edge-swipe open instead of popping at the end.
            if nav.isSidebarOpen || sidebarDragTranslation != nil {
                Color.black.opacity(0.28 * sidebarProgress)
                    .ignoresSafeArea()
                    .onTapGesture { nav.closeSidebar() }
                    .gesture(
                        DragGesture(minimumDistance: 10)
                            .onChanged { value in
                                // Only engage on a leftward pull (closing);
                                // once engaged, keep tracking both directions.
                                if sidebarDragTranslation == nil {
                                    guard value.translation.width < 0 else { return }
                                }
                                sidebarDragTranslation = value.translation.width
                            }
                            .onEnded { value in
                                settleSidebar(
                                    predictedTranslation: value.predictedEndTranslation.width
                                )
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
                .offset(x: sidebarOffset)
                // Take the panel out of the accessibility tree when it's off-
                // screen, otherwise VoiceOver users can still focus Settings /
                // Recent rows that are visually at negative x coordinates.
                .accessibilityHidden(!nav.isSidebarOpen)

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
                            .onChanged { value in
                                // Engage only once horizontal dominance is
                                // established on a rightward pull, so vertical
                                // timeline scroll starting near the edge never
                                // drags the drawer. After engaging, track 1:1.
                                if sidebarDragTranslation == nil {
                                    let dx = value.translation.width
                                    let dy = value.translation.height
                                    guard dx > 0, abs(dx) > abs(dy) * 1.2 else { return }
                                }
                                sidebarDragTranslation = value.translation.width
                            }
                            .onEnded { value in
                                settleSidebar(
                                    predictedTranslation: value.predictedEndTranslation.width
                                )
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
