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

    @State private var showAccountSheet: Bool = false
    @State private var showSyncBanner: Bool = false
    @State private var showAuthSheet: Bool = false

    /// 输入栏中的草稿文本。
    @State private var draftText: String = ""

    /// Whether to show the Daily Page sheet.
    @State private var showDailyPage: Bool = false

    /// Whether to show the Settings sheet.
    @State private var showSettings: Bool = false

    /// Date string for On This Day navigation.
    @State private var onThisDayDateString: String? = nil

    /// Current time for the header timestamp (refreshed every minute).
    @State private var currentTime: Date = Date()

    /// Whether the daily page card is swiped open to reveal the recompile action.
    @State private var dailyPageRevealed: Bool = false

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
                    HStack(alignment: .top, spacing: 0) {
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
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            if let entry = OnThisDayScheduler.shared.forceRefresh() {
                                viewModel.onThisDayEntry = entry
                            } else {
                                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                            }
                        }

                        Spacer()

                        // Right: settings + account
                        HStack(spacing: 8) {
                            Button {
                                showSettings = true
                            } label: {
                                Image(systemName: "gearshape")
                                    .font(.system(size: 15, weight: .regular))
                                    .foregroundColor(DSColor.inkMuted)
                                    .frame(width: 36, height: 36)
                                    .background(DSColor.glassStd)
                                    .background(.ultraThinMaterial, in: Circle())
                                    .overlay(Circle().strokeBorder(DSColor.glassRim, lineWidth: 0.5))
                                    .clipShape(Circle())
                            }
                            .accessibilityLabel("设置")

                            if authService.session != nil {
                                Button {
                                    showAccountSheet = true
                                } label: {
                                    accountAvatar
                                }
                            }
                        }
                        .padding(.top, 4)
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
                    orbHero

                    // MARK: Timeline (75% of available space)
                    GeometryReader { geo in
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
                                    Group {
                                        if hasOnboarded {
                                            EmptyStateView.todayNoSignals()
                                        } else {
                                            EmptyStateView.todayBlank {
                                                // focus is implicit — the input bar is always visible below
                                            }
                                        }
                                    }
                                    .padding(.top, 48)
                                    .padding(.horizontal, 20)
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
                                            }
                                        )
                                        .padding(.horizontal, 20)
                                        .transition(.move(edge: .bottom).combined(with: .opacity))
                                    }
                                }

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
                            .frame(minHeight: geo.size.height * 0.75)
                        }
                        .coordinateSpace(name: "todayScroll")
                        .frame(maxHeight: geo.size.height)
                    }

                    // MARK: Compile Area
                    // Shows a locked hint when signals < 3, or the compile
                    // button when ready. Hidden once today's page is compiled.
                    if !viewModel.isDailyPageCompiled && !viewModel.memos.isEmpty {
                        HStack {
                            Spacer()
                            if viewModel.memos.count < 3 {
                                EmptyStateView.compileLocked(currentCount: viewModel.memos.count)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 8)
                            } else {
                                CompileFooterButton(
                                    memoCount: viewModel.memos.count,
                                    isCompiling: viewModel.isCompiling,
                                    isVisible: true,
                                    onTap: { viewModel.compile() }
                                )
                            }
                            Spacer()
                        }
                        .padding(.bottom, 4)
                    }

                    // MARK: Input Bar — single canonical surface (V4).
                    // V1/V2/V3 were removed in the Capture v2 cleanup; the
                    // variant switch was a feature-flag carcass keeping four
                    // parallel implementations alive. Now the input bar is
                    // just the input bar.
                    inputBarV4
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
            .navigationDestination(for: UUID.self) { memoID in
                if let memo = viewModel.memos.first(where: { $0.id == memoID }) {
                    MemoDetailView(memo: memo, vm: viewModel)
                }
            }
            .onAppear {
                viewModel.load()
                updateVoiceQueueBanner(count: voiceQueue.pendingCount)
            }
            .onChange(of: voiceQueue.pendingCount) { count in
                updateVoiceQueueBanner(count: count)
            }
            // Reload when app returns from background to correct the active date (midnight crossover).
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    viewModel.load()
                }
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
            .bannerOverlay()
            .sheet(isPresented: $showAccountSheet) {
                AccountSheet()
            }
            .sheet(isPresented: $showAuthSheet) {
                AuthView()
            }
            // iCloud migration progress sheet — shown during vault migration
            .sheet(isPresented: $migrationService.isMigrating) {
                MigrationProgressSheet(service: migrationService)
            }
            .onAppear {
                evaluateSyncBanner()
            }
            .onChange(of: authService.session) { _ in
                evaluateSyncBanner()
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

    // MARK: - Account Avatar

    private var accountAvatar: some View {
        let email = authService.session?.user.email ?? ""
        let initial = email.first.map { String($0).uppercased() } ?? "?"
        return ZStack {
            Circle()
                .fill(DSColor.amberSoft)
                .frame(width: 36, height: 36)
                .overlay(Circle().strokeBorder(DSColor.amberRim, lineWidth: 0.5))
            Text(initial)
                .font(DSType.labelSM)
                .foregroundColor(DSColor.amberDeep)
        }
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
                    Text("重新编译")
                        .font(.custom("Inter-Medium", size: 13))
                        .foregroundColor(.white)
                        .frame(width: 80)
                        .frame(maxHeight: .infinity)
                        .background(DSColor.accentAmber)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("重新编译")
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
                DayOrbView(signalCount: viewModel.signalCount, size: 200)
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
            }
        )
    }

    // MARK: - Helpers

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

    private func weekdayName(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f.string(from: date)
    }

    private func headerSubline(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d · HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        let count = viewModel.memos.count
        return "\(f.string(from: date))  ·  \(count) signals"
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

    var body: some View {
        SwipeableMemoCard(memo: memo, onDelete: onDelete, onPin: onPin)
            .frame(maxWidth: .infinity)
    }
}
