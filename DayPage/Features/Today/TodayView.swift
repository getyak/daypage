import SwiftUI
import CoreLocation

struct TodayView: View {

    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var nav: AppNavigationModel
    @StateObject private var viewModel = TodayViewModel()
    @StateObject private var passiveLocation = PassiveLocationService.shared
    @StateObject private var bannerCenter = BannerCenter.shared
    @StateObject private var voiceQueue = VoiceAttachmentQueue.shared
    @StateObject private var migrationService = VaultMigrationService.shared
    @StateObject private var compilationService = CompilationService.shared
    @EnvironmentObject private var sidebarVM: SidebarViewModel

    @Environment(\.scenePhase) private var scenePhase

    @State private var showSyncBanner: Bool = false
    @State private var showAuthSheet: Bool = false

    /// 输入栏中的草稿文本。SceneStorage persists the draft across backgrounding and process kills.
    @SceneStorage("today.draftText") private var draftText: String = ""

    /// Whether to show the Daily Page sheet.
    @State private var showDailyPage: Bool = false

    /// Date string for the fallback yesterday daily page sheet.
    @State private var fallbackDailyPageDateString: String? = nil

    /// Whether to show the Settings sheet.
    @State private var showSettings: Bool = false

    /// Date string for On This Day navigation.
    @State private var onThisDayDateString: String? = nil

    /// Current time for the header timestamp (refreshed every minute).
    @State private var currentTime: Date = Date()

    /// Whether the daily page card is swiped open to reveal the recompile action.
    @State private var dailyPageRevealed: Bool = false

    /// Session-only flag: true once the "restored unsent draft" banner has been shown this session.
    @State private var draftRestoredBannerShown: Bool = false

    // US-006: Date the draft was last modified, stored in UserDefaults.
    // If the draft is older than 30 days it is auto-cleared on next launch.
    @AppStorage("today.draftDate") private var draftDate: Double = 0

    // Rolling count of the last successfully-loaded memo set for today.
    // Drives MemoListSkeleton so placeholder height matches expected content height.
    @AppStorage("today.skeletonCardCount") private var skeletonCardCount: Int = 3

    // US-009: Text to restore if undo is tapped within 5s of submit.
    @State private var undoText: String? = nil
    @State private var undoTask: Task<Void, Never>? = nil

    // US-010: First-run tutorial overlay
    @State private var showTutorial: Bool = false

    // Issue #302: share-card sheet payload. Set by long-press on a memo.
    @State private var sharePayload: SharePayload? = nil

    // Issue #309 W2: multi-select mode. When non-nil, the timeline is in
    // selection mode: card taps toggle membership instead of navigating,
    // swipe panels are disabled, and a top action bar lets the user share
    // the selection as a collage. Reset to nil to leave the mode.
    //
    // Set is session-scoped — switching tabs or backgrounding the app
    // clears it implicitly (TodayView re-renders fresh). We don't persist
    // across launches; selection is always an immediate action.
    @State private var selectedMemoIds: Set<UUID>? = nil

    /// Programmatic memo-detail navigation. The card body no longer uses a
    /// SwiftUI NavigationLink (the swipe gesture's UIKit host hit-tests to
    /// self, which would swallow the link's tap); instead a tap recognizer
    /// fires `onOpen`, which sets this id and drives `navigationDestination`.
    @State private var openedMemoID: UUID? = nil

    /// v8 WriteSheet — bottom-sheet text composer opened from the dock's text
    /// affordance (composer.jsx:183). Routes saves through `submitCombinedMemo`
    /// (the same path the inline composer uses) via `draftText`.
    @State private var showWriteSheet: Bool = false

    /// Toggled each time the Day Orb is tapped to focus the composer input.
    @State private var orbFocusToggle: Bool = false
    /// Toggled each time a new memo is added while the orb hero is visible, triggering a capture-reward glow pulse.
    @State private var orbCapturePulse: Bool = false

    /// US-019: controls the markdown export share sheet.
    @State private var showExportSheet: Bool = false
    @State private var exportFileURL: URL? = nil

    /// One-time discoverable pulse on the export button (fires when button first appears with >=1 memo).
    @State private var exportHintPulse: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var orbBreathing: Bool = false

    /// Hint offset for the one-time swipe-left nudge on the Daily Page card.
    @State private var dailyPageHintOffset: CGFloat = 0
    @State private var memoCardHintOffset: CGFloat = 0

    /// Session-only: true once the 3-memo unlock celebration has fired this session.
    /// Resets to false when memo count drops back below 3 so delete+readd re-fires it.
    @State private var didCelebrateUnlock: Bool = false
    /// Drives the one-shot amber glow pulse on the compile button at unlock.
    @State private var unlockGlow: Bool = false
    /// Tracks the previous memo count so escalating haptics only fire on additions, not deletions.
    @State private var lastMemoCount: Int = 0

    /// True when a new memo arrived while the user was scrolled past the ~240pt threshold.
    /// Drives the amber dot badge on the scroll-to-top button. Cleared on scroll-to-top.
    @State private var hasNewContentAboveFold: Bool = false

    /// Session-only: true once the compile-completion celebration has fired for the current daily page.
    /// Resets to false when isDailyPageCompiled becomes false (recompile/new day) so it re-fires.
    @State private var didCelebrateCompile: Bool = false
    /// Drives the one-shot amber glow + scale reveal on the daily page card after compilation.
    @State private var compileRevealGlow: Bool = false

    /// Drives the one-shot amber glow pulse on the orb / timeline top after pull-to-refresh.
    @State private var refreshGlow: Bool = false

    /// Milestone feedback when the scroll-to-top progress ring fills to 100%.
    @State private var didReachScrollEnd: Bool = false
    @State private var scrollRingGlow: Bool = false
    /// Tracks which 1/3-ring milestone bucket (0/1/2) has already fired a haptic tick this scroll gesture.
    @State private var lastScrollMilestone: Int = 0

    /// Scroll proxy captured from the timeline ScrollViewReader; used by composeSection
    /// to scroll to the top anchor after a new memo is added.
    @State private var timelineScrollProxy: ScrollViewProxy? = nil

    // US-005: Tracks timeline scroll offset to activate the glass header bar.
    // Becomes negative as the user scrolls down; < -8 triggers the frosted glass.
    @State private var timelineScrollOffset: CGFloat = 0

    private var isInSelectionMode: Bool { selectedMemoIds != nil }

    /// Progress of the scroll-to-top ring: 0 at 240pt (button appears), 1 after 1200pt more.
    private var scrollProgress: CGFloat {
        min(1, max(0, (-timelineScrollOffset - 240) / 1200))
    }

    /// Fraction of the current local day elapsed (0.0 at midnight, 1.0 at next midnight).
    private var dayProgress: CGFloat {
        DayProgress.fraction(at: currentTime)
    }

    /// Live drag offset for the daily page card (negative = pulled left).
    @GestureState private var dailyPageDrag: CGFloat = 0

