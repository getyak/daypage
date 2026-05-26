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

    /// Toggled each time the Day Orb is tapped to focus the composer input.
    @State private var orbFocusToggle: Bool = false

    private var isInSelectionMode: Bool { selectedMemoIds != nil }

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
                        .accessibilityHint("Opens the sidebar navigation drawer")
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
                        .accessibilityHint("Opens app settings")
                        .accessibilityIdentifier("settings-gear-button")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 6 }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 12)
                    .onReceive(headerTimer) { date in
                        currentTime = date
                    }

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

                            // Skeleton placeholder while the initial load is in flight
                            if viewModel.loadState == .loading && viewModel.memos.isEmpty {
                                MemoListSkeleton()
                                    .padding(.horizontal, 20)
                                    .transition(.opacity)
                            }

                            // Memo cards (reverse-chronological)
                            if viewModel.memos.isEmpty && viewModel.loadState == .ready {
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
                                        onDelete: {
                                            // Clear submit undo pill so the two never stack
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
                                            // Smart default — auto picks photo/voice/memo
                                            // based on attachments (issue #309 W1-②).
                                            sharePayload = SharePayload.auto(from: memo)
                                        },
                                        onShareAsQuote: {
                                            // Build attribution from date + location.
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
                                                // At cap — buzz to let the user know and skip the toggle.
                                                Haptics.warn()
                                                return
                                            }
                                            selectedMemoIds = set
                                        }
                                    )
                                    .padding(.horizontal, 20)
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                                }
                            }

                            // History supplement — shown at the bottom when today
                            // already has memos, so the user can still scroll down
                            // to yesterday's page or the weekly recap. (#US-016)
                            historySupplement

                            // Skeleton while reloading with existing memos visible
                            if viewModel.loadState == .loading && !viewModel.memos.isEmpty {
                                HStack {
                                    Spacer()
                                    ProgressView()
                                        .tint(DSColor.inkSubtle)
                                    Spacer()
                                }
                                .padding(.vertical, 8)
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
                    // Motion.spring on memoCount drives the dock→button swap so
                    // the unlock moment transitions with a spring rather than cutting.
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
                                    Spacer()
                                }
                                .padding(.bottom, 4)
                            }
                        }
                    }
                    .animation(Motion.spring, value: viewModel.memos.count)
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
                // Undo pill shown for 5s after memo delete
                .overlay(alignment: .bottom) {
                    if viewModel.lastDeletedMemo != nil {
                        UndoPillView(label: "已删除 · 撤销") {
                            viewModel.undoDelete()
                        }
                        .padding(.bottom, 96)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(Motion.rise, value: viewModel.lastDeletedMemo != nil)
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

            DayOrbView(signalCount: viewModel.signalCount, size: 140) {
                Haptics.tapConfirm()
                orbFocusToggle.toggle()
            }
            .accessibilityLabel("Today's orb, \(viewModel.signalCount) signals")
            .accessibilityHint("Tap to start writing today's first note")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
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
            requestFocusToggle: orbFocusToggle,
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
            onAddPhotoAsset: nil,
            batchPhotoProgress: viewModel.batchPhotoProgress,
            batchPhotoTotal: viewModel.batchPhotoTotal,
            requestFocusToggle: orbFocusToggle
        )
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

    // MARK: - Helpers

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
                .font(.system(size: 11, weight: .medium))
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
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .accessibilityLabel("忽略此位置")

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
                onRetranscribe: onRetranscribe,
                isSelectionMode: isSelectionMode
            )
            .frame(maxWidth: .infinity)
            // Selection mode taps anywhere on the row toggle membership.
            // contentShape is the row's full bounding rect — without it the
            // glass card's rounded corners would leak taps through gaps.
            .contentShape(Rectangle())
            .onTapGesture {
                guard isSelectionMode else { return }
                Haptics.soft()
                onToggleSelection?()
            }
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
    }

    private var selectionIndicator: some View {
        ZStack {
            Circle()
                .fill(isSelected ? DSColor.amberDeep : Color.white.opacity(0.9))
                .frame(width: 26, height: 26)
                .shadow(color: Color.black.opacity(0.15), radius: 3, x: 0, y: 1)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .heavy))
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
