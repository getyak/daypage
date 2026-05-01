import SwiftUI
import PhotosUI
import UIKit

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
                        .padding(.bottom, 20)

                    if case .submitted(let url) = vm.status {
                        successView(url: url)
                    } else {
                        feedbackInputSection
                        attachmentsSection
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
                .padding(.horizontal, 20)
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
            VoiceRecordingView(
                onComplete: { result in
                    vm.handleVoiceRecordingComplete(result: result)
                },
                onCancel: {
                    vm.cancelVoiceRecording()
                }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.hidden)
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
                for item in newItems {
                    await vm.addImage(from: item)
                }
                photosPickerItems = []
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Feedback")
                .font(.custom("SpaceGrotesk-Bold", size: 22))
                .foregroundColor(DSColor.onBackgroundPrimary)
            Text("Describe → AI files it on GitHub for you")
                .font(.custom("Inter-Regular", size: 13))
                .foregroundColor(DSColor.onBackgroundSubtle)
        }
        .padding(.top, 64)
        .padding(.bottom, 16)
    }

    // MARK: - Feedback Input

    private var feedbackInputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Your Feedback")

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(DSColor.surfaceWhite)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(DSColor.borderDefault, lineWidth: 1)
                    )

                if vm.rawFeedback.isEmpty {
                    Text("Describe a bug, feature, or improvement…")
                        .font(.custom("Inter-Regular", size: 15))
                        .foregroundColor(DSColor.onBackgroundSubtle)
                        .padding(.horizontal, 14)
                        .padding(.top, 14)
                }

                TextEditor(text: $vm.rawFeedback)
                    .font(.custom("Inter-Regular", size: 15))
                    .foregroundColor(DSColor.onBackgroundPrimary)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .padding(10)
                    .frame(minHeight: 140)
            }
            .frame(minHeight: 140)
        }
        .padding(.bottom, 16)
    }

    // MARK: - Attachments

    private var attachmentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                PhotosPicker(
                    selection: $photosPickerItems,
                    maxSelectionCount: 4,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    attachmentChip(icon: "photo.on.rectangle", label: "Photos")
                }

                Button {
                    showCamera = true
                } label: {
                    attachmentChip(icon: "camera", label: "Camera")
                }
                .buttonStyle(.plain)

                Spacer()
            }

            if !vm.pendingImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(vm.pendingImages) { image in
                            imageThumb(image)
                        }
                    }
                }
            }

            if vm.isProcessingImage {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text("Processing image…")
                        .font(.custom("Inter-Regular", size: 12))
                        .foregroundColor(DSColor.onBackgroundSubtle)
                }
            }
        }
        .padding(.bottom, 16)
    }

    private func attachmentChip(icon: String, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13))
            Text(label)
                .font(.custom("Inter-Medium", size: 13))
        }
        .foregroundColor(DSColor.onBackgroundMuted)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
            .offset(x: 4, y: -4)
        }
    }

    // MARK: - Send bar (mic + send)

    private var sendBar: some View {
        HStack(spacing: 12) {
            PressToTalkButton(
                onPressStart: { vm.voicePressStart() },
                onReleaseSend: { vm.voiceReleaseSendAsTranscript() },
                onReleaseCancel: { vm.voiceReleaseCancel() },
                onReleaseTranscribe: { vm.voiceReleaseTranscribe() },
                onPhaseChange: { phase in vm.pressToTalkPhase = phase },
                onTapShortRelease: { vm.startVoiceRecording() },
                size: 44
            )

            Text("Tap to record · hold for quick memo")
                .font(.custom("Inter-Regular", size: 12))
                .foregroundColor(DSColor.onBackgroundSubtle)

            Spacer()

            sendButton
        }
        .padding(.bottom, 24)
    }

    private var sendButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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
                Text(vm.isSending ? "Sending…" : "Send")
                    .font(.custom("Inter-SemiBold", size: 16))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(vm.isSending ? DSColor.accentAmber.opacity(0.7) : DSColor.accentAmber)
            .cornerRadius(12)
        }
        .disabled(vm.isSending)
    }

    // MARK: - Voice Overlay

    private var voiceOverlay: some View {
        VStack {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: overlayIcon)
                    .font(.system(size: 28))
                    .foregroundColor(overlayColor)
                Text(overlayLabel)
                    .font(.custom("Inter-SemiBold", size: 14))
                    .foregroundColor(DSColor.onBackgroundPrimary)
                if vm.pressToTalkPhase == .recording {
                    Text("\(vm.voiceService.elapsedSeconds)s · slide up to cancel")
                        .font(.custom("Inter-Regular", size: 12))
                        .foregroundColor(DSColor.onBackgroundSubtle)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .background(DSColor.surfaceWhite)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(DSColor.borderDefault, lineWidth: 1)
            )
            .cornerRadius(14)
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
        case .cancelArmed: return "Release to cancel"
        case .transcribeArmed: return "Release to transcribe"
        case .transcribing: return "Transcribing…"
        default: return "Listening…"
        }
    }

    // MARK: - Submitted Issues (muted styling — issue numbers de-emphasized)

    private var submittedIssuesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Past Submissions")

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
        .padding(.bottom, 24)
    }

    private func submittedIssueRow(_ issue: SubmittedIssue) -> some View {
        HStack(alignment: .top, spacing: 12) {
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
        .padding(.vertical, 12)
    }

    // MARK: - Success View

    private func successView(url: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(DSColor.successGreen)

            Text("Thanks — your feedback was received.")
                .font(.custom("SpaceGrotesk-Bold", size: 20))
                .foregroundColor(DSColor.onBackgroundPrimary)
                .multilineTextAlignment(.center)

            Text("We'll take it from here.")
                .font(.custom("Inter-Regular", size: 14))
                .foregroundColor(DSColor.onBackgroundMuted)

            HStack(spacing: 14) {
                if let link = URL(string: url) {
                    Link(destination: link) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 12))
                            Text("Review on GitHub")
                                .font(.custom("Inter-Medium", size: 13))
                        }
                        .foregroundColor(DSColor.onBackgroundMuted)
                    }
                }

                Button("Submit another") {
                    vm.reset()
                }
                .font(.custom("Inter-Medium", size: 13))
                .foregroundColor(DSColor.accentAmber)
            }
            .padding(.top, 4)
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
                Button("Dismiss") {
                    vm.status = .idle
                }
                .font(.custom("Inter-Medium", size: 12))
                .foregroundColor(DSColor.onBackgroundMuted)
            }
            Spacer()
        }
        .padding(12)
        .background(DSColor.errorSoft)
        .cornerRadius(10)
        .padding(.vertical, 8)
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
