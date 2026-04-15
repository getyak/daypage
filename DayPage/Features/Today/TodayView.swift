import SwiftUI
import CoreLocation

struct TodayView: View {

    @StateObject private var viewModel = TodayViewModel()

    /// The draft text in the input bar.
    @State private var draftText: String = ""

    /// Whether to show the Daily Page sheet.
    @State private var showDailyPage: Bool = false

    /// Current time for the header timestamp (refreshed every minute).
    @State private var currentTime: Date = Date()

    private let headerTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ZStack {
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

                        // Settings icon (decorative for MVP)
                        Image(systemName: "gearshape")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundColor(DSColor.onSurface)
                            .frame(width: 32, height: 32)
                    }
                    .padding(.horizontal, 20)
                    .frame(height: 56)
                    .onReceive(headerTimer) { date in
                        currentTime = date
                    }

                    Divider()
                        .background(DSColor.outline)

                    // MARK: Timeline (75% of available space)
                    GeometryReader { geo in
                        ScrollView {
                            LazyVStack(spacing: 8) {
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
                                    VStack(spacing: 8) {
                                        Spacer(minLength: 32)
                                        Text("今天还没有记录")
                                            .bodySMStyle()
                                            .foregroundColor(DSColor.onSurfaceVariant)
                                        Spacer(minLength: 32)
                                    }
                                    .frame(maxWidth: .infinity)
                                } else {
                                    ForEach(viewModel.memos) { memo in
                                        MemoCardView(memo: memo)
                                            .padding(.horizontal, 20)
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
                        onRemoveAttachment: { id in
                            viewModel.removePendingAttachment(id: id)
                        },
                        onStartVoiceRecording: {
                            viewModel.startVoiceRecording()
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
        }
    }

    // MARK: - Helpers

    private func formattedTimestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd // HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f.string(from: date)
    }
}
