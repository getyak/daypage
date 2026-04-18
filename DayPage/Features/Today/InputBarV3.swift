import SwiftUI
import CoreLocation
import PhotosUI
import UIKit

// MARK: - InputBarV3 (Voice-First)
//
// Voice-first home composer for Issue #76. Two states:
//
//   • collapsed — empty default. A centered 80pt primary mic (press-and-hold
//     to record, slide-up to cancel, slide-left to transcribe-into-draft,
//     release-in-place to send) with a small muted text affordance under
//     it. Nothing else competes for attention.
//
//   • composing — user tapped the text affordance or has draft content or
//     pending attachments. Reveals a capsule TextEditor with `+` on the
//     left and an arrow-up send button on the right; mic is hidden while
//     text is being composed. Matches WeChat's "tap-to-swap" metaphor.
//
// Press-to-talk gesture + RecordingOverlayView reuse is unchanged from V2.

struct InputBarV3: View {

    // MARK: Inputs (identical surface to InputBarV2)

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
    var onPressToTalkSend: (VoiceRecordingResult) -> Void
    var onPressToTalkTranscribe: (String) -> Void
    var onAddFile: () -> Void
    var onSubmit: () -> Void

    // MARK: Private State

    @FocusState private var isFocused: Bool
    @State private var showAttachmentMenu: Bool = false
    @State private var photosPickerItem: PhotosPickerItem? = nil
    @State private var showPhotosPicker: Bool = false
    @State private var pressToTalkPhase: PressToTalkPhase = .idle
    @State private var showHoldToast: Bool = false
    @State private var userExpandedText: Bool = false

    @StateObject private var voiceService = VoiceService.shared

    // MARK: Derived

    /// True when the bar should show the text composer (capsule field + send).
    /// Expanded automatically when there's draft content or attachments; also
    /// latches open when the user taps the "写点什么" affordance.
    private var isComposing: Bool {
        userExpandedText
            || !text.isEmpty
            || !pendingAttachments.isEmpty
            || pendingLocation != nil
    }

    private var pressToTalkOverlayMode: RecordingOverlayMode? {
        switch pressToTalkPhase {
        case .idle: return nil
        case .recording: return .recording
        case .cancelArmed: return .cancelArmed
        case .transcribeArmed: return .transcribeArmed
        case .transcribing: return .transcribing
        }
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            if let overlayMode = pressToTalkOverlayMode {
                RecordingOverlayView(
                    mode: overlayMode,
                    elapsedSeconds: voiceService.elapsedSeconds,
                    waveform: voiceService.waveformHistory
                )
                .animation(.spring(response: 0.28, dampingFraction: 0.85), value: overlayMode)
            }

            Rectangle()
                .fill(DSColor.outlineVariant.opacity(0.6))
                .frame(height: 0.5)

            if !pendingAttachments.isEmpty {
                attachmentPreviewRow
            }

            if let loc = pendingLocation {
                locationChipRow(loc: loc)
            }

            if isComposing {
                composingRow
            } else {
                collapsedRow
            }
        }
        .animation(.easeInOut(duration: 0.22), value: isComposing)
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
        .overlay(alignment: .bottom) {
            if showHoldToast {
                Text("按住说话")
                    .monoLabelStyle(size: 11)
                    .foregroundColor(DSColor.onSurface)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(DSColor.surfaceContainerHigh)
                    .clipShape(Capsule())
                    .padding(.bottom, 140)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showHoldToast)
        .onChange(of: isFocused) { focused in
            if !focused && text.isEmpty && pendingAttachments.isEmpty && pendingLocation == nil {
                userExpandedText = false
            }
        }
    }

    // MARK: - Collapsed Row (voice-first default)

