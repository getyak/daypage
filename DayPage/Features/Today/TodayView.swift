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

    // US-009: Text to restore if undo is tapped within 5s of submit.
    @State private var undoText: String? = nil
    @State private var undoTask: Task<Void, Never>? = nil

    // US-010: First-run tutorial overlay
    @State private var showTutorial: Bool = false

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
                    // MARK: Header — serif date + right-side controls
                    // Note: animation on this VStack drives the orbHero enter/exit transition.
                    // `alignment: .firstTextBaseline` puts the 28pt settings gear
                    // on the same cap-height baseline as the "Tuesday" serif title
                    // rather than floating mid-row. (#today-polish)
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        // Left: serif weekday + mono date subline; tap → open sidebar
                        Button {
                            nav.openSidebar()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(weekdayName(currentTime))
                                    .font(DSType.serifDisplay32)
                                    .foregroundColor(DSColor.inkPrimary)
                                Text(headerSubline(currentTime))
                                    .font(DSType.mono10)
                                    .foregroundColor(DSColor.inkSubtle)
                                    .textCase(.uppercase)
                                    .tracking(1.0)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open navigation")
                        .accessibilityIdentifier("sidebar-menu-button")
                        // Long press on the date header → force-refresh On This Day
                        .onLongPressGesture(minimumDuration: 1.5) {
                            HapticFeedback.medium()
                            if let entry = OnThisDayScheduler.shared.forceRefresh() {
                                viewModel.onThisDayEntry = entry
                            } else {
                                HapticFeedback.warning()
                            }
                        }

                        Spacer()

                        // Right: settings gear (28pt glass circle).
                        // alignmentGuide pulls the gear's vertical center onto
                        // the serif title's first-text-baseline so it doesn't
                        // float below the cap-height of "Tuesday".
                        //
                        // Math (DSType.serifDisplay32): the circle's geometric
                        // center sits ~14pt below its top edge. The serif's
                        // first-text-baseline sits ~8pt below cap-height. The
                        // +6 offset slides the circle so its center lands on
                        // the title's cap-height midline rather than below the
                        // baseline. Empirically tuned — revisit if
                        // serifDisplay32's point size or the 28pt circle
                        // diameter changes.
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.system(size: 14, weight: .regular))
                                .foregroundColor(DSColor.inkMuted)
                                .frame(width: 28, height: 28)
                                .background(DSColor.glassStd)
                                .background(.ultraThinMaterial, in: Circle())
                                .overlay(Circle().strokeBorder(DSColor.glassRim, lineWidth: 0.5))
                                .clipShape(Circle())
                        }
                        .accessibilityLabel("Settings")
                        .accessibilityIdentifier("settings-gear-button")
                        .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 6 }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 12)
                    .onReceive(headerTimer) { date in
                        currentTime = date
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
                            .animation(.easeOut(duration: 0.22), value: viewModel.memos.isEmpty)
                    }

                    // MARK: Timeline
                    // Plain ScrollView — no GeometryReader. The previous wrapper
                    // (`GeometryReader { ScrollView { ... }.frame(minHeight: geo.size.height * 0.75) }
                    // .frame(maxHeight: geo.size.height)`) created a layout
                    // feedback loop: GeometryReader sized itself from the parent
                    // VStack's leftover space, then constrained the ScrollView's
                    // intrinsic content to ≥75% of that space. When sibling rows
                    // (banners, orb hero, compile area, input bar) republished
                    // their @Published state, the VStack's leftover changed,
                    // GeometryReader handed back a new size, and the whole tree
                    // measured again — manifesting as a 2–4 s page-wide jitter
                    // on real devices. (#258)
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            // OnThisDayCard removed — relocation tracked in follow-up issue (US-015)
                            // WeeklyRecapSection removed — relocation tracked in follow-up issue (US-015)

                            // Daily Page entry card (post-compile). Auto-compile runs
                            // silently on load; users swipe left to reveal a manual
                            // "重新编译" action when the AI output needs a redo.
                            if viewModel.isDailyPageCompiled {
                                swipeableDailyPageCard
                                    .padding(.horizontal, 20)
                            }

                            // Memo cards (reverse-chronological)
                            if viewModel.memos.isEmpty && !viewModel.isLoading {
                                let hasOnboarded = UserDefaults.standard.bool(forKey: AppSettings.Keys.hasOnboarded)
                                if !hasOnboarded {
                                    EmptyStateView.todayBlank {
                                        // focus is implicit — the input bar is always visible below
                                    }
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
                                        onDelete: { viewModel.deleteMemo(memo) },
                                        onPin: {
                                            if memo.pinnedAt != nil {
                                                viewModel.unpinMemo(memo)
                                            } else {
                                                viewModel.pinMemo(memo)
                                            }
                                        },
                                        onRetranscribe: { m, att in viewModel.retranscribe(memo: m, attachment: att) }
                                    )
                                    .padding(.horizontal, 20)
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                                }
                            }

                            // History supplement — shown at the bottom when today
                            // already has memos, so the user can still scroll down
                            // to yesterday's page or the weekly recap. (#US-016)
                            historySupplement

                            // Loading indicator
                            if viewModel.isLoading {
                                HStack {
                                    Spacer()
                                    ProgressView()
                                        .tint(DSColor.onSurfaceVariant)
                                    Spacer()
                                }
                                .padding(.vertical, 20)
                            }

                            // Load error message
                            if let error = viewModel.errorMessage {
                                Text(error)
                                    .bodySMStyle()
                                    .foregroundColor(DSColor.error)
                                    .padding(.horizontal, 20)
                            }

                            Spacer(minLength: 16)
                        }
                        .padding(.top, 12)
                    }
                    // US-010: Vignette gradient at the bottom edge fades timeline
                    // content behind the composer dock, so cards appear to recede
                    // rather than abruptly stopping at the input bar boundary.
                    // Note: overlay+allowsHitTesting(false) preserves scroll gestures;
                    // .mask() on a ScrollView blocks hit-testing and breaks scrolling.
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // MARK: Compile Area
                    // When < 3 memos: show a single-line mono dock hint
                    // ("N / 3 memos · M more to unlock") sitting directly above
                    // the input bar — it belongs to the composer dock, not to
                    // the timeline. When ≥ 3 memos: show the compile button.
                    // Hidden entirely once today's page is compiled.
                    if !viewModel.isDailyPageCompiled && !viewModel.memos.isEmpty {
                        if viewModel.memos.count < 3 {
                            Text(L10n.Empty.compileDockLocked(
                                current: viewModel.memos.count,
                                remaining: max(0, 3 - viewModel.memos.count)
                            ))
                                .font(DSType.mono10)
                                .foregroundColor(DSColor.inkSubtle)
                                .textCase(.uppercase)
                                .tracking(0.8)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .accessibilityIdentifier("compile-dock-hint")
                        } else {
                            HStack {
                                Spacer()
                                CompileFooterButton(
                                    memoCount: viewModel.memos.count,
                                    isCompiling: viewModel.isCompiling,
                                    isVisible: true,
                                    stage: CompilationService.shared.stage,
                                    errorMessage: viewModel.submitError,
                                    onTap: { viewModel.compile() },
                                    onRetry: { viewModel.compile() }
                                )
                                Spacer()
                            }
                            .padding(.bottom, 4)
                        }
                    }

                    // MARK: Input Bar — single canonical surface (V4).
                    // V1/V2/V3 were removed in the Capture v2 cleanup; the
                    // variant switch was a feature-flag carcass keeping four
                    // parallel implementations alive. Now the input bar is
                    // just the input bar.
                    inputBarV4
                }
                // US-009: Undo pill shown for 5s after memo submit
                .overlay(alignment: .bottom) {
                    if let text = undoText {
                        UndoPillView {
                            draftText = text
                            undoText = nil
                            undoTask?.cancel()
                        }
                        .padding(.bottom, 96)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(Motion.rise, value: undoText != nil)
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
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
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
            .animation(.easeInOut(duration: 0.22), value: showTutorial)
            .sheet(isPresented: $showAuthSheet) {
                AuthView()
            }
            // iCloud migration progress sheet — shown during vault migration
            .sheet(isPresented: $migrationService.isMigrating) {
                MigrationProgressSheet(service: migrationService)
            }
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
        Text("Sync your journal across devices →")
            .font(DSType.bodySM)
            .foregroundColor(DSColor.inkMuted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 20)
            .background(DSColor.glassStd)
            .background(.ultraThinMaterial)
            .overlay(Rectangle().frame(height: 0.5).foregroundColor(DSColor.glassRim), alignment: .bottom)
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onEnded { value in
                        if value.translation.height < -10 {
                            withAnimation { showSyncBanner = false }
                            UserDefaults.standard.set(Date(), forKey: AppSettings.Keys.lastSyncBannerDate)
                        }
                    }
            )
            .onTapGesture {
                showAuthSheet = true
            }
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
            EmptyStateView.todayNoSignals()
                .padding(.horizontal, 20)
        }
    }

    // MARK: - Yesterday Section (shared by fallback and supplement paths)

    @ViewBuilder
    private func yesterdaySection(_ page: DailyPageModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("YESTERDAY")
                .font(DSType.mono10)
                .tracking(1.0)
                .foregroundColor(DSColor.inkSubtle)
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
        if !viewModel.memos.isEmpty && !viewModel.isLoading && !viewModel.timelineSections.isEmpty {
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
            Text("EARLIER")
                .font(DSType.mono10)
                .tracking(1.0)
                .foregroundColor(DSColor.inkSubtle)
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
                        .font(.custom("Inter-Medium", size: 13))
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
                        withAnimation(Motion.spring) {
                            dailyPageRevealed = false
                        }
                    } else {
                        showDailyPage = true
                    }
                }
            )
            .offset(x: (dailyPageRevealed ? -80 : 0) + dailyPageDrag)
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
    }

    // MARK: - Day Orb Hero

    /// Hero region shown at the top of Today: serif date + mono signal kicker + 200pt Day Orb.
    @ViewBuilder
    private var orbHero: some View {
        VStack(spacing: 6) {
            Text(weekdayName(currentTime))
                .font(DSType.serifDisplay32)
                .foregroundColor(DSColor.inkPrimary)

            Text(orbKicker(currentTime))
                .font(DSType.mono10)
                .foregroundColor(DSColor.inkSubtle)
                .textCase(.uppercase)
                .tracking(1.0)

            Button {
                // TODO: open Day Drawer (follow-up story)
            } label: {
                DayOrbView(signalCount: viewModel.signalCount, size: 140)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private func orbKicker(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        let count = viewModel.signalCount
        let plural = count == 1 ? "SIGNAL" : "SIGNALS"
        return "\(f.string(from: date).uppercased()) · \(count) \(plural)"
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
            batchPhotoProgress: viewModel.batchPhotoProgress,
            batchPhotoTotal: viewModel.batchPhotoTotal
        )
    }

    // MARK: - Helpers

    // US-009: Show undo pill for 5 seconds after submitting a memo.
    private func showUndoPill(for text: String) {
        guard !text.isEmpty else { return }
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
        switch count {
        case 0:
            return "\(dateStr)  ·  \(Self.headerTimeFmt.string(from: date))"
        case 1:
            return "\(dateStr)  ·  1 note"
        default:
            return "\(dateStr)  ·  \(count) notes"
        }
    }
}

// MARK: - OnThisDayNavTarget

private struct OnThisDayNavTarget: Identifiable {
    let dateString: String
    var id: String { dateString }
}

// MARK: - CompilationFailedBanner

/// Red banner shown when background compilation failed after all retries.
struct CompilationFailedBanner: View {
    let message: String
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(DSColor.errorRed)
                .font(.system(size: 14))
            Text(message)
                .font(DSType.bodySM)
                .foregroundColor(DSColor.inkPrimary)
                .lineLimit(2)
            Spacer()
            Button("重试") {
                onRetry()
            }
            .font(DSType.caption)
            .foregroundColor(DSColor.errorRed)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DSColor.inkMuted)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(DSColor.errorSoft)
        .background(.ultraThinMaterial)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DSColor.glassRim, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
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
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DSColor.amberAccent)
            Text("检测到位置到达")
                .font(DSType.caption)
                .foregroundColor(DSColor.inkPrimary)
            Spacer()
            Button("全部忽略") { onIgnoreAll() }
                .font(DSType.caption)
                .foregroundColor(DSColor.inkMuted)
            Button("全部确认") { onConfirmAll() }
                .font(DSType.caption)
                .foregroundColor(DSColor.amberAccent)
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
                .font(.system(size: 18))
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
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DSColor.inkMuted)
                        .frame(width: 30, height: 30)
                        .background(DSColor.glassLo)
                        .background(.ultraThinMaterial, in: Circle())
                        .clipShape(Circle())
                }

                Button {
                    onConfirm()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 30, height: 30)
                        .background(DSColor.amberAccent)
                        .clipShape(Circle())
                }
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

// MARK: - TimelineRow

/// V4: Direct card stack — no left timeline column. Cards float edge-to-edge
/// over the ambient background, letting the glass surface provide depth.
struct TimelineRow: View {
    let memo: Memo
    let isLast: Bool
    var onDelete: (() -> Void)? = nil
    var onPin: (() -> Void)? = nil
    var onRetranscribe: ((Memo, Memo.Attachment) -> Void)? = nil

    var body: some View {
        SwipeableMemoCard(memo: memo, onDelete: onDelete, onPin: onPin, onRetranscribe: onRetranscribe)
            .frame(maxWidth: .infinity)
    }
}
