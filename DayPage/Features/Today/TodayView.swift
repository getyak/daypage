import SwiftUI
import CoreLocation

struct TodayView: View {

    @StateObject private var viewModel = TodayViewModel()
    @StateObject private var passiveLocation = PassiveLocationService.shared
    @StateObject private var bannerCenter = BannerCenter.shared
    @StateObject private var voiceQueue = VoiceAttachmentQueue.shared

    /// The draft text in the input bar.
    @State private var draftText: String = ""

    /// Whether to show the Daily Page sheet.
    @State private var showDailyPage: Bool = false

    /// Whether to show the Settings sheet.
    @State private var showSettings: Bool = false

    /// Date string for On This Day navigation.
    @State private var onThisDayDateString: String? = nil

    /// Current time for the header timestamp (refreshed every minute).
    @State private var currentTime: Date = Date()

    private let headerTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var todayPendingDrafts: [VisitDraft] {
        passiveLocation.todayPendingDrafts()
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                DSColor.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    // MARK: Header
                    HStack(spacing: 12) {
                        // Hamburger menu (decorative for MVP)
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 20, weight: .regular))
                            .foregroundColor(DSColor.onSurface)
                            .frame(width: 32, height: 32)

                        // Brand name
                        Text("DAYPAGE")
                            .font(.custom("SpaceGrotesk-Bold", size: 20))
                            .foregroundColor(DSColor.onSurface)
                            .kerning(2)

                        Spacer()

                        // Timestamp badge
                        Text(formattedTimestamp(currentTime))
                            .monoLabelStyle(size: 10)
                            .foregroundColor(DSColor.onSurfaceVariant)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(DSColor.surfaceContainer)

                        // Compiling badge (shown during manual or background compilation)
                        if viewModel.isCompiling || viewModel.isBackgroundCompiling {
                            CompilingBadge()
                        }