    private let headerTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var todayPendingDrafts: [VisitDraft] {
        passiveLocation.todayPendingDrafts()
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                // V4: Warm ambient canvas — glass surfaces refract against this
                AmbientBackground()
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    // MARK: Sidebar/Header (US-021: extracted subview)
                    sidebarSection

                    // MARK: Compilation Progress Bar
                    if viewModel.isCompiling {
                        CompilationProgressBar(stage: compilationService.stage)
                            .transition(.opacity)
                            .animation(Motion.fade, value: viewModel.isCompiling)
                    }

                    // MARK: Compilation Failed Banner
                    if let failureMsg = viewModel.compilationFailedError {
                        CompilationFailedBanner(message: failureMsg) {
                            viewModel.compilationFailedError = nil
                            viewModel.compile()
                        } onDismiss: {
                            viewModel.compilationFailedError = nil
                        }
                    }

                    // MARK: Sync Prompt Banner
                    if showSyncBanner {
                        syncBanner
                    }

                    // MARK: Location Draft Card
                    if !todayPendingDrafts.isEmpty {
                        LocationDraftCard(
                            drafts: todayPendingDrafts,
                            onConfirm: { draft in
                                do { try passiveLocation.confirmDraft(draft) }
                                catch { DayPageLogger.shared.error("TodayView: confirmDraft: \(error)") }
                                viewModel.load()
                            },
                            onIgnore: { draft in
                                passiveLocation.ignoreDraft(draft)
                            },
                            onConfirmAll: {
                                for draft in todayPendingDrafts {
                                    do { try passiveLocation.confirmDraft(draft) }
                                    catch { DayPageLogger.shared.error("TodayView: confirmDraft: \(error)") }
                                }
                                viewModel.load()
                            },
                            onIgnoreAll: {
                                for draft in todayPendingDrafts {
                                    passiveLocation.ignoreDraft(draft)
                                }
                            }
                        )
                    }

                    // MARK: Day Orb Hero — serif date + mono kicker + orb
                    // Hide when memos exist: the header already shows the date,
                    // and the 140pt orb wastes prime content space once there
                    // are signals in the timeline. (#US-016)
                    if viewModel.memos.isEmpty {
                        orbHero
                            .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
                            .animation(Motion.dismiss, value: viewModel.memos.isEmpty)
                    }

                    // MARK: Selection toolbar (issue #309 W2)
                    // Renders only while in multi-select mode, between the
                    // header and the timeline. Lifted out of the ScrollView
                    // so it stays pinned during scroll and never overlaps a
                    // selected card's chrome.
                    if let selected = selectedMemoIds {
                        selectionToolbar(selectedIds: selected)
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                            .padding(.bottom, 4)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    // MARK: Timeline (US-021: extracted subview)
                    timelineSection

                    // MARK: Compose (US-021: extracted subview)
                    composeSection
                }
                // US-009: Undo pill shown for 5s after memo submit
                .overlay(alignment: .bottom) {
                    if let text = undoText {
                        UndoPillView {
                            draftText = text
                            undoText = nil
                            undoTask?.cancel()
                        } onDismiss: {
                            undoText = nil
                            undoTask?.cancel()
                        }
                        .padding(.bottom, 96)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(Motion.rise, value: undoText != nil)
                // Undo pill shown for 5s after memo delete
                .overlay(alignment: .bottom) {
                    if viewModel.lastDeletedMemo != nil {
                        UndoPillView(label: NSLocalizedString("undo_pill.label.delete", comment: "Undo delete pill label")) {
                            viewModel.undoDelete()
                        } onDismiss: {
                            viewModel.lastDeletedMemo = nil
                        }
                        .padding(.bottom, 96)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(Motion.rise, value: viewModel.lastDeletedMemo != nil)
                // Scroll-to-top chevron — fades in at bottom-trailing when scrolled past 240pt
                .overlay(alignment: .bottomTrailing) {
                    if timelineScrollOffset < -240 && !viewModel.memos.isEmpty && !isInSelectionMode {
                        Button {
                            hasNewContentAboveFold = false
                            Haptics.soft()
                            withAnimation(reduceMotion ? nil : Motion.spring) {
                                timelineScrollProxy?.scrollTo("timelineTop", anchor: .top)
                            }
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "chevron.up")
                                    .font(DSType.bodySM)
                                    .foregroundColor(DSColor.inkMuted)
                                    .frame(width: 28, height: 28)
                                    .background(DSColor.glassStd)
                                    .background(.ultraThinMaterial, in: Circle())
                                    .overlay(Circle().strokeBorder(DSColor.glassRim, lineWidth: 0.5))
                                    .overlay(
                                        Circle()
                                            .trim(from: 0, to: scrollProgress)
                                            .stroke(
                                                DSColor.accentAmber,
                                                style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                                            )
                                            .rotationEffect(.degrees(-90))
                                            .animation(reduceMotion ? nil : Motion.fade, value: scrollProgress)
                                    )
                                    .shadow(
                                        color: DSColor.accentAmber.opacity(scrollRingGlow ? 0.5 : 0),
                                        radius: scrollRingGlow ? 14 : 0
                                    )
                                    .animation(.easeOut(duration: 0.6), value: scrollRingGlow)
                                    .clipShape(Circle())

                                if hasNewContentAboveFold {
                                    Circle()
                                        .fill(DSColor.accentAmber)
                                        .frame(width: 7, height: 7)
                                        .offset(x: 1, y: -1)
                                        .transition(.scale)
                                        .animation(reduceMotion ? nil : Motion.spring, value: hasNewContentAboveFold)
                                }
                            }
                        }
                        .padding(.trailing, 20)
                        .padding(.bottom, 96)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                        .accessibilityLabel(hasNewContentAboveFold
                            ? NSLocalizedString("scroll_to_top.label.new_content", comment: "")
                            : NSLocalizedString("scroll_to_top.label.default", comment: ""))
                        .accessibilityHint("Returns to the top of today's timeline")
                        .accessibilityIdentifier("scroll-to-top-button")
                    }
                }
                .animation(reduceMotion ? nil : Motion.rise, value: timelineScrollOffset < -240)
                .onChange(of: scrollProgress) { progress in
                    // Intermediate milestone ticks at 33% and 66% fill.
                    let milestone = Int(progress * 3) // 0/1/2/3
                    if milestone > lastScrollMilestone && milestone < 3 && !reduceMotion {
                        Haptics.rigid(intensity: 0.3 + 0.2 * CGFloat(milestone))
                        lastScrollMilestone = milestone
                    }
                    if progress >= 1.0 && !didReachScrollEnd {
                        didReachScrollEnd = true
                        hasNewContentAboveFold = false
                        Haptics.soft()
                        if !reduceMotion {
                            scrollRingGlow = true
                            Task {
                                try? await Task.sleep(nanoseconds: 600_000_000)
                                scrollRingGlow = false
                            }
                        }
                    } else if progress < 0.95 {
                        didReachScrollEnd = false
                        lastScrollMilestone = 0
                    }
                }
                // Submit error toast — scoped animation lives on the overlay
                // container so only the toast itself animates, not the whole
                // ZStack tree. (#217)
                .overlay(alignment: .top) {
                    ZStack(alignment: .top) {
                        if let err = viewModel.submitError {
                            Text(err)
                                .bodySMStyle()
                                .foregroundColor(DSColor.onError)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(DSColor.error)
                                .padding(.top, 8)
                                .transition(.move(edge: .top).combined(with: .opacity))
                                .onAppear {
                                    Task { @MainActor in
                                        try? await Task.sleep(for: .seconds(3))
                                        viewModel.submitError = nil
                                    }
                                }
                        }
                    }
                    .animation(Motion.rise, value: viewModel.submitError)
                }
            }
            .navigationBarHidden(true)
            // US-030: left-edge swipe (within first 20pt) opens sidebar
            .gesture(
                DragGesture(minimumDistance: 20, coordinateSpace: .local)
                    .onEnded { value in
                        guard value.startLocation.x < 20,
                              value.translation.width > 40,
                              abs(value.translation.width) > abs(value.translation.height) * 1.2
                        else { return }
                        nav.openSidebar()
                    }
            )
            .navigationDestination(for: UUID.self) { memoID in
                if let memo = viewModel.memos.first(where: { $0.id == memoID }) {
                    MemoDetailView(memo: memo, vm: viewModel)
                }
            }
            // Programmatic detail navigation for the card-body tap (the swipe
            // card drives this instead of a NavigationLink — see openedMemoID).
            // Uses isPresented (iOS 16+) rather than item: to stay portable.
            .navigationDestination(
                isPresented: Binding(
                    get: { openedMemoID != nil },
                    set: { if !$0 { openedMemoID = nil } }
                )
            ) {
                if let id = openedMemoID,
                   let memo = viewModel.memos.first(where: { $0.id == id }) {
                    MemoDetailView(memo: memo, vm: viewModel)
                }
            }
            .onAppear {
                clearDraftIfExpired()
                viewModel.load()
                updateVoiceQueueBanner(count: voiceQueue.pendingCount)
                showDraftRestoredBannerIfNeeded()
                if InputBarTutorialOverlay.shouldShow {
                    showTutorial = true
                }
            }
            .onChange(of: draftText) { _ in
                draftDate = Date().timeIntervalSince1970
            }
            .onChange(of: voiceQueue.pendingCount) { count in
                updateVoiceQueueBanner(count: count)
                // When a transcription finishes (count drops), reload memos so the
                // newly-written transcript appears in the card without user intervention.
                viewModel.load()
            }
            // Reload when app returns from background to correct the active date (midnight crossover).
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    viewModel.load()
                }
            }
            // US-017: consume pending draft text from daypage://memo/new?text=…
            .onChange(of: nav.pendingDraftText) { text in
                guard let text else { return }
                draftText = text
                nav.pendingDraftText = nil
            }
            // Bridge the ViewModel settings flag to the View-local sheet binding.
            .onChange(of: viewModel.shouldShowSettings) { show in
                if show {
                    showSettings = true
                    viewModel.shouldShowSettings = false
                }
            }
            // Daily Page full-screen sheet
            .fullScreenCover(isPresented: $showDailyPage) {
                let dateStr: String = {
                    let f = DateFormatter()
                    f.dateFormat = "yyyy-MM-dd"
                    f.locale = Locale(identifier: "en_US_POSIX")
                    f.timeZone = TimeZone.current
                    return f.string(from: Date())
                }()
                DailyPageView(
                    dateString: dateStr,
                    onReturnToToday: { question in
                        draftText = question
                        showDailyPage = false
                    }
                )
            }
            // Voice recording half-screen sheet
            // On complete: immediately submit the recording as a standalone memo.
            .sheet(isPresented: $viewModel.isShowingVoiceRecorder) {
                VoiceRecordingView(
                    onComplete: { result in
                        viewModel.isShowingVoiceRecorder = false
                        viewModel.addVoiceAndSubmit(result: result)
                    },
                    onCancel: {
                        viewModel.cancelVoiceRecording()
                    }
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.hidden)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            // US-019: Markdown export share sheet
            .sheet(isPresented: $showExportSheet) {
                if let url = exportFileURL {
                    ShareSheet(activityItems: [url])
                }
            }
            // Document picker sheet
            .sheet(isPresented: $viewModel.isShowingDocumentPicker) {
                DocumentPickerView(
                    onPick: { url in
                        viewModel.addFileAttachment(url: url)
                    },
                    onCancel: {
                        viewModel.isShowingDocumentPicker = false
                    }
                )
                .ignoresSafeArea()
            }
            // Camera capture sheet (fullScreenCover so the camera UI uses full screen)
            .fullScreenCover(isPresented: $viewModel.isShowingCamera) {
                CameraPickerView(
                    onCapture: { image in
                        viewModel.isShowingCamera = false
                        viewModel.addCameraPhotoAndSubmit(image)
                    },
                    onCancel: {
                        viewModel.isShowingCamera = false
                    }
                )
                .ignoresSafeArea()
            }
            // On This Day navigation to DayDetailView
            .fullScreenCover(item: Binding(
                get: { onThisDayDateString.map { OnThisDayNavTarget(dateString: $0) } },
                set: { onThisDayDateString = $0?.dateString }
            )) { target in
                DayDetailView(dateString: target.dateString)
            }
            // Fallback "yesterday daily page" cover — opened from the zero-memo
            // fallback view when yesterday already has a compiled page.
            .fullScreenCover(item: Binding(
                get: { fallbackDailyPageDateString.map { OnThisDayNavTarget(dateString: $0) } },
                set: { fallbackDailyPageDateString = $0?.dateString }
            )) { target in
                DailyPageView(
                    dateString: target.dateString,
                    onReturnToToday: { _ in
                        fallbackDailyPageDateString = nil
                    }
                )
            }
            .bannerOverlay()
            // US-010: First-run input bar tutorial
            .overlay {
                if showTutorial {
                    InputBarTutorialOverlay(isPresented: $showTutorial)
                        .ignoresSafeArea()
                        .transition(.opacity)
                }
            }
            .animation(Motion.dismiss, value: showTutorial)
            .sheet(isPresented: $showAuthSheet) {
                AuthView()
            }
            // iCloud migration progress sheet — shown during vault migration
            .sheet(isPresented: $migrationService.isMigrating) {
                MigrationProgressSheet(service: migrationService)
            }
            // Issue #302: share-card sheet, opened via long-press on a memo.
            .sheet(item: $sharePayload) { payload in
                ShareCardSheet(payload: payload)
            }
            // v8 WriteSheet — custom bottom sheet (scrim + drag handle + sheet-up
            // anim are drawn inside the view), so it presents as a full-screen
            // overlay rather than a system `.sheet`. Saves route through the same
            // `submitCombinedMemo` path the dock composer uses (draftText binding).
            .overlay { writeSheetOverlay }
            .onAppear {
                evaluateSyncBanner()
                // Handle a Quick Capture trigger that fired before TodayView
                // appeared (cold launch via Widget / Siri / URL scheme).
                if nav.pendingRecordingTrigger != nil {
                    viewModel.isShowingVoiceRecorder = true
                    nav.pendingRecordingTrigger = nil
                }
            }
            .onChange(of: authService.session) { _ in
                evaluateSyncBanner()
            }
            .onChange(of: nav.pendingRecordingTrigger) { newValue in
                guard newValue != nil else { return }
                viewModel.isShowingVoiceRecorder = true
                nav.pendingRecordingTrigger = nil
            }
        }
    }

    // MARK: - Sync Banner Logic

    private func evaluateSyncBanner() {
        // If user is already authenticated, never show the banner
        guard authService.session == nil else {
            showSyncBanner = false
            return
        }
        let saveCount = UserDefaults.standard.integer(forKey: AppSettings.Keys.memoSaveCount)
        let authSkipped = UserDefaults.standard.bool(forKey: AppSettings.Keys.authSkipped)
        guard saveCount >= 3, authSkipped else { return }
        let lastShown = UserDefaults.standard.object(forKey: AppSettings.Keys.lastSyncBannerDate) as? Date
        let sevenDays: TimeInterval = 7 * 24 * 3600
        if let last = lastShown, Date().timeIntervalSince(last) < sevenDays { return }
        showSyncBanner = true
    }

    private var syncBanner: some View {
        DSBanner(
            kind: .info,
            title: "Sync your journal across devices",
            subtitle: "Sign in to back up your notes",
            primaryAction: (label: "Sync", action: { showAuthSheet = true }),
            onDismiss: {
                withAnimation { showSyncBanner = false }
                UserDefaults.standard.set(Date(), forKey: AppSettings.Keys.lastSyncBannerDate)
            }
        )
        .padding(.horizontal, DSSpacing.pageMargin)
        .padding(.bottom, DSSpacing.xs)
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    if value.translation.height < -10 {
                        withAnimation { showSyncBanner = false }
                        UserDefaults.standard.set(Date(), forKey: AppSettings.Keys.lastSyncBannerDate)
                    }
                }
        )
    }

    // MARK: - Fallback Content (zero-memo today)

    /// Shown in the timeline when the user is onboarded but today has no memos.
    /// Priority is decided by `viewModel.fallbackContent`; each branch falls
    /// back to existing components instead of inventing a new visual language.
    @ViewBuilder
    private var fallbackContentView: some View {
        switch viewModel.fallbackContent {
        case .yesterdayDailyPage(let page):
            yesterdayDailyPageFallback(page)
        case .onThisDay(let memos):
            onThisDayFallback(memos: memos)
        case .weekRecap(let entries):
            WeeklyRecapSection(entries: entries) { dateString in
                onThisDayDateString = dateString
            }
        case .pureEmpty:
            EmptyStateView.todayNoSignals(ctaAction: { orbFocusToggle.toggle() }, subtitleOverride: todayEmptySubtitle(currentTime))
                .padding(.horizontal, 20)
        }
    }

    // MARK: - Yesterday Section (shared by fallback and supplement paths)

    @ViewBuilder
    private func yesterdaySection(_ page: DailyPageModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString("today.section.yesterday", comment: ""))
                .font(DSType.mono10)
                .tracking(1.0)
                .foregroundColor(DSColor.inkSubtle)
                .dynamicTypeSize(.xSmall ... .accessibility5)
                .padding(.horizontal, 20)

            DailyPageEntryCard(
                summary: page.summary.isEmpty ? nil : page.summary,
                onTap: {
                    fallbackDailyPageDateString = page.dateString
                }
            )
            .padding(.horizontal, 20)
        }
    }

    // MARK: - History Supplement (memos present — shown at timeline bottom)

    /// History supplement rendered below today's raw memos. Previously this
    /// only showed yesterday's compiled page or the weekly recap; now it owns
    /// the full historical timeline (#276) — this week's other days, last
    /// week, week-before-last, and older months as expandable cards.
    @ViewBuilder
    private var historySupplement: some View {
        if !viewModel.memos.isEmpty && viewModel.loadState == .ready && !viewModel.timelineSections.isEmpty {
            earlierDivider
            ForEach(viewModel.timelineSections) { section in
                TimelineSectionView(section: section)
            }
        }
    }

    // MARK: - Earlier Divider

    /// Horizontal rule with "EARLIER" label that visually separates today's
    /// memo list from the history supplement section.
    private var earlierDivider: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(DSColor.inkFaint)
                .frame(height: 0.5)
            Text(NSLocalizedString("today.section.earlier", comment: ""))
                .font(DSType.mono10)
                .tracking(1.0)
                .foregroundColor(DSColor.inkSubtle)
                .dynamicTypeSize(.xSmall ... .accessibility5)
                .padding(.horizontal, 8)
            Rectangle()
                .fill(DSColor.inkFaint)
                .frame(height: 0.5)
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func yesterdayDailyPageFallback(_ page: DailyPageModel) -> some View {
        yesterdaySection(page)
    }

    @ViewBuilder
    private func onThisDayFallback(memos: [Memo]) -> some View {
        // Prefer the structured `onThisDayEntry` (carries yearsAgo + filePath);
        // synthesize a lightweight one from memos when the index is cold.
        let entry = viewModel.onThisDayEntry ?? OnThisDayEntry(
            originalDate: memos.first?.created ?? Date(),
            yearsAgo: nil,
            daysAgo: nil,
            preview: memos.first?.body.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            filePath: ""
        )
        OnThisDayCard(
            entry: entry,
            onDismiss: { viewModel.onThisDayEntry = nil },
            onTap: { tapped in
                onThisDayDateString = Self.dateString(from: tapped.originalDate)
            }
        )
    }

    private static func dateString(from date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f.string(from: date)
    }

    // MARK: - Swipeable Daily Page Card

    /// Daily Page entry card with a left-swipe-to-reveal "重新编译" action.
    /// Mirrors the SwipeableMemoCard interaction: drag the card left, snap
    /// open at -44pt, tap the revealed amber button to recompile, or tap
    /// the card itself to dismiss the open state.
    @ViewBuilder
    private var swipeableDailyPageCard: some View {
        ZStack(alignment: .center) {
            HStack(spacing: 0) {
                Spacer()
                Button {
                    withAnimation(Motion.spring) {
                        dailyPageRevealed = false
                    }
                    viewModel.compile()
                } label: {
                    Text(NSLocalizedString("today.action.recompile", comment: ""))
                        .font(DSType.caption)
                        .foregroundColor(.white)
                        .frame(width: 80)
                        .frame(maxHeight: .infinity)
                        .background(DSColor.accentAmber)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Recompile")
            }

            DailyPageEntryCard(
                summary: viewModel.dailyPageSummary,
                onTap: {
                    if dailyPageRevealed {
                        Haptics.soft()
                        withAnimation(Motion.spring) {
                            dailyPageRevealed = false
                        }
                    } else {
                        Haptics.tapConfirm()
                        showDailyPage = true
                    }
                }
            )
            .accessibilityElement(children: .combine)
            .accessibilityHint(NSLocalizedString("today.accessibility.dailypage.hint", comment: ""))
            .accessibilityAction(named: Text(NSLocalizedString("today.action.recompile", comment: ""))) {
                viewModel.compile()
                withAnimation(Motion.spring) {
                    dailyPageRevealed = false
                }
            }
            .offset(x: (dailyPageRevealed ? -80 : 0) + dailyPageDrag + dailyPageHintOffset)
            .onAppear {
                guard !UserDefaults.standard.bool(forKey: AppSettings.Keys.dailyPageSwipeHintShown),
                      !reduceMotion else { return }
                UserDefaults.standard.set(true, forKey: AppSettings.Keys.dailyPageSwipeHintShown)
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(0.6))
                    withAnimation(Motion.spring) { dailyPageHintOffset = -24 }
                    Haptics.soft()
                    try? await Task.sleep(for: .seconds(0.45))
                    withAnimation(Motion.spring) { dailyPageHintOffset = 0 }
                }
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 10)
                    .updating($dailyPageDrag) { value, state, _ in
                        if value.translation.width < 0 {
                            state = value.translation.width
                        }
                    }
                    .onEnded { value in
                        withAnimation(Motion.spring) {
                            dailyPageRevealed = value.translation.width < -44
                        }
                    }
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Daily page")
        .accessibilityValue(viewModel.dailyPageSummary ?? "")
        .accessibilityHint("Double tap to open the daily page")
        .accessibilityAction { showDailyPage = true }
        .accessibilityAction(named: Text(NSLocalizedString("today.action.recompile", comment: ""))) {
            dailyPageRevealed = false
            viewModel.compile()
        }
    }

    // MARK: - Day Orb Hero

    /// Hero region shown at the top of Today: serif date + mono signal kicker + 200pt Day Orb.
    @ViewBuilder
    private var orbHero: some View {
        // The 56pt hero title now lives in `sidebarSection` (always-on), so the
        // empty-state orb block only carries the orb + kicker to avoid a
        // duplicate weekday title.
        VStack(spacing: 6) {
            Text(orbGreeting(currentTime))
                .font(DSType.serifDisplay28)
                .foregroundColor(DSColor.inkPrimary)
                .dynamicTypeSize(.xSmall ... .accessibility2)
                .minimumScaleFactor(0.7)
                .padding(.bottom, 2)

            // Split the kicker so the signal count can animate with numericText
            // while date/time remain stable. HStack(spacing:0) keeps the line
            // visually identical to the old single-Text layout.
            HStack(spacing: 0) {
                Text(orbKickerPrefix(currentTime))
                    .font(DSType.mono10)
                    .foregroundColor(DSColor.inkSubtle)
                    .textCase(.uppercase)
                    .tracking(1.0)
                Text("\(viewModel.signalCount)")
                    .font(DSType.mono10)
                    .foregroundColor(DSColor.inkSubtle)
                    .textCase(.uppercase)
                    .tracking(1.0)
                    .modifier(NumericTextContentTransition(value: Double(viewModel.signalCount), reduceMotion: reduceMotion))
                    .animation(reduceMotion ? nil : Motion.spring, value: viewModel.signalCount)
                Text(orbKickerSuffix())
                    .font(DSType.mono10)
                    .foregroundColor(DSColor.inkSubtle)
                    .textCase(.uppercase)
                    .tracking(1.0)
            }
            .accessibilityLabel(orbKicker(currentTime))

            let glowBoost = min(Double(viewModel.signalCount), 5) * 0.04
            let signalCount = viewModel.signalCount
            let orbValueKey = signalCount == 1 ? "today.orb.value.one" : "today.orb.value.other"
            let orbValue = String(format: NSLocalizedString(orbValueKey, comment: ""), signalCount)
            let tint = orbTint(currentTime)
            DayOrbView(signalCount: signalCount, size: 140, onTap: {
                Haptics.tapConfirm()
                orbFocusToggle.toggle()
            }, pulseToggle: orbCapturePulse, dayProgress: dayProgress, timeTint: tint)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.8), value: tint)
            .scaleEffect(reduceMotion ? 1.0 : (orbBreathing ? 1.03 : 0.985))
            .shadow(
                color: tint.opacity(orbBreathing ? 0.28 + glowBoost : 0.12 + glowBoost),
                radius: orbBreathing ? 22 + glowBoost * 40 : 12
            )
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 3.0).repeatForever(autoreverses: true),
                value: orbBreathing
            )
            .animation(reduceMotion ? nil : Motion.fade, value: orbTintBucket(currentTime))
            .shadow(
                color: DSColor.accentAmber.opacity(refreshGlow ? 0.45 : 0),
                radius: refreshGlow ? 18 : 0
            )
            .animation(.easeOut(duration: 0.6), value: refreshGlow)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(NSLocalizedString("today.orb.label", comment: ""))
            .accessibilityValue(orbValue)
            .accessibilityHint(NSLocalizedString("today.orb.hint", comment: ""))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .onAppear {
            if !reduceMotion {
                orbBreathing = true
            }
        }
        .onChange(of: viewModel.memos.count) { count in
            if count > lastMemoCount && !reduceMotion {
                orbCapturePulse.toggle()
            }
        }
    }

    /// Issue #309 W2: top action bar shown while in multi-select mode.
    /// Layout:
    ///   [Cancel]  N selected  [Share N]
    ///
    /// Share is disabled unless 2 ≤ count ≤ maxItems. The "selected" count
    /// uses an explicit `selected.count` argument rather than reading the
    /// optional state again so the view recomputes when the set changes.
    @ViewBuilder
    private func selectionToolbar(selectedIds selected: Set<UUID>) -> some View {
        let count = selected.count
        let canShare = count >= 2 && count <= CollageSnapshot.maxItems
        HStack(spacing: 12) {
            Button("取消") {
                Haptics.soft()
                selectedMemoIds = nil
            }
            .font(DSType.mono10)
            .tracking(1.0)
            .textCase(.uppercase)
            .foregroundColor(DSColor.inkSubtle)

            Spacer()

            Text(count == 0 ? "选择 memo" : "已选 \(count)")
                .font(DSType.mono10)
                .tracking(1.5)
                .textCase(.uppercase)
                .foregroundColor(DSColor.inkPrimary)

            Spacer()

            Button {
                guard canShare else { return }
                Haptics.tapConfirm()
                let memos = viewModel.memos.filter { selected.contains($0.id) }
                sharePayload = .collage(CollageSnapshot.from(memos))
                // Exit selection mode after triggering — sheet replaces the
                // foreground; keeping the toolbar around would feel orphaned.
                selectedMemoIds = nil
            } label: {
                Text(count >= 2 ? "分享 \(count) 项" : "至少 2 项")
                    .font(DSType.mono10)
                    .tracking(1.0)
                    .textCase(.uppercase)
                    .foregroundColor(canShare ? .white : DSColor.inkSubtle)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        canShare ? DSColor.amberDeep : DSColor.glassLo,
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canShare)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(DSColor.inkFaint.opacity(0.6), lineWidth: 0.5)
        )
    }

    private func orbGreeting(_ date: Date) -> String {
        NSLocalizedString(TimeOfDay.from(date).greetingKey, comment: "")
    }

    private func todayEmptySubtitle(_ date: Date) -> String {
        let key: String
        switch TimeOfDay.from(date) {
        case .morning:   key = "empty.today.subtitle.morning"
        case .afternoon: key = "empty.today.subtitle.afternoon"
        case .evening:   key = "empty.today.subtitle.evening"
        case .lateNight: key = "empty.today.subtitle.night"
        }
        return NSLocalizedString(key, comment: "")
    }

    /// Returns an integer bucket index (0–3) for the current time-of-day bucket.
    /// Used to key the tint animation so crossfades fire only at bucket boundaries.
    private func orbTintBucket(_ date: Date) -> Int {
        TimeOfDay.from(date).bucketIndex
    }

    /// Derives a subtle ambient hue for the orb breathing glow from the time-of-day bucket.
    private func orbTint(_ date: Date) -> Color {
        TimeOfDay.from(date).tint
    }

    private func orbKicker(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        let count = viewModel.signalCount
        let signalKey = count == 1 ? "today.kicker.signal.one" : "today.kicker.signal.other"
        let signal = NSLocalizedString(signalKey, comment: "")
        let dateStr = f.string(from: date).uppercased()
        let timeStr = Self.headerTimeFmt.string(from: date)
        return "\(dateStr) · \(timeStr) · \(count) \(signal)"
    }

    /// Date + time prefix for the split kicker: "29 MAY · 14:30 · "
    private func orbKickerPrefix(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        let dateStr = f.string(from: date).uppercased()
        let timeStr = Self.headerTimeFmt.string(from: date)
        return "\(dateStr) · \(timeStr) · "
    }

    /// Signal-word suffix for the split kicker: " SIGNALS"
    private func orbKickerSuffix() -> String {
        let count = viewModel.signalCount
        let signalKey = count == 1 ? "today.kicker.signal.one" : "today.kicker.signal.other"
        let signal = NSLocalizedString(signalKey, comment: "")
        return " \(signal)"
    }

    // MARK: - InputBarV4 (variant D: Silent Press-to-Talk)
    //
    // Extracted to avoid "expression too complex" errors in body.

    @ViewBuilder
    private var inputBarV4: some View {
        InputBarV4(
            text: $draftText,
            isSubmitting: viewModel.isSubmitting,
            isLocating: viewModel.isLocating,
            pendingLocation: viewModel.pendingLocation,
            locationAuthStatus: LocationService.shared.authorizationStatus,
            isProcessingPhoto: viewModel.isProcessingPhoto,
            pendingAttachments: viewModel.pendingAttachments,
            onFetchLocation: { viewModel.fetchLocation() },
            onSetLocation: { loc in viewModel.setPendingLocation(loc) },
            onClearLocation: { viewModel.clearPendingLocation() },
            onAddPhoto: { items in
                for item in items {
                    viewModel.addPhotoAttachment(item: item)
                }
            },
            onCapturePhoto: { viewModel.startCameraCapture() },
            onRemoveAttachment: { id in viewModel.removePendingAttachment(id: id) },
            onStartVoiceRecording: { viewModel.startVoiceRecording() },
            onOpenWriteSheet: {
                Haptics.soft()
                showWriteSheet = true
            },
            onPressToTalkSend: { result in
                viewModel.addVoiceAttachment(result: result)
                let body = draftText
                draftText = ""
                viewModel.submitCombinedMemo(body: body)
                showUndoPill(for: body)
            },
            onPressToTalkTranscribe: { transcript in
                if draftText.isEmpty {
                    draftText = transcript
                } else {
                    draftText += (draftText.hasSuffix(" ") ? "" : " ") + transcript
                }
            },
            onAddFile: { viewModel.startFilePicker() },
            onSubmit: {
                let body = draftText
                draftText = ""
                viewModel.submitCombinedMemo(body: body)
                showUndoPill(for: body)
            },
            onAddPhotoAsset: nil,
            batchPhotoProgress: viewModel.batchPhotoProgress,
            batchPhotoTotal: viewModel.batchPhotoTotal,
            requestFocusToggle: orbFocusToggle
        )
    }

    // MARK: - WriteSheet Overlay (v8)
    //
    // Bottom-sheet text composer (composer.jsx:183-345). Bound to the same
    // `draftText` the inline composer uses; on save it calls the identical
    // sequence as `inputBarV4.onSubmit` — submitCombinedMemo(body:) + undo pill —
    // so there is a single persistence path, never a second one.

    @ViewBuilder
    private var writeSheetOverlay: some View {
        if showWriteSheet {
            WriteSheetView(
                text: $draftText,
                onSave: {
                    let body = draftText
                    draftText = ""
                    showWriteSheet = false
                    viewModel.submitCombinedMemo(body: body)
                    showUndoPill(for: body)
                },
                onClose: { showWriteSheet = false }
            )
            .transition(.opacity)
            .zIndex(50)
        }
    }

    // MARK: - Compile Progress Dots

    @ViewBuilder
    private func compileProgressDots(filled: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(index < filled ? DSColor.accentAmber : DSColor.glassStd)
                    .frame(width: 5, height: 5)
                    .animation(Motion.spring, value: filled)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.Empty.compileDockLocked(
            current: filled,
            remaining: max(0, 3 - filled)
        ))
    }

    // MARK: - US-021 Extracted Subviews

    /// Header bar: serif date, export button, and settings gear.
    /// US-005: background fades to frosted glass once the timeline has scrolled > 8pt.
    @ViewBuilder
    private var sidebarSection: some View {
        let isScrolled = timelineScrollOffset < -8
        // The header HStack now participates in normal layout (it owns its
        // height), with the glass/separator drawn as a `.background` behind it.
        // Previously the HStack lived inside `.overlay()` on a zero-height
        // ZStack, so it contributed 0pt to the parent VStack and the orbHero
        // below it slid up and overlapped the 56pt hero title. (#590)
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Button {
                nav.openSidebar()
            } label: {
                // Compact header when memos exist: content first, date chip only.
                // Full 56pt hero reserved for the empty-day capture prompt.
                if viewModel.memos.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(weekdayName(currentTime))
                            .font(DSType.serifDisplay56)
                            .foregroundColor(DSColor.inkPrimary)
                            .lineLimit(1)
                            .dynamicTypeSize(.xSmall ... .accessibility2)
                            .minimumScaleFactor(0.6)
                        Text(headerSubline(currentTime))
                            .font(DSType.mono10)
                            .foregroundColor(DSColor.inkSubtle)
                            .textCase(.uppercase)
                            .tracking(1.0)
                            .dynamicTypeSize(.xSmall ... .accessibility5)
                            .minimumScaleFactor(0.75)
                            .accessibilityLabel(headerSublineAccessibilityLabel(currentTime))
                    }
                } else {
                    Text(headerSubline(currentTime))
                        .font(DSType.mono10)
                        .foregroundColor(DSColor.inkSubtle)
                        .textCase(.uppercase)
                        .tracking(1.0)
                        .dynamicTypeSize(.xSmall ... .accessibility5)
                        .minimumScaleFactor(0.75)
                        .accessibilityLabel(headerSublineAccessibilityLabel(currentTime))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open navigation")
            .accessibilityHint("Opens the sidebar navigation drawer")
            .accessibilityIdentifier("sidebar-menu-button")
            .onLongPressGesture(minimumDuration: 1.5) {
                HapticFeedback.medium()
                if let entry = OnThisDayScheduler.shared.forceRefresh() {
                    viewModel.onThisDayEntry = entry
                } else {
                    HapticFeedback.warning()
                }
            }

            Spacer()

            // US-019: Export as Markdown (tap → share sheet; long-press → copy to clipboard)
            if !viewModel.memos.isEmpty {
                Button {
                    let content = MarkdownExportService.buildExportContent(
                        memos: viewModel.memos, date: Date(),
                        summary: viewModel.dailyPageSummary
                    )
                    let df = DateFormatter()
                    df.dateFormat = "yyyy-MM-dd"
                    df.locale = Locale(identifier: "en_US_POSIX")
                    df.timeZone = AppSettings.currentTimeZone()
                    let dateString = df.string(from: Date())
                    do {
                        let url = try MarkdownExportService.writeExportFile(
                            content: content, dateString: dateString
                        )
                        exportFileURL = url
                        showExportSheet = true
                        Haptics.tapConfirm()
                    } catch {
                        Haptics.warn()
                        bannerCenter.show(AppBannerModel(
                            kind: .error,
                            title: NSLocalizedString("export.error.title", comment: ""),
                            autoDismiss: true
                        ))
                        DayPageLogger.shared.error("TodayView: export failed: \(error)")
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(DSType.bodySM)
                        .foregroundColor(DSColor.inkMuted)
                        .frame(width: 28, height: 28)
                        .background(DSColor.glassStd)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(DSColor.glassRim, lineWidth: 0.5))
                        .clipShape(Circle())
                        .scaleEffect(exportHintPulse ? 1.12 : 1)
                        .shadow(color: DSColor.accentAmber.opacity(exportHintPulse ? 0.4 : 0), radius: exportHintPulse ? 8 : 0)
                        .animation(reduceMotion ? nil : Motion.spring, value: exportHintPulse)
                }
                .accessibilityLabel(NSLocalizedString("export.action.title", comment: ""))
                .accessibilityHint(NSLocalizedString("export.action.hint", comment: ""))
                .accessibilityIdentifier("export-markdown-button")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 6 }
                .onAppear {
                    guard !UserDefaults.standard.bool(forKey: AppSettings.Keys.exportLongPressHintShown),
                          !reduceMotion,
                          !viewModel.memos.isEmpty else { return }
                    UserDefaults.standard.set(true, forKey: AppSettings.Keys.exportLongPressHintShown)
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(0.8))
                        Haptics.soft()
                        withAnimation(Motion.spring) { exportHintPulse = true }
                        try? await Task.sleep(for: .seconds(0.5))
                        withAnimation(Motion.spring) { exportHintPulse = false }
                    }
                }
                .onLongPressGesture(minimumDuration: 0.5) {
                    let content = MarkdownExportService.buildExportContent(
                        memos: viewModel.memos, date: Date(),
                        summary: viewModel.dailyPageSummary
                    )
                    UIPasteboard.general.string = content
                    Haptics.medium()
                    Haptics.success()
                    bannerCenter.show(AppBannerModel(
                        kind: .info,
                        title: NSLocalizedString("export.copied.title", comment: ""),
                        autoDismiss: true
                    ))
                }
            }

            Button {
                Haptics.soft()
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(DSType.bodySM)
                    .foregroundColor(DSColor.inkMuted)
                    .frame(width: 28, height: 28)
                    .background(DSColor.glassStd)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(DSColor.glassRim, lineWidth: 0.5))
                    .clipShape(Circle())
            }
            .accessibilityLabel("Settings")
            .accessibilityHint("Opens app settings")
            .accessibilityIdentifier("settings-gear-button")
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 6 }
        }
        .padding(.horizontal, 14)
        .padding(.top, viewModel.memos.isEmpty ? 16 : 10)
        .padding(.bottom, viewModel.memos.isEmpty ? 10 : 6)
        .animation(reduceMotion ? nil : Motion.fade, value: viewModel.memos.isEmpty)
        .onReceive(headerTimer) { date in
            currentTime = date
        }
        .frame(maxWidth: .infinity)
        // US-005: frosted glass + separator fade in behind the header once the
        // timeline scrolls > 8pt. Drawn as a background so it never affects the
        // header's intrinsic height (the cause of the old overlap bug). (#590)
        .background(alignment: .bottom) {
            ZStack(alignment: .bottom) {
                if isScrolled {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Rectangle()
                                .fill(DSColor.bgWarm.opacity(0.78))
                        )
                    Rectangle()
                        .fill(DSColor.borderSubtle)
                        .frame(height: 0.5)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isScrolled)
        }
    }

    /// Scrollable timeline: daily page card, skeleton, memo cards, history supplement.
    @ViewBuilder
    private var timelineSection: some View {
        ScrollViewReader { proxy in
        ScrollView {
            // US-005: Offset tracker — reads the scroll position relative to the
            // named coordinate space so the header bar can go glassy on scroll.
            GeometryReader { geo in
                Color.clear
                    .preference(
                        key: ScrollOffsetPreferenceKey.self,
                        value: geo.frame(in: .named("todayScroll")).minY
                    )
            }
            .frame(height: 0)

            LazyVStack(spacing: 8) {
                // Invisible anchor: scrollTo("timelineTop") brings the list to the very top.
                Color.clear.frame(height: 0).id("timelineTop")

                // Museum-aesthetic "AI · 今日一句" — restrained one-liner pinned
                // at the very top once the day has a compiled summary.
                if let summary = viewModel.dailyPageSummary,
                   !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    AISummaryCard(summary: summary, onTap: { Haptics.tapConfirm(); showDailyPage = true })
                        .padding(.horizontal, 20)
                        .padding(.bottom, 4)
                        .transition(.opacity)
                        .onLongPressGesture(minimumDuration: 0.4) {
                            UIPasteboard.general.string = summary
                            Haptics.tapConfirm()
                            bannerCenter.show(AppBannerModel(
                                kind: .info,
                                title: NSLocalizedString("today.summary.copied", comment: ""),
                                autoDismiss: true
                            ))
                        }
                        .accessibilityAction(named: Text("Copy summary")) {
                            UIPasteboard.general.string = summary
                            Haptics.tapConfirm()
                            bannerCenter.show(AppBannerModel(
                                kind: .info,
                                title: NSLocalizedString("today.summary.copied", comment: ""),
                                autoDismiss: true
                            ))
                        }
                }

                if viewModel.isDailyPageCompiled {
                    swipeableDailyPageCard
                        .padding(.horizontal, 20)
                        .shadow(
                            color: DSColor.accentAmber.opacity(compileRevealGlow ? 0.5 : 0),
                            radius: compileRevealGlow ? 20 : 0
                        )
                        .scaleEffect(reduceMotion ? 1 : (compileRevealGlow ? 1.0 : 0.97))
                        .animation(.easeOut(duration: 0.7), value: compileRevealGlow)
                        .transition(.scale(scale: 0.95).combined(with: .opacity))
                        .animation(Motion.spring, value: viewModel.isDailyPageCompiled)
                }

                if viewModel.loadState == .loading && viewModel.memos.isEmpty {
                    MemoListSkeleton(count: skeletonCardCount)
                        .padding(.horizontal, 20)
                        .transition(.opacity)
                }

                if viewModel.memos.isEmpty && viewModel.loadState == .ready {
                    let hasOnboarded = UserDefaults.standard.bool(forKey: AppSettings.Keys.hasOnboarded)
                    if !hasOnboarded {
                        EmptyStateView.todayBlank(ctaAction: { orbFocusToggle.toggle() }, subtitleOverride: todayEmptySubtitle(currentTime))
                            .padding(.top, 48)
                            .padding(.horizontal, 20)
                    } else {
                        fallbackContentView
                            .padding(.top, 24)
                    }
                } else {
                    ForEach(Array(viewModel.memos.enumerated()), id: \.element.id) { idx, memo in
                        TimelineRow(
                            memo: memo,
                            isLast: idx == viewModel.memos.count - 1,
                            onDelete: {
                                undoText = nil
                                undoTask?.cancel()
                                viewModel.deleteMemo(memo)
                            },
                            onPin: {
                                if memo.pinnedAt != nil {
                                    viewModel.unpinMemo(memo)
                                } else {
                                    viewModel.pinMemo(memo)
                                }
                            },
                            onRetranscribe: { m, att in viewModel.retranscribe(memo: m, attachment: att) },
                            onShare: {
                                sharePayload = SharePayload.auto(from: memo)
                            },
                            onShareAsQuote: {
                                let df = DateFormatter()
                                df.dateFormat = "yyyy-MM-dd"
                                var attrib = df.string(from: memo.created)
                                if let loc = memo.location?.name, !loc.isEmpty {
                                    attrib += " · " + loc
                                }
                                sharePayload = .quote(QuoteSnapshot(
                                    text: memo.body,
                                    attribution: attrib
                                ))
                            },
                            onEnterSelectionMode: {
                                Haptics.tapConfirm()
                                selectedMemoIds = [memo.id]
                            },
                            isSelectionMode: isInSelectionMode,
                            isSelected: selectedMemoIds?.contains(memo.id) ?? false,
                            onToggleSelection: {
                                guard var set = selectedMemoIds else { return }
                                if set.contains(memo.id) {
                                    set.remove(memo.id)
                                } else if set.count < CollageSnapshot.maxItems {
                                    set.insert(memo.id)
                                } else {
                                    Haptics.warn()
                                    return
                                }
                                selectedMemoIds = set
                            },
                            onOpen: { openedMemoID = memo.id }
                        )
                        .offset(x: idx == 0 ? memoCardHintOffset : 0)
                        .onAppear {
                            guard idx == 0,
                                  !UserDefaults.standard.bool(forKey: AppSettings.Keys.memoSwipeHintShown),
                                  !reduceMotion,
                                  !isInSelectionMode else { return }
                            UserDefaults.standard.set(true, forKey: AppSettings.Keys.memoSwipeHintShown)
                            Task { @MainActor in
                                try? await Task.sleep(for: .seconds(0.6))
                                withAnimation(Motion.spring) { memoCardHintOffset = -28 }
                                Haptics.soft()
                                try? await Task.sleep(for: .seconds(0.45))
                                withAnimation(Motion.spring) { memoCardHintOffset = 28 }
                                try? await Task.sleep(for: .seconds(0.35))
                                withAnimation(Motion.spring) { memoCardHintOffset = 0 }
                            }
                        }
                        .padding(.horizontal, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }

                // Museum-aesthetic inline "unlock today's page" placeholder —
                // shown once the day has memos but hasn't been compiled and is
                // still short of the threshold that triggers AI compilation.
                if !viewModel.memos.isEmpty
                    && !viewModel.isDailyPageCompiled
                    && viewModel.memos.count < 3 {
                    CompileUnlockCard(memoCount: viewModel.memos.count, onTap: { orbFocusToggle.toggle() })
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                        .transition(.opacity)
                }

                historySupplement

                if viewModel.loadState == .loading && !viewModel.memos.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView().tint(DSColor.inkSubtle)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }

                if let error = viewModel.errorMessage {
                    Text(error)
                        .bodySMStyle()
                        .foregroundColor(DSColor.error)
                        .padding(.horizontal, 20)
                }

                Spacer(minLength: 16)
            }
            .padding(.top, 12)
            .shadow(
                color: DSColor.accentAmber.opacity(refreshGlow ? 0.45 : 0),
                radius: refreshGlow ? 18 : 0
            )
            .animation(.easeOut(duration: 0.6), value: refreshGlow)
        }
        .refreshable {
            await viewModel.refresh()
            Haptics.success()
            if !reduceMotion {
                refreshGlow = true
                Task {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    refreshGlow = false
                }
            }
        }
        .overlay(
            LinearGradient(
                colors: [Color.clear, DSColor.bgWarm],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 40)
            .allowsHitTesting(false),
            alignment: .bottom
        )
        .coordinateSpace(name: "todayScroll")
        .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
            timelineScrollOffset = value
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { timelineScrollProxy = proxy }
        } // end ScrollViewReader
    }

    /// Compose area: compile progress dock / compile button + input bar.
    @ViewBuilder
    private var composeSection: some View {
        Group {
            if !viewModel.isDailyPageCompiled && !viewModel.memos.isEmpty {
                if viewModel.memos.count < 3 {
                    CompileProgressDock(memoCount: viewModel.memos.count)
                        .padding(.vertical, 6)
                        .transition(
                            .asymmetric(
                                insertion: .opacity,
                                removal: .opacity.combined(with: .scale(scale: 0.9))
                            )
                        )
                } else {
                    HStack {
                        Spacer()
                        CompileFooterButton(
                            memoCount: viewModel.memos.count,
                            isCompiling: viewModel.isCompiling,
                            isVisible: true,
                            stage: compilationService.stage,
                            errorMessage: viewModel.submitError,
                            onTap: { viewModel.compile() },
                            onRetry: { viewModel.compile() }
                        )
                        .shadow(
                            color: DSColor.accentAmber.opacity(unlockGlow ? 0.5 : 0),
                            radius: unlockGlow ? 18 : 0
                        )
                        .animation(.easeOut(duration: 0.6), value: unlockGlow)
                        Spacer()
                    }
                    .padding(.bottom, 4)
                }
            }
        }
        .animation(Motion.spring, value: viewModel.memos.count)
        .onChange(of: viewModel.memos.count) { count in
            if count >= 3 && !viewModel.isDailyPageCompiled && !didCelebrateUnlock {
                didCelebrateUnlock = true
                Haptics.success()
                if !reduceMotion {
                    unlockGlow = true
                    Task {
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        unlockGlow = false
                    }
                }
            } else if (1...2).contains(count) && !viewModel.isDailyPageCompiled && count > lastMemoCount {
                // Escalating tick on 1st memo (intensity 0.55) and 2nd (intensity 0.80)
                Haptics.rigid(intensity: 0.3 + 0.25 * Double(count))
            } else if count < 3 {
                didCelebrateUnlock = false
            }
            // Celebrate streak milestone when today's first memo is added.
            if lastMemoCount == 0 && count == 1 {
                Task { @MainActor in
                    await sidebarVM.refreshRecentDaysAsync()
                    celebrateStreakIfNeeded()
                }
            }
            // Scroll to top on additions only, not deletions.
            // When the user is scrolled far into history (past the button threshold),
            // badge the scroll-to-top button instead of jumping them away from context.
            if count > lastMemoCount {
                if timelineScrollOffset < -240 {
                    hasNewContentAboveFold = true
                    Haptics.soft()
                } else if let proxy = timelineScrollProxy {
                    withAnimation(reduceMotion ? nil : Motion.spring) {
                        proxy.scrollTo("timelineTop", anchor: .top)
                    }
                }
            }
            lastMemoCount = count
            if viewModel.loadState == .ready && count > 0 {
                skeletonCardCount = count
            }
        }
        .onChange(of: viewModel.isDailyPageCompiled) { compiled in
            if compiled && !didCelebrateCompile {
                didCelebrateCompile = true
                Haptics.success()
                if !reduceMotion {
                    compileRevealGlow = true
                    Task {
                        try? await Task.sleep(nanoseconds: 700_000_000)
                        compileRevealGlow = false
                    }
                }
            } else if !compiled {
                didCelebrateCompile = false
            }
        }

        inputBarV4
    }

    // MARK: - Helpers

    // MARK: - Streak Milestone Celebration

    private static let streakMilestones: [Int] = [3, 7, 14, 30, 100, 365]

    private func milestoneEncouragement(for n: Int) -> String {
        switch n {
        case 3:   return NSLocalizedString("today.streak.milestone.subtitle.3",   comment: "")
        case 7:   return NSLocalizedString("today.streak.milestone.subtitle.7",   comment: "")
        case 14:  return NSLocalizedString("today.streak.milestone.subtitle.14",  comment: "")
        case 30:  return NSLocalizedString("today.streak.milestone.subtitle.30",  comment: "")
        case 100: return NSLocalizedString("today.streak.milestone.subtitle.100", comment: "")
        case 365: return NSLocalizedString("today.streak.milestone.subtitle.365", comment: "")
        default:  return NSLocalizedString("today.streak.milestone.subtitle.365", comment: "")
        }
    }

    private func shownMilestones() -> Set<Int> {
        let raw = UserDefaults.standard.string(forKey: AppSettings.Keys.streakMilestonesShown) ?? ""
        return Set(raw.split(separator: ",").compactMap { Int($0) })
    }

    private func markMilestoneShown(_ n: Int) {
        var shown = shownMilestones()
        shown.insert(n)
        UserDefaults.standard.set(shown.map(String.init).joined(separator: ","),
                                  forKey: AppSettings.Keys.streakMilestonesShown)
    }

    private func celebrateStreakIfNeeded() {
        let streak = sidebarVM.currentStreak
        guard let milestone = Self.streakMilestones.first(where: { $0 == streak }) else { return }
        guard !shownMilestones().contains(milestone) else { return }

        markMilestoneShown(milestone)
        Haptics.success()
        if !reduceMotion {
            orbCapturePulse.toggle()
            refreshGlow = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                refreshGlow = false
            }
        }
        let title = String(format: NSLocalizedString("today.streak.milestone.title", comment: ""), milestone)
        bannerCenter.show(AppBannerModel(
            kind: .info,
            title: title,
            subtitle: milestoneEncouragement(for: milestone),
            autoDismiss: true
        ))
    }

    // US-009: Show undo pill for 5 seconds after submitting a memo.
    private func showUndoPill(for text: String) {
        guard !text.isEmpty else { return }
        // Clear delete undo pill so the two never stack
        viewModel.lastDeletedMemo = nil
        undoTask?.cancel()
        undoText = text
        undoTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            undoText = nil
        }
    }

    // US-006: Clear draft when it's more than 30 days old.
    private func clearDraftIfExpired() {
        guard !draftText.isEmpty, draftDate > 0 else { return }
        let age = Date().timeIntervalSince1970 - draftDate
        if age > 30 * 24 * 3600 {
            draftText = ""
            draftDate = 0
        }
    }

    private func showDraftRestoredBannerIfNeeded() {
        guard !draftRestoredBannerShown, !draftText.isEmpty else { return }
        draftRestoredBannerShown = true
        bannerCenter.show(AppBannerModel(
            kind: .info,
            title: "恢复了未发送的草稿",
            autoDismiss: true
        ))
    }

    private func updateVoiceQueueBanner(count: Int) {
        if count > 0 {
            bannerCenter.show(AppBannerModel(
                kind: .info,
                title: "你有 \(count) 条语音待转写",
                autoDismiss: false
            ))
        } else if bannerCenter.currentBanner?.title.contains("语音待转写") == true {
            bannerCenter.dismiss()
        }
    }

    private static let weekdayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    private static let headerDateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    private static let headerTimeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    private func weekdayName(_ date: Date) -> String {
        Self.weekdayFmt.string(from: date)
    }

    private func headerSubline(_ date: Date) -> String {
        let count = viewModel.memos.count
        let dateStr = Self.headerDateFmt.string(from: date)

        // Notes segment (empty-state shows time instead of count).
        var parts: [String]
        if count == 0 {
            parts = [dateStr, Self.headerTimeFmt.string(from: date)]
        } else {
            let notesKey = count == 1 ? "today.subline.notes.one" : "today.subline.notes.other"
            let notesStr = String(format: NSLocalizedString(notesKey, comment: ""), count)
            parts = [dateStr, notesStr]
        }

        // Museum-aesthetic subline: append today's weather + place when known.
        // Sourced from existing memos — no extra network/location fetch (M1 is UI-only).
        // e.g. "MAY 28 · 2 NOTES · 28° · VIENTIANE"
        if let weather = todayWeatherShort() {
            parts.append(weather)
        }
        if let place = todayPlaceShort() {
            parts.append(place)
        }
        return parts.joined(separator: "  ·  ")
    }

    /// Comma-separated version of the header subline for VoiceOver.
    /// e.g. "May 28, 2 notes, 28°, Vientiane"
    private func headerSublineAccessibilityLabel(_ date: Date) -> String {
        let count = viewModel.memos.count
        let dateStr = Self.headerDateFmt.string(from: date)
        var parts: [String]
        if count == 0 {
            parts = [dateStr, Self.headerTimeFmt.string(from: date)]
        } else {
            let notesKey = count == 1 ? "today.subline.notes.one" : "today.subline.notes.other"
            let notesStr = String(format: NSLocalizedString(notesKey, comment: ""), count)
            parts = [dateStr, notesStr]
        }
        if let weather = todayWeatherShort() { parts.append(weather) }
        if let place = todayPlaceShort() { parts.append(place) }
        return parts.joined(separator: ", ")
    }

    /// Today's weather temperature, taken from the most recent memo that carries
    /// a weather string (e.g. "28° · 多云" → "28°"). Returns nil when unknown.
    private func todayWeatherShort() -> String? {
        for memo in viewModel.memos {  // memos is already newest-first
            if let w = memo.weather?.trimmingCharacters(in: .whitespaces), !w.isEmpty {
                // Keep only the temperature token ("28° · 多云" → "28°").
                let temp = w.split(separator: "·").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? w
                return temp.isEmpty ? nil : temp
            }
        }
        return nil
    }

    /// Today's place name, taken from the most recent memo carrying a location.
    private func todayPlaceShort() -> String? {
        for memo in viewModel.memos {  // memos is already newest-first
            if let name = memo.location?.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
                return name
            }
        }
        return nil
    }
}