    @ViewBuilder
    private var collapsedRow: some View {
        VStack(spacing: 10) {
            PressToTalkButton(
                onPressStart: { handlePressToTalkStart() },
                onReleaseSend: { handlePressToTalkReleaseSend() },
                onReleaseCancel: { handlePressToTalkReleaseCancel() },
                onReleaseTranscribe: { handlePressToTalkReleaseTranscribe() },
                onPhaseChange: { phase in
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        pressToTalkPhase = phase
                    }
                },
                size: 80
            )

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                userExpandedText = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    isFocused = true
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "character.cursor.ibeam")
                        .font(.system(size: 11, weight: .regular))
                    Text("写点什么")
                        .font(.custom("Inter-Regular", size: 12))
                }
                .foregroundColor(DSColor.onSurfaceVariant)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开文字输入")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
        .padding(.bottom, 20)
        .background(DSColor.surface)
    }

    // MARK: - Composing Row (text capsule + send)

    // MARK: - Composing Row (Telegram-style: tight, borderless)
    //
    // Layout: `[+]  ⟨…capsule-shaped text field on a soft fill, no stroke…⟩  [mic|send]`
    // The capsule-shaped field has no explicit border; the visual distinction
    // from the surrounding bar is carried purely by `surfaceContainerLow` fill
    // vs. the bar's `surface`. The right button morphs between mic and send
    // rather than swapping views — this keeps the hit target anchored.

    @ViewBuilder
    private var composingRow: some View {
        HStack(alignment: .bottom, spacing: 6) {
            plusButton
            textFieldCapsule
            rightMorphButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(DSColor.surface)
    }

    @ViewBuilder
    private var plusButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                showAttachmentMenu.toggle()
            }
        } label: {
            Image(systemName: showAttachmentMenu ? "xmark" : "plus")
                .font(.system(size: 18, weight: .regular))
                .foregroundColor(DSColor.onSurfaceVariant)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showAttachmentMenu ? "关闭附件菜单" : "打开附件菜单")
    }

    @ViewBuilder
    private var textFieldCapsule: some View {
        // Collapsed single-line height matches the 36pt `+` / mic buttons.
        // TextEditor's intrinsic line-height is ~22pt; we absorb its built-in
        // 8pt vertical insets with a negative padding so the capsule reads as
        // 36pt tall. The frame grows up to 88pt (~3–4 lines) as the user types.
        ZStack(alignment: .leading) {
            if text.isEmpty {
                Text("写点什么…")
                    .font(.custom("Inter-Regular", size: 15))
                    .foregroundColor(DSColor.onSurfaceVariant.opacity(0.55))
                    .padding(.horizontal, 14)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.custom("Inter-Regular", size: 15))
                .foregroundColor(DSColor.onSurface)
                .focused($isFocused)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .frame(minHeight: 22, maxHeight: 80)
                .padding(.horizontal, 10)
                .padding(.vertical, -7)
        }
        .frame(minHeight: 36)
        .background(DSColor.surfaceContainerLow)
        .clipShape(Capsule())
    }

    /// Right-side action button. A single button that morphs between mic
    /// (idle, press-to-talk) and send (when there's text/attachments).
    /// The morph is visual — internally they are two distinct button
    /// subtrees so the press-to-talk gesture only exists when needed.
    @ViewBuilder
    private var rightMorphButton: some View {
        let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         || !pendingAttachments.isEmpty
        ZStack {
            if hasContent {
                Button {
                    guard !isSubmitting else { return }
                    onSubmit()
                } label: {
                    ZStack {
                        if isSubmitting {
                            ProgressView().tint(DSColor.onPrimary)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(DSColor.onPrimary)
                        }
                    }
                    .frame(width: 36, height: 36)
                    .background(DSColor.primary)
                    .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting)
                .accessibilityLabel("发送")
                .transition(.scale.combined(with: .opacity))
            } else {
                PressToTalkButton(
                    onPressStart: { handlePressToTalkStart() },
                    onReleaseSend: { handlePressToTalkReleaseSend() },
                    onReleaseCancel: { handlePressToTalkReleaseCancel() },
                    onReleaseTranscribe: { handlePressToTalkReleaseTranscribe() },
                    onPhaseChange: { phase in
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                            pressToTalkPhase = phase
                        }
                    },
                    size: 36
                )
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: hasContent)
    }

    // MARK: - Press-to-Talk Handlers

    private func handlePressToTalkStart() {
        showHoldToast = false
        Task { @MainActor in
            await voiceService.startRecording()
        }
    }

    private func handlePressToTalkReleaseSend() {
        // Release-in-place with no actual movement may indicate a mis-tap.
        // If elapsed < ~0.4s, treat as a tap → show the "hold to talk" toast
        // rather than committing an empty recording.
        if voiceService.elapsedSeconds < 1 && voiceService.waveformHistory.allSatisfy({ $0 < 0.02 }) {
            voiceService.cancelRecording()
            pressToTalkPhase = .idle
            flashHoldToast()
            return
        }
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
        Task { @MainActor in
            guard let result = await voiceService.stopAndTranscribe() else {
                pressToTalkPhase = .idle
                return
            }
            if let transcript = result.transcript, !transcript.isEmpty {
                onPressToTalkTranscribe(transcript)
                userExpandedText = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    isFocused = true
                }
            }
            try? FileManager.default.removeItem(at: result.fileURL)
            voiceService.reset()
            pressToTalkPhase = .idle
        }
    }

    private func flashHoldToast() {
        showHoldToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            showHoldToast = false
        }
    }

    // MARK: - Attachment Rows (reused visual style from V2)

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
        .background(DSColor.surface)
    }

    @ViewBuilder
    private func attachmentChip(_ att: PendingAttachment) -> some View {
        let (icon, label) = chipContent(att)
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DSColor.onSurface)
            Text(label)
                .font(.custom("Inter-Regular", size: 11))
                .foregroundColor(DSColor.onSurface)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 120)
            Button {
                onRemoveAttachment(att.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DSColor.onSurfaceVariant)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(DSColor.surfaceContainerHigh)
        .clipShape(Capsule())
    }

    private func chipContent(_ att: PendingAttachment) -> (icon: String, label: String) {
        switch att {
        case .photo(let result):
            let name = (result.filePath as NSString).lastPathComponent
            return ("photo", String(name.prefix(20)))
        case .voice(let result):
            let d = Int(result.duration)
            return ("waveform", String(format: "语音 %02d:%02d", d / 60, d % 60))
        case .file(let result):
            return ("doc", String(result.fileName.prefix(20)))
        }
    }

    @ViewBuilder
    private func locationChipRow(loc: Memo.Location) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "mappin")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DSColor.amberArchival)
            Text(locationLabel(loc))
                .monoLabelStyle(size: 10)
                .foregroundColor(DSColor.amberArchival)
                .lineLimit(1)
            Spacer()
            Button(action: onClearLocation) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DSColor.onSurfaceVariant)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(DSColor.surface)
    }

    // MARK: - Helpers

    private func locationLabel(_ loc: Memo.Location) -> String {
        if let name = loc.name, !name.isEmpty { return name }
        if let lat = loc.lat, let lng = loc.lng { return String(format: "%.4f, %.4f", lat, lng) }
        return "未知位置"
    }
}
