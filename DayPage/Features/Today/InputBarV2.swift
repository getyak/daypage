import SwiftUI
import CoreLocation
import PhotosUI
import UIKit

// MARK: - InputBarV2
//
// Fromm-style input bar: a rounded outlined text field with a `+` button on
// the left (opens AttachmentMenuPopover) and a context-sensitive right button
// (microphone when empty, send when text exists).
//
// Coexists with legacy InputBarView; TodayView chooses between them via the
// Settings toggle backed by @AppStorage("useInputBarV2").
//
// The old keyboard accessory toolbar's 5 icons are intentionally absent — all
// attachment entry points live in the `+` popover (US-007 AC).

struct InputBarV2: View {

    // MARK: Binding

    @Binding var text: String
    var isSubmitting: Bool
    var isLocating: Bool
    var pendingLocation: Memo.Location?
    var locationAuthStatus: CLAuthorizationStatus
    var isProcessingPhoto: Bool
    var pendingAttachments: [PendingAttachment]
    var onFetchLocation: () -> Void
    var onClearLocation: () -> Void
    var onAddPhoto: (PhotosPickerItem) -> Void
    var onCapturePhoto: () -> Void
    var onRemoveAttachment: (String) -> Void
    var onStartVoiceRecording: () -> Void
    var onVoiceComplete: (VoiceRecordingResult) -> Void
    /// Called when a press-to-talk release-in-place produces a finished
    /// recording. Parent should stage it and submit immediately.
    var onPressToTalkSend: (VoiceRecordingResult) -> Void
    /// Called when a press-to-talk left-swipe-release produces a transcript.
    /// Parent should fill draftText; do NOT submit.
    var onPressToTalkTranscribe: (String) -> Void
    var onAddFile: () -> Void
    var onSubmit: () -> Void

    // MARK: Private State

    @FocusState private var isFocused: Bool
    @State private var showAttachmentMenu: Bool = false
    @State private var photosPickerItem: PhotosPickerItem? = nil
    @State private var showPhotosPicker: Bool = false
    @State private var showVoiceSheet: Bool = false

    /// Feature flag — when true, the right-side mic button is the WeChat-style
    /// press-to-talk gesture (US-008). When false, tapping the mic opens the
    /// legacy VoiceRecordingView sheet. Settings → 外观 toggles this.
    @AppStorage("usePressToTalk") private var usePressToTalk: Bool = true

    /// Voice service singleton used for live waveform + elapsed readouts
    /// inside the press-to-talk overlay.
    @StateObject private var voiceService = VoiceService.shared

    /// Current press-to-talk gesture phase; drives overlay visibility + style.
    @State private var pressToTalkPhase: PressToTalkPhase = .idle

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            // Press-to-talk overlay — floats above the input bar while the user
            // is holding the mic. Shows waveform + timer + swipe hints.
            if let overlayMode = pressToTalkOverlayMode {
                RecordingOverlayView(
                    mode: overlayMode,
                    elapsedSeconds: voiceService.elapsedSeconds,
                    waveform: voiceService.waveformHistory
                )
                .animation(.spring(response: 0.28, dampingFraction: 0.85), value: overlayMode)
            }

            Divider()
                .background(DSColor.outline)

            // Staged attachment preview row
            if !pendingAttachments.isEmpty {
                attachmentPreviewRow
            }

            // Location chip row
            if let loc = pendingLocation {
                locationChipRow(loc: loc)
            }