// MARK: - OnThisDayNavTarget

private struct OnThisDayNavTarget: Identifiable {
    let dateString: String
    var id: String { dateString }
}

// MARK: - CompilationFailedBanner

/// Red banner shown when background compilation failed after all retries.
/// Delegates to the shared DSBanner so the visual language matches every
/// other banner in the app (syncBanner, LocationDraftCard header, etc.).
struct CompilationFailedBanner: View {
    let message: String
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        DSBanner(
            kind: .error,
            title: message,
            primaryAction: (label: "重试", action: onRetry),
            onDismiss: onDismiss
        )
        .padding(.horizontal, DSSpacing.pageMargin)
        .padding(.bottom, DSSpacing.xs)
    }
}

// MARK: - LocationDraftCard

/// Card shown at the top of Today View listing passively-detected visits pending user action.
struct LocationDraftCard: View {
    let drafts: [VisitDraft]
    let onConfirm: (VisitDraft) -> Void
    let onIgnore: (VisitDraft) -> Void
    let onConfirmAll: () -> Void
    let onIgnoreAll: () -> Void

    var body: some View {
        locationDraftContent
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
    }

    // MARK: - Location Draft Content

    private var locationDraftContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            draftHeader
            Divider().background(DSColor.inkFaint)
            draftRows
        }
        .background(DSColor.glassStd)
        .background(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(LinearGradient(colors: [DSColor.glassEdge, Color.clear], startPoint: .top, endPoint: .center), lineWidth: 0.6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(DSColor.glassRim, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Color(hex: "2D1E0A").opacity(0.04), radius: 1, x: 0, y: 1)
        .shadow(color: Color(hex: "2D1E0A").opacity(0.08), radius: 24, x: 0, y: 8)
    }

    // MARK: - Draft Header

    private var draftHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "location.fill")
                .font(DSType.label)
                .foregroundColor(DSColor.amberAccent)
            Text("检测到位置到达")
                .font(DSType.caption)
                .foregroundColor(DSColor.inkPrimary)
            Spacer()
            Button("全部忽略") { onIgnoreAll() }
                .font(DSType.caption)
                .foregroundColor(DSColor.inkMuted)
                .accessibilityLabel("忽略所有位置记录")
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            Button("全部确认") { onConfirmAll() }
                .font(DSType.caption)
                .foregroundColor(DSColor.amberAccent)
                .accessibilityLabel("确认所有位置记录")
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    // MARK: - Draft Rows

    private var draftRows: some View {
        ForEach(Array(drafts.enumerated()), id: \.element.id) { idx, draft in
            VStack(spacing: 0) {
                LocationDraftRow(
                    draft: draft,
                    onConfirm: { onConfirm(draft) },
                    onIgnore: { onIgnore(draft) }
                )
                if idx < drafts.count - 1 {
                    Divider()
                        .background(DSColor.inkFaint)
                        .padding(.leading, 16)
                }
            }
        }
    }
}

