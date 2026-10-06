import SwiftUI
import PhotosUI
import UIKit
import DayPageServices

// MARK: - FeedbackView

struct FeedbackView: View {

    @StateObject private var vm = FeedbackViewModel()

    @State private var photosPickerItems: [PhotosPickerItem] = []
    @State private var showCamera: Bool = false

    var body: some View {
        ZStack {
            DSColor.backgroundWarm.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    headerSection
                    Divider()
                        .background(DSColor.borderSubtle)
                        .padding(.bottom, DSSpacing.xl)

                    if case .submitted(let url) = vm.status {
                        successView(url: url)
                    } else {
                        feedbackInputSection
                        attachmentsSection
                        privacySection
                        sendBar
                    }

                    if let err = vm.errorMessage {
                        errorBanner(message: err)
                    }

                    if !vm.submittedIssues.isEmpty {
                        submittedIssuesSection
                    }

                    Spacer(minLength: 40)
                }
                .padding(.horizontal, DSSpacing.xl)
            }

            if vm.pressToTalkPhase == .recording
                || vm.pressToTalkPhase == .cancelArmed
                || vm.pressToTalkPhase == .transcribeArmed
                || vm.pressToTalkPhase == .transcribing {
                voiceOverlay
                    .transition(.opacity)
            }
        }
        .sheet(isPresented: $vm.isShowingVoiceRecorder) {
            let generation = vm.voiceGeneration
            VoiceRecordingView(
                onComplete: { result in
                    vm.handleVoiceRecordingComplete(result: result, generation: generation)
                },
                onCancel: {
                    vm.cancelVoiceRecording()
                },
                purpose: .feedback
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.hidden)
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showCamera) {
            CameraPickerView(
                onCapture: { image in
                    vm.addCameraImage(image)
                    showCamera = false
                },
                onCancel: { showCamera = false }
            )
        }
        .onChange(of: photosPickerItems) { newItems in
            guard !newItems.isEmpty else { return }
            Task {
                await vm.addImages(from: newItems)
                photosPickerItems = []
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text(NSLocalizedString("feedback.header.title", comment: ""))
                .font(.custom("SpaceGrotesk-Bold", size: 22))
                .foregroundColor(DSColor.onBackgroundPrimary)
            Text(NSLocalizedString("feedback.header.subtitle", comment: ""))
                .font(.custom("Inter-Regular", size: 13))
                .foregroundColor(DSColor.onBackgroundSubtle)
        }
        .padding(.top, 64)
        .padding(.bottom, DSSpacing.lg)
    }

    // MARK: - Feedback Input

    private var feedbackInputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel(NSLocalizedString("feedback.input.label", comment: ""))

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: DSRadius.sm)
                    .fill(DSColor.surfaceWhite)
                    .overlay(
                        RoundedRectangle(cornerRadius: DSRadius.sm)
                            .stroke(DSColor.borderDefault, lineWidth: 1)
                    )

                if vm.rawFeedback.isEmpty {
                    Text(NSLocalizedString("feedback.input.placeholder", comment: ""))
                        .font(.custom("Inter-Regular", size: 15))
                        .foregroundColor(DSColor.onBackgroundSubtle)
                        .padding(.horizontal, 14)
                        .padding(.top, 14)
                }

                TextEditor(text: $vm.rawFeedback)
                    .disabled(vm.isSending)
                    .font(.custom("Inter-Regular", size: 15))
                    .foregroundColor(DSColor.onBackgroundPrimary)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .padding(10)
                    .frame(minHeight: 140)
            }
            .frame(minHeight: 140)
        }
        .padding(.bottom, DSSpacing.lg)
    }

    // MARK: - Attachments

    private var attachmentsSection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            HStack(spacing: 10) {
                PhotosPicker(
                    selection: $photosPickerItems,
                    maxSelectionCount: 4,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    attachmentChip(icon: "photo.on.rectangle", label: NSLocalizedString("feedback.photos", comment: ""))
                }
                .disabled(vm.isSending || vm.isProcessingImage)

                Button {
                    showCamera = true
                } label: {
                    attachmentChip(icon: "camera", label: NSLocalizedString("feedback.camera", comment: ""))
                }
                .buttonStyle(.plain)
                .disabled(vm.isSending)

                Spacer()
            }

            if !vm.pendingImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DSSpacing.sm) {
                        ForEach(vm.pendingImages) { image in
                            imageThumb(image)
                        }
                    }
                }
            }

            if vm.isProcessingImage {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text(NSLocalizedString("feedback.image.processing", comment: ""))
                        .font(.custom("Inter-Regular", size: 12))
                        .foregroundColor(DSColor.onBackgroundSubtle)
                }
            }
        }
        .padding(.bottom, DSSpacing.lg)
    }

    private func attachmentChip(icon: String, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13))
            Text(label)
                .font(.custom("Inter-Medium", size: 13))
        }
        .foregroundColor(DSColor.onBackgroundMuted)
        .padding(.horizontal, DSSpacing.md)
        .padding(.vertical, DSSpacing.sm)
        .background(DSColor.surfaceWhite)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(DSColor.borderDefault, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func imageThumb(_ image: PendingFeedbackImage) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(uiImage: image.thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(DSColor.borderDefault, lineWidth: 1)
                )

            Button {
                vm.removeImage(id: image.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(DSColor.onBackgroundMuted)
                    .background(Circle().fill(DSColor.surfaceWhite))
            }
            .buttonStyle(.plain)
            .disabled(vm.isSending)
            .offset(x: 4, y: -4)
        }
    }

    // MARK: - Send bar (mic + send)

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Text(NSLocalizedString("feedback.privacy.destination", comment: "Feedback upload disclosure"))
                .font(DSType.caption)
                .foregroundColor(DSColor.onBackgroundMuted)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(NSLocalizedString("feedback.privacy.diagnostics", comment: "Optional technical diagnostics"),
                   isOn: $vm.includeDiagnostics)
                .font(DSType.bodySM)
                .disabled(vm.isSending)
                .accessibilityIdentifier("feedback-include-diagnostics")
            if vm.includeDiagnostics {
                Text(vm.diagnosticsPreview)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("feedback-diagnostics-preview")
            }
        }
        .padding(.bottom, DSSpacing.lg)
    }

    private var sendBar: some View {
        HStack(spacing: DSSpacing.md) {
            PressToTalkButton(
                onPressStart: { vm.voicePressStart() },
                onReleaseSend: { vm.voiceReleaseSendAsTranscript() },
                onReleaseCancel: { vm.voiceReleaseCancel() },
                onReleaseTranscribe: { vm.voiceReleaseTranscribe() },
                onPhaseChange: { phase in vm.pressToTalkPhase = phase },
                onTapShortRelease: { vm.startVoiceRecording() },
                size: 44
            )
            .disabled(vm.isSending)

            Text(NSLocalizedString("feedback.voice.hint", comment: ""))
                .font(.custom("Inter-Regular", size: 12))
                .foregroundColor(DSColor.onBackgroundSubtle)

            Spacer()

            sendButton
        }
        .padding(.bottom, DSSpacing.xl2)
    }

    private var sendButton: some View {
        Button {
            HapticFeedback.medium()
            Task { await vm.send() }
        } label: {
            HStack(spacing: 6) {
                if vm.isSending {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.8)
                        .tint(.white)
                } else {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 15, weight: .medium))
                }
                Text(vm.isSending ? NSLocalizedString("feedback.sending", comment: "") : NSLocalizedString("feedback.send", comment: ""))
                    .font(.custom("Inter-SemiBold", size: 16))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, DSSpacing.xl)
            .padding(.vertical, 14)
            .background(vm.isSending ? DSColor.accentAmber.opacity(0.7) : DSColor.accentAmber)
            .cornerRadius(12)
        }
        .disabled(vm.isSending || vm.isProcessingImage ||
                  (vm.rawFeedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && vm.pendingImages.isEmpty))
    }

    // MARK: - Voice Overlay

    private var voiceOverlay: some View {
        VStack {
            Spacer()
            VStack(spacing: DSSpacing.md) {
                Image(systemName: overlayIcon)
                    .font(.system(size: 28))
                    .foregroundColor(overlayColor)
                Text(overlayLabel)
                    .font(.custom("Inter-SemiBold", size: 14))
                    .foregroundColor(DSColor.onBackgroundPrimary)
                if vm.pressToTalkPhase == .recording {
                    Text(String(format: NSLocalizedString("feedback.voice.elapsed", comment: "Recording seconds"), vm.voiceService.elapsedSeconds))
                        .font(.custom("Inter-Regular", size: 12))
                        .foregroundColor(DSColor.onBackgroundSubtle)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .background(DSColor.surfaceWhite)
            .overlay(
                RoundedRectangle(cornerRadius: DSRadius.md)
                    .stroke(DSColor.borderDefault, lineWidth: 1)
            )
            .cornerRadius(DSRadius.md)
            .padding(.bottom, 120)
        }
        .frame(maxWidth: .infinity)
    }

    private var overlayIcon: String {
        switch vm.pressToTalkPhase {
        case .cancelArmed: return "xmark.circle.fill"
        case .transcribeArmed: return "text.bubble.fill"
        case .transcribing: return "waveform"
        default: return "mic.fill"
        }
    }

    private var overlayColor: Color {
        switch vm.pressToTalkPhase {
        case .cancelArmed: return DSColor.errorRed
        default: return DSColor.accentAmber
        }
    }

    private var overlayLabel: String {
        switch vm.pressToTalkPhase {
        case .cancelArmed: return NSLocalizedString("feedback.voice.cancel", comment: "")
        case .transcribeArmed: return NSLocalizedString("feedback.voice.transcribe", comment: "")
        case .transcribing: return NSLocalizedString("feedback.voice.transcribing", comment: "")
        default: return NSLocalizedString("feedback.voice.listening", comment: "")
        }
    }

    // MARK: - Submitted Issues (muted styling — issue numbers de-emphasized)

    private var submittedIssuesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel(NSLocalizedString("feedback.history", comment: ""))

            VStack(alignment: .leading, spacing: 0) {
                ForEach(vm.submittedIssues) { issue in
                    submittedIssueRow(issue)
                    if issue.id != vm.submittedIssues.last?.id {
                        Divider()
                            .background(DSColor.borderSubtle)
                            .padding(.leading, 14)
                    }
                }
            }
            .background(DSColor.surfaceWhite)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(DSColor.borderDefault, lineWidth: 1)
            )
        }
        .padding(.bottom, DSSpacing.xl2)
    }

    private func submittedIssueRow(_ issue: SubmittedIssue) -> some View {
        HStack(alignment: .top, spacing: DSSpacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(issue.title)
                    .font(.custom("Inter-Medium", size: 13))
                    .foregroundColor(DSColor.onBackgroundPrimary)
                    .lineLimit(2)
                Text(issue.date, style: .date)
                    .font(.custom("Inter-Regular", size: 11))
                    .foregroundColor(DSColor.onBackgroundSubtle)
            }
            Spacer()
            if let link = URL(string: issue.url) {
                Link(destination: link) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 14))
                        .foregroundColor(DSColor.onBackgroundSubtle)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, DSSpacing.md)
    }

    // MARK: - Success View

    private func successView(url: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(DSColor.successGreen)

            Text(NSLocalizedString("feedback.success.title", comment: ""))
                .font(.custom("SpaceGrotesk-Bold", size: 20))
                .foregroundColor(DSColor.onBackgroundPrimary)
                .multilineTextAlignment(.center)

            Text(NSLocalizedString("feedback.success.body", comment: ""))
                .font(.custom("Inter-Regular", size: 14))
                .foregroundColor(DSColor.onBackgroundMuted)

            HStack(spacing: 14) {
                if let link = URL(string: url) {
                    Link(destination: link) {
                        HStack(spacing: DSSpacing.xs) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 12))
                            Text(NSLocalizedString("feedback.github.review", comment: ""))
                                .font(.custom("Inter-Medium", size: 13))
                        }
                        .foregroundColor(DSColor.onBackgroundMuted)
                    }
                }

                Button(NSLocalizedString("feedback.another", comment: "")) {
                    vm.reset()
                }
                .font(.custom("Inter-Medium", size: 13))
                .foregroundColor(DSColor.accentOnBg)
            }
            .padding(.top, DSSpacing.xs)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    // MARK: - Error / Toast

    private func errorBanner(message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundColor(DSColor.errorRed)
            VStack(alignment: .leading, spacing: 2) {
                Text(message)
                    .font(.custom("Inter-Regular", size: 13))
                    .foregroundColor(DSColor.errorRed)
                Button(NSLocalizedString("feedback.dismiss", comment: "")) {
                    vm.status = .idle
                }
                .font(.custom("Inter-Medium", size: 12))
                .foregroundColor(DSColor.onBackgroundMuted)
            }
            Spacer()
        }
        .padding(DSSpacing.md)
        .background(DSColor.errorSoft)
        .cornerRadius(DSRadius.sm)
        .padding(.vertical, DSSpacing.sm)
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.custom("Inter-SemiBold", size: 12))
            .foregroundColor(DSColor.onBackgroundSubtle)
            .kerning(0.5)
            .textCase(.uppercase)
    }
}