            // Main row: [+] [rounded text field] [mic | send]
            HStack(alignment: .bottom, spacing: 8) {
                plusButton
                textFieldCapsule
                rightActionButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(DSColor.surfaceContainerLow)
        }
        // Attachment popover anchored above the `+` button
        .overlay(alignment: .bottomLeading) {
            if showAttachmentMenu {
                AttachmentMenuPopover(
                    onCapturePhoto: {
                        showAttachmentMenu = false
                        onCapturePhoto()
                    },
                    onPickPhoto: {
                        showAttachmentMenu = false
                        showPhotosPicker = true
                    },
                    onAddFile: {
                        showAttachmentMenu = false
                        onAddFile()
                    },
                    onAddLocation: {
                        showAttachmentMenu = false
                        guard !isLocating else { return }
                        onFetchLocation()
                    },
                    isLocating: isLocating,
                    hasPendingLocation: pendingLocation != nil
                )
                .padding(.leading, 12)
                .padding(.bottom, 56)
                .transition(.scale(scale: 0.85, anchor: .bottomLeading).combined(with: .opacity))
                .zIndex(1)
            }
        }
        // Tap-outside dismissal — covers the InputBar area; popover button taps
        // close the menu themselves via their handlers above.
        .background(
            Group {
                if showAttachmentMenu {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                                showAttachmentMenu = false
                            }
                        }
                }
            }
        )
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: showAttachmentMenu)
        .onChange(of: photosPickerItem) { newItem in
            guard let item = newItem else { return }
            onAddPhoto(item)
            photosPickerItem = nil
        }
        .photosPicker(
            isPresented: $showPhotosPicker,
            selection: $photosPickerItem,
            matching: .images,
            photoLibrary: .shared()
        )
        .sheet(isPresented: $showVoiceSheet) {
            VoiceRecordingView(
                onComplete: { result in
                    showVoiceSheet = false
                    onVoiceComplete(result)
                },
                onCancel: { showVoiceSheet = false }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Plus Button

    @ViewBuilder
    private var plusButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                showAttachmentMenu.toggle()
            }
        } label: {
            Image(systemName: showAttachmentMenu ? "xmark" : "plus")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(DSColor.onSurface)
                .frame(width: 36, height: 36)
                .background(DSColor.surfaceContainerHigh)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showAttachmentMenu ? "关闭附件菜单" : "打开附件菜单")
    }

    // MARK: - Text Field Capsule

    @ViewBuilder
    private var textFieldCapsule: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("LOG NEW OBSERVATION...")
                    .monoLabelStyle(size: 11)
                    .foregroundColor(DSColor.outlineVariant.opacity(0.7))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .bodyMDStyle()
                .foregroundColor(DSColor.onSurface)
                .focused($isFocused)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .frame(minHeight: 36, maxHeight: 100)
                // TextEditor has ~8pt top/bottom system padding; negate it so the
                // capsule height matches the visual content height.
                .padding(.horizontal, 8)
                .padding(.vertical, -4)
        }
        .background(DSColor.surfaceContainerLowest)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(DSColor.outlineVariant, lineWidth: 1)
        )
        .cornerRadius(12)
    }

    // MARK: - Right Action (Mic or Send)

    @ViewBuilder
    private var rightActionButton: some View {
        let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         || !pendingAttachments.isEmpty

        if hasContent {
            // Send button
            Button {
                guard !isSubmitting else { return }
                onSubmit()
            } label: {
                ZStack {
                    if isSubmitting {
                        ProgressView()
                            .tint(DSColor.onPrimary)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(DSColor.onPrimary)
                    }
                }
                .frame(width: 40, height: 40)
                .background(DSColor.primary)
                .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting)
            .accessibilityLabel("发送")
        } else if usePressToTalk {
            // Press-to-talk (US-008): press+hold to record, release to send,
            // swipe up to cancel, swipe left to transcribe-only.
            PressToTalkButton(
                onPressStart: { handlePressToTalkStart() },
                onReleaseSend: { handlePressToTalkReleaseSend() },
                onReleaseCancel: { handlePressToTalkReleaseCancel() },
                onReleaseTranscribe: { handlePressToTalkReleaseTranscribe() },
                onPhaseChange: { phase in
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        pressToTalkPhase = phase
                    }
                }
            )
        } else {
            // Legacy mic button — tap opens the VoiceRecordingView sheet.
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onStartVoiceRecording()
            } label: {
                Image(systemName: "mic")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundColor(DSColor.onSurface)
                    .frame(width: 40, height: 40)
                    .background(DSColor.surfaceContainerHigh)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("语音录制")
        }
    }

    // MARK: - Press-to-Talk Handlers

    /// Maps the current gesture phase to the RecordingOverlayView mode.
    private var pressToTalkOverlayMode: RecordingOverlayMode? {
        switch pressToTalkPhase {
        case .idle: return nil
        case .recording: return .recording
        case .cancelArmed: return .cancelArmed
        case .transcribeArmed: return .transcribeArmed
        case .transcribing: return .transcribing
        }
    }

    private func handlePressToTalkStart() {
        Task { @MainActor in
            await voiceService.startRecording()
        }
    }

    private func handlePressToTalkReleaseSend() {
        Task { @MainActor in
            guard let result = await voiceService.stopAndTranscribe() else {
                pressToTalkPhase = .idle
                return
            }
            onPressToTalkSend(result)
            pressToTalkPhase = .idle
        }
    }

    private func handlePressToTalkReleaseCancel() {
        voiceService.cancelRecording()
        pressToTalkPhase = .idle
    }

    private func handlePressToTalkReleaseTranscribe() {
        // Stay in .transcribing until the Whisper call returns.
        Task { @MainActor in
            guard let result = await voiceService.stopAndTranscribe() else {
                pressToTalkPhase = .idle
                return
            }
            if let transcript = result.transcript, !transcript.isEmpty {
                onPressToTalkTranscribe(transcript)
            }
            // Discard the audio file — transcribe-only path does not stage a voice attachment.
            try? FileManager.default.removeItem(at: result.fileURL)
            voiceService.reset()
            pressToTalkPhase = .idle
        }
    }

    // MARK: - Attachment Chip Row

    @ViewBuilder
    private var attachmentPreviewRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingAttachments) { att in
                    attachmentChip(att)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .background(DSColor.surfaceContainerLow)
    }

    @ViewBuilder
    private func attachmentChip(_ att: PendingAttachment) -> some View {
        let (icon, label) = chipContent(att)
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(DSColor.onSurfaceVariant)
            Text(label)
                .monoLabelStyle(size: 11)
                .foregroundColor(DSColor.onSurfaceVariant)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 120)
            Button(action: { onRemoveAttachment(att.id) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DSColor.onSurfaceVariant)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(height: 32)
        .background(DSColor.surfaceContainerHigh)
        .cornerRadius(6)
    }

    private func chipContent(_ att: PendingAttachment) -> (icon: String, label: String) {
        switch att {
        case .photo(let result):
            let name = (result.filePath as NSString).lastPathComponent
            return ("photo", String(name.prefix(20)))
        case .voice(let result):
            return ("mic.fill", formatDuration(result.duration))
        case .file(let result):
            return ("doc.fill", String(result.fileName.prefix(20)))
        }
    }

    // MARK: - Location Chip

    @ViewBuilder
    private func locationChipRow(loc: Memo.Location) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "mappin").font(.system(size: 10, weight: .semibold)).foregroundColor(DSColor.amberArchival)
            Text(locationLabel(loc)).monoLabelStyle(size: 10).foregroundColor(DSColor.amberArchival).lineLimit(1)
            Spacer()
            Button(action: onClearLocation) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundColor(DSColor.onSurfaceVariant)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(DSColor.surfaceContainerLow)
    }

    // MARK: - Helpers

    private func locationLabel(_ loc: Memo.Location) -> String {
        if let name = loc.name, !name.isEmpty { return name }
        if let lat = loc.lat, let lng = loc.lng { return String(format: "%.4f, %.4f", lat, lng) }
        return "未知位置"
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