// MARK: - LocationDraftRow

private struct LocationDraftRow: View {
    let draft: VisitDraft
    let onConfirm: () -> Void
    let onIgnore: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "mappin.circle.fill")
                .font(DSType.headlineCaps)
                .foregroundColor(DSColor.amberAccent)

            VStack(alignment: .leading, spacing: 2) {
                Text(draft.placeName ?? "未知地点")
                    .font(DSType.caption)
                    .foregroundColor(DSColor.inkPrimary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(formatTime(draft.arrivalDate))
                        .font(DSType.mono10)
                        .foregroundColor(DSColor.inkSubtle)
                        .textCase(.uppercase)
                    if let dur = durationText {
                        Text("·")
                            .font(DSType.mono10)
                            .foregroundColor(DSColor.inkSubtle)
                        Text(dur)
                            .font(DSType.mono10)
                            .foregroundColor(DSColor.inkSubtle)
                    }
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    onIgnore()
                } label: {
                    Image(systemName: "xmark")
                        .font(DSType.label)
                        .foregroundColor(DSColor.inkMuted)
                        .frame(width: 30, height: 30)
                        .background(DSColor.glassLo)
                        .background(.ultraThinMaterial, in: Circle())
                        .clipShape(Circle())
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .accessibilityLabel("忽略此位置")

                Button {
                    onConfirm()
                } label: {
                    Image(systemName: "checkmark")
                        .font(DSType.label)
                        .foregroundColor(.white)
                        .frame(width: 30, height: 30)
                        .background(DSColor.amberAccent)
                        .clipShape(Circle())
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .accessibilityLabel("确认此位置")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f.string(from: date)
    }

    private var durationText: String? {
        guard let dep = draft.departureDate else { return "仍在此处" }
        let secs = dep.timeIntervalSince(draft.arrivalDate)
        guard secs > 0 else { return nil }
        let mins = Int(secs / 60)
        if mins < 60 { return "停留 \(mins) 分钟" }
        let h = mins / 60; let m = mins % 60
        return m == 0 ? "停留 \(h) 小时" : "停留 \(h) 小时 \(m) 分钟"
    }
}

// MARK: - CompilationProgressBar

/// Thin progress strip shown at the top of TodayView while AI compilation runs.
struct CompilationProgressBar: View {
    let stage: CompilationStage

    private var progress: Double {
        switch stage {
        case .extracting: return 0.25
        case .compiling:  return 0.60
        case .formatting: return 0.85
        case .done:       return 1.00
        }
    }

    private var label: String {
        switch stage {
        case .extracting: return "读取记录…"
        case .compiling:  return "AI 编译中…"
        case .formatting: return "整理格式…"
        case .done:       return "完成"
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(DSColor.glassStd)
                        .frame(height: 3)
                    Capsule()
                        .fill(DSColor.accentAmber)
                        .frame(width: geo.size.width * progress, height: 3)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: progress)
                }
            }
            .frame(height: 3)

            Text(label)
                .font(DSType.mono10)
                .foregroundColor(DSColor.inkSubtle)
                .textCase(.uppercase)
                .tracking(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }
}