                        // Settings icon
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.system(size: 18, weight: .regular))
                                .foregroundColor(DSColor.onSurface)
                                .frame(width: 32, height: 32)
                        }
                    }
                    .padding(.horizontal, 20)
                    .frame(height: 56)
                    .onReceive(headerTimer) { date in
                        currentTime = date
                    }

                    Divider()
                        .background(DSColor.outline)

                    // MARK: API Key Missing Banner
                    if viewModel.hasApiKeysMissing {
                        ApiKeyMissingBanner {
                            showSettings = true
                        }
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

                    // MARK: Timeline (75% of available space)
                    GeometryReader { geo in
                        ScrollView {
                            LazyVStack(spacing: 8) {
                                // On This Day card
                                if let entry = viewModel.onThisDayEntry {
                                    OnThisDayCard(
                                        entry: entry,
                                        onDismiss: { viewModel.dismissOnThisDay() },
                                        onTap: { e in
                                            let fmt = DateFormatter()
                                            fmt.dateFormat = "yyyy-MM-dd"
                                            fmt.locale = Locale(identifier: "en_US_POSIX")
                                            fmt.timeZone = TimeZone.current
                                            onThisDayDateString = fmt.string(from: e.originalDate)
                                        }
                                    )
                                    .padding(.top, 4)
                                }

                                // Daily Page entry card or compile prompt
                                Group {
                                    if viewModel.isDailyPageCompiled {
                                        DailyPageEntryCard(
                                            summary: viewModel.dailyPageSummary,
                                            onTap: { showDailyPage = true }
                                        )
                                    } else {
                                        CompilePromptCard(
                                            memoCount: viewModel.memos.count,
                                            isCompiling: viewModel.isCompiling,
                                            onCompile: { viewModel.compile() }
                                        )
                                    }
                                }
                                .padding(.horizontal, 20)

                                // Memo cards (reverse-chronological)
                                if viewModel.memos.isEmpty && !viewModel.isLoading {
                                    TodayEmptyStateView { suggestion in
                                        draftText = suggestion
                                    }
                                } else {
                                    ForEach(Array(viewModel.memos.enumerated()), id: \.element.id) { idx, memo in
                                        TimelineRow(
                                            memo: memo,
                                            isLast: idx == viewModel.memos.count - 1
                                        )
                                        .padding(.leading, 20)
                                        .padding(.trailing, 20)
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
                        .frame(maxHeight: geo.size.height)
                    }

                    // MARK: Input Bar
                    InputBarView(
                        text: $draftText,
                        isSubmitting: viewModel.isSubmitting,
                        isLocating: viewModel.isLocating,
                        pendingLocation: viewModel.pendingLocation,
                        locationAuthStatus: LocationService.shared.authorizationStatus,
                        isProcessingPhoto: viewModel.isProcessingPhoto,
                        pendingAttachments: viewModel.pendingAttachments,
                        onFetchLocation: {
                            viewModel.fetchLocation()
                        },
                        onClearLocation: {
                            viewModel.clearPendingLocation()
                        },
                        onAddPhoto: { item in
                            viewModel.addPhotoAttachment(item: item)
                        },
                        onCapturePhoto: {
                            viewModel.startCameraCapture()
                        },
                        onRemoveAttachment: { id in
                            viewModel.removePendingAttachment(id: id)
                        },
                        onStartVoiceRecording: {
                            viewModel.startVoiceRecording()
                        },
                        onVoiceComplete: { result in
                            viewModel.addVoiceAttachment(result: result)
                        },
                        onAddFile: {
                            viewModel.startFilePicker()
                        },
                        onSubmit: {
                            let body = draftText
                            draftText = ""
                            viewModel.submitCombinedMemo(body: body)
                        }
                    )
                }
                // Submit error toast
                .overlay(alignment: .top) {
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
            }
            .navigationBarHidden(true)
            .onAppear {
                viewModel.load()
                updateVoiceQueueBanner(count: voiceQueue.pendingCount)
            }
            .onChange(of: voiceQueue.pendingCount) { count in
                updateVoiceQueueBanner(count: count)
            }
            .animation(.easeInOut(duration: 0.25), value: viewModel.submitError)
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
            // On complete: stage the recording as a pending attachment; user submits manually.
            .sheet(isPresented: $viewModel.isShowingVoiceRecorder) {
                VoiceRecordingView(
                    onComplete: { result in
                        viewModel.isShowingVoiceRecorder = false
                        viewModel.addVoiceAttachment(result: result)
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
                        viewModel.addCameraPhoto(image)
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
        }
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

    private func formattedTimestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd // HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f.string(from: date)
    }
}

// MARK: - OnThisDayNavTarget

private struct OnThisDayNavTarget: Identifiable {
    let dateString: String
    var id: String { dateString }
}

// MARK: - ApiKeyMissingBanner

/// Yellow banner shown when one or more API keys are not configured.
struct ApiKeyMissingBanner: View {
    let onGoToSettings: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(DSColor.warning)
                .font(.system(size: 14))
            Text("部分功能需要配置 API Key")
                .font(.custom("Inter-Regular", size: 13))
                .foregroundColor(DSColor.onWarningContainer)
            Spacer()
            Button("前往设置") {
                onGoToSettings()
            }
            .font(.custom("Inter-Medium", size: 13))
            .foregroundColor(DSColor.warning)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(DSColor.warningContainer)
    }
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
                .foregroundColor(DSColor.error)
                .font(.system(size: 14))
            Text(message)
                .font(.custom("Inter-Regular", size: 13))
                .foregroundColor(DSColor.onErrorContainer)
                .lineLimit(2)
            Spacer()
            Button("重试") {
                onRetry()
            }
            .font(.custom("Inter-Medium", size: 13))
            .foregroundColor(DSColor.error)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DSColor.onErrorContainer)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(DSColor.errorContainer)
    }
}

// MARK: - CompilingBadge

/// Small badge shown in the Today header when compilation is in progress.
struct CompilingBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            ProgressView()
                .scaleEffect(0.6)
                .tint(DSColor.onSurface)
            Text("正在编译...")
                .font(.custom("JetBrainsMono-Regular", fixedSize: 10))
                .foregroundColor(DSColor.onSurface)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(DSColor.primary.opacity(0.12))
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
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 6) {
                Image(systemName: "location.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DSColor.primary)
                Text("检测到位置到达")
                    .font(.custom("Inter-Medium", size: 13))
                    .foregroundColor(DSColor.onSurface)
                Spacer()
                Button("全部忽略") {
                    onIgnoreAll()
                }
                .font(.custom("Inter-Regular", size: 12))
                .foregroundColor(DSColor.onSurfaceVariant)
                Button("全部确认") {
                    onConfirmAll()
                }
                .font(.custom("Inter-Medium", size: 12))
                .foregroundColor(DSColor.primary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Divider()
                .background(DSColor.outlineVariant)

            ForEach(drafts) { draft in
                LocationDraftRow(
                    draft: draft,
                    onConfirm: { onConfirm(draft) },
                    onIgnore: { onIgnore(draft) }
                )
                if draft.id != drafts.last?.id {
                    Divider()
                        .background(DSColor.outlineVariant)
                        .padding(.leading, 16)
                }
            }
        }
        .background(DSColor.surfaceContainer)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(DSColor.outlineVariant),
            alignment: .bottom
        )
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
                .font(.system(size: 20))
                .foregroundColor(DSColor.primary.opacity(0.7))

            VStack(alignment: .leading, spacing: 2) {
                Text(draft.placeName ?? "未知地点")
                    .font(.custom("Inter-Medium", size: 13))
                    .foregroundColor(DSColor.onSurface)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(formatTime(draft.arrivalDate))
                        .font(.custom("JetBrainsMono-Regular", fixedSize: 10))
                        .foregroundColor(DSColor.onSurfaceVariant)
                    if let dur = durationText {
                        Text("·")
                            .font(.custom("JetBrainsMono-Regular", fixedSize: 10))
                            .foregroundColor(DSColor.onSurfaceVariant)
                        Text(dur)
                            .font(.custom("JetBrainsMono-Regular", fixedSize: 10))
                            .foregroundColor(DSColor.onSurfaceVariant)
                    }
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    onIgnore()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DSColor.onSurfaceVariant)
                        .frame(width: 28, height: 28)
                        .background(DSColor.surfaceContainerHigh)
                }

                Button {
                    onConfirm()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(DSColor.primary)
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

/// Wraps a MemoCardView with a left timeline column (time + connecting line).
struct TimelineRow: View {
    let memo: Memo
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left timeline column: time label + connecting line
            VStack(spacing: 0) {
                Text(RelativeTimeFormatter.relative(memo.created))
                    .font(.custom("JetBrainsMono-Regular", fixedSize: 10))
                    .foregroundColor(DSColor.onSurfaceVariant)
                    .frame(width: 60)
                    .padding(.top, 10)
                    .multilineTextAlignment(.center)

                // Connecting line extends to bottom of card
                if !isLast {
                    Rectangle()
                        .fill(DSColor.outlineVariant)
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                        .padding(.top, 4)
                }

                Spacer(minLength: 0)
            }
            .frame(width: 40)

            // Memo card
            MemoCardView(memo: memo)
                .frame(maxWidth: .infinity)
        }
    }
}