// MARK: - TimelineRow

/// V4: Direct card stack — no left timeline column. Cards float edge-to-edge
/// over the ambient background, letting the glass surface provide depth.
struct TimelineRow: View {
    let memo: Memo
    let isLast: Bool
    var onDelete: (() -> Void)? = nil
    var onPin: (() -> Void)? = nil
    var onRetranscribe: ((Memo, Memo.Attachment) -> Void)? = nil
    /// Issue #302: long-press → "分享为卡片"
    var onShare: (() -> Void)? = nil
    /// Issue #302: long-press → "分享为引用"
    var onShareAsQuote: (() -> Void)? = nil
    /// Issue #309 W2: long-press → "多选". Enters selection mode and
    /// seeds the selection with the long-pressed memo. nil hides the menu
    /// item (e.g. when already in selection mode).
    var onEnterSelectionMode: (() -> Void)? = nil
    /// Issue #309 W2: selection mode props. When isSelectionMode is true,
    /// the card renders with a selection indicator overlay and a tap
    /// toggles membership instead of navigating to the detail view.
    var isSelectionMode: Bool = false
    var isSelected: Bool = false
    var onToggleSelection: (() -> Void)? = nil
    /// Tap on the card body → open detail. Driven programmatically by the
    /// parent (the swipe card no longer uses a NavigationLink).
    var onOpen: (() -> Void)? = nil

    /// Drives the right-swipe MORE confirmation dialog (pin / delete / …).
    @State private var showMoreActions = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // In selection mode the inner NavigationLink must be disabled
            // (otherwise a tap routes to detail). We pass isSelectionMode
            // down so SwipeableMemoCard can mute its swipe gesture too —
            // both behaviors live on a single flag at the card root.
            SwipeableMemoCard(
                memo: memo,
                onDelete: onDelete,
                onPin: onPin,
                onShare: onShare,            // left-swipe SHARE → share-as-card
                onMore: { showMoreActions = true }, // right-swipe MORE → dialog
                // Card-body tap: in selection mode toggle membership, else open
                // detail. Both flow through the card's UIKit tap recognizer so
                // they never fight the swipe gesture's self-hit-testing host.
                onOpen: {
                    if isSelectionMode {
                        Haptics.soft()
                        onToggleSelection?()
                    } else {
                        onOpen?()
                    }
                },
                onRetranscribe: onRetranscribe,
                isSelectionMode: isSelectionMode
            )
            .frame(maxWidth: .infinity)
            // Dimmer when in selection mode but not selected — pulls focus
            // toward the picked memos without hiding the others completely.
            .opacity(isSelectionMode && !isSelected ? 0.55 : 1)
            .animation(.easeInOut(duration: 0.18), value: isSelected)
            .animation(.easeInOut(duration: 0.18), value: isSelectionMode)

            // Selection circle indicator, top-trailing.
            if isSelectionMode {
                selectionIndicator
                    .padding(.top, 14)
                    .padding(.trailing, 18)
                    .transition(.opacity)
            }
        }
        .contextMenu {
            // Hide the menu while in selection mode — long-pressing a card
            // mid-selection should not open another menu over the toolbar.
            if !isSelectionMode {
                if let onShare {
                    Button {
                        onShare()
                    } label: {
                        Label("分享为卡片", systemImage: "square.and.arrow.up.on.square")
                    }
                }
                if let onShareAsQuote {
                    Button {
                        onShareAsQuote()
                    } label: {
                        Label("分享为引用", systemImage: "quote.opening")
                    }
                }
                if let onEnterSelectionMode {
                    Button {
                        onEnterSelectionMode()
                    } label: {
                        Label("多选", systemImage: "checkmark.circle")
                    }
                }
            }
        }
        // Right-swipe MORE → fuller action set (pin / quote / delete) kept
        // out of the card's resting chrome per the content-first redesign.
        .confirmationDialog("更多", isPresented: $showMoreActions, titleVisibility: .hidden) {
            moreActionsButtons
        }
    }

    @ViewBuilder
    private var moreActionsButtons: some View {
        if let onPin {
            Button(memo.pinnedAt != nil ? "取消置顶" : "置顶") { onPin() }
        }
        if let onShareAsQuote {
            Button("分享为引用") { onShareAsQuote() }
        }
        if let onEnterSelectionMode {
            Button("多选") { onEnterSelectionMode() }
        }
        if let onDelete {
            Button("删除", role: .destructive) { onDelete() }
        }
        Button("取消", role: .cancel) { }
    }

    private var selectionIndicator: some View {
        ZStack {
            Circle()
                .fill(isSelected ? DSColor.amberDeep : Color.white.opacity(0.9))
                .frame(width: 26, height: 26)
                .shadow(color: Color.black.opacity(0.15), radius: 3, x: 0, y: 1)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(DSType.caption)
                    .foregroundColor(.white)
            } else {
                Circle()
                    .strokeBorder(DSColor.inkSubtle.opacity(0.4), lineWidth: 1.5)
                    .frame(width: 26, height: 26)
            }
        }
        .accessibilityLabel(isSelected ? "已选中" : "未选中")
    }
}

// US-005: PreferenceKey used to propagate the ScrollView offset up to TodayView.
private struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// ViewModifier to wrap .numericText(value:) which requires iOS 17+
private struct NumericTextContentTransition: ViewModifier {
    let value: Double
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content
                .contentTransition(reduceMotion ? .identity : .numericText(value: value))
        } else {
            content
                .contentTransition(.identity)
        }
    }
}
