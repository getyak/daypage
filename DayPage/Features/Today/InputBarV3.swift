import SwiftUI
import CoreLocation
import PhotosUI
import UIKit

// MARK: - InputBarV3（语音优先）
//
// 语音优先的首页输入器。两种状态：
//
//   • 收起态——64pt 黑色麦克风居中作为主要 CTA。长按
//     说话（上滑取消，左滑转写为草稿，松手
//     发送），或短按进入持久录音栏。文字和
//     相机在下方作为辅助操作行。
//
//   • 编辑态——用户点击了文字入口或有草稿内容或
//     暂存附件。展开胶囊形 TextEditor，左侧 `+`，
//     右侧向上箭头发送按钮；编辑文字时麦克风隐藏。
//     符合微信"点击切换"的交互隐喻。
//
// 按住说话手势 + RecordingOverlayView 复用与 V2 保持一致。

struct InputBarV3: View {

    // MARK: 输入（与 InputBarV2 接口一致）

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

    // MARK: 私有状态

    @FocusState private var isFocused: Bool
    @State private var showAttachmentMenu: Bool = false
    @State private var photosPickerItem: PhotosPickerItem? = nil
    @State private var showPhotosPicker: Bool = false
    @State private var pressToTalkPhase: PressToTalkPhase = .idle
    @State private var showHoldToast: Bool = false
    @State private var showTranscribeFailed: Bool = false
    @State private var userExpandedText: Bool = false
    /// 点击录制持久栏激活时为 true
    @State private var isTapRecording: Bool = false

    @StateObject private var voiceService = VoiceService.shared

    // MARK: 派生属性

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

            if !pendingAttachments.isEmpty && !isTapRecording {
                attachmentPreviewRow
            }

            if let loc = pendingLocation, !isTapRecording {
                locationChipRow(loc: loc)
            }

            if isTapRecording {
                tapRecordingBar
            } else if isComposing {
                composingRow
            } else {
                collapsedRow
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isComposing)
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: isTapRecording)
        .sheet(isPresented: $showAttachmentMenu) {
            attachmentSheet
        }
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
                Text("长按可快速发送")
                    .monoLabelStyle(size: 11)
                    .foregroundColor(DSColor.onSurface)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(DSColor.surfaceContainerHigh)
                    .clipShape(Capsule())
                    .padding(.bottom, 140)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if showTranscribeFailed {
                HStack(spacing: 6) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 11, weight: .semibold))
                    Text("转写失败，请重试")
                        .font(.custom("Inter-Regular", size: 11))
                }
                .foregroundColor(DSColor.onError)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(DSColor.error)
                .clipShape(Capsule())
                .padding(.bottom, 140)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showHoldToast)
        .animation(.easeInOut(duration: 0.2), value: showTranscribeFailed)
        .onChange(of: voiceService.state) { newState in
            if case .failed = newState, isTapRecording {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                    isTapRecording = false
                }
            }
        }
        .onChange(of: isFocused) { focused in
            // Collapse only when the user actively dismisses (taps outside) with
            // nothing staged. Do NOT collapse after submit — continuous logging
            // requires the bar to stay open between entries.
            if !focused && text.isEmpty && pendingAttachments.isEmpty && pendingLocation == nil {
                // Delay the collapse check slightly so a submit-then-refocus sequence
                // (where isFocused momentarily drops to false) doesn't snap shut.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if !isFocused && text.isEmpty && pendingAttachments.isEmpty && pendingLocation == nil {
                        userExpandedText = false
                    }
                }
            }
        }
    }

    // MARK: - Attachment Sheet

    @ViewBuilder
    private var attachmentSheet: some View {
        let content = AttachmentMenuSheet(
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
        if #available(iOS 16.4, *) {
            content
                .presentationDetents([PresentationDetent.height(260)])
                .presentationDragIndicator(Visibility.visible)
                .presentationCornerRadius(20)
        } else {
            content
                .presentationDetents([PresentationDetent.height(260)])
                .presentationDragIndicator(Visibility.visible)
        }
    }

    // MARK: - Collapsed Row (centered primary mic + secondary action bar)
    //
    // Voice is the primary action — 64pt black circle, centered, visually dominant.
    // Text and camera sit below as a compact secondary bar so they remain reachable
    // without competing for attention with the mic.

    @ViewBuilder
    private var collapsedRow: some View {
        VStack(spacing: 12) {
            // Primary: centered voice button
            VStack(spacing: 8) {
                PressToTalkButton(
                    onTap: { handleTapToRecord() },
                    onPressStart: { handlePressToTalkStart() },
                    onReleaseSend: { handlePressToTalkReleaseSend() },
                    onReleaseCancel: { handlePressToTalkReleaseCancel() },
                    onReleaseTranscribe: { handlePressToTalkReleaseTranscribe() },
                    onPhaseChange: { phase in
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                            pressToTalkPhase = phase
                        }
                    },
                    size: 64,
                    idleBackgroundColor: DSColor.primary,
                    idleIconColor: DSColor.onPrimary
                )
                Text("按住说话")
                    .font(.custom("Inter-Medium", size: 12))
                    .foregroundColor(DSColor.onSurfaceVariant)
            }
            .frame(maxWidth: .infinity)

            // Secondary: text + camera
            HStack(alignment: .center, spacing: 10) {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    userExpandedText = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        isFocused = true
                    }
                } label: {
                    ZStack(alignment: .leading) {
                        Text("记点什么…")
                            .font(.custom("Inter-Regular", size: 15))
                            .foregroundColor(DSColor.onSurfaceVariant)
                            .padding(.horizontal, 14)
                    }
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(DSColor.surfaceContainerLow)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("打开文字输入，记点什么")

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onCapturePhoto()
                } label: {
                    Image(systemName: "camera")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundColor(DSColor.onSurfaceVariant)
                        .frame(width: 40, height: 40)
                        .background(DSColor.surfaceContainerLow)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("拍照")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
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
                    .foregroundColor(DSColor.onSurfaceVariant)
                    .padding(.horizontal, 14)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.custom("Inter-Regular", size: 15))
                .foregroundColor(DSColor.onSurface)
                .focused($isFocused)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .frame(minHeight: 22, maxHeight: 96)
                .padding(.horizontal, 10)
                .padding(.vertical, -7)
                .accessibilityIdentifier("memo-input")
        }
        .frame(minHeight: 36)
        .background(DSColor.surfaceContainerLow)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                    // Keep the bar open for continuous logging — refocus after
                    // the parent clears the text binding (next run loop tick).
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        userExpandedText = true
                        isFocused = true
                    }
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
                    onTap: { handleTapToRecord() },
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

    // MARK: - Tap-to-Record Bar
    //
    // Shown when the user taps (short-press) the mic button. Replaces the entire
    // input bar content with a compact recording control strip:
    //   [❌ 取消]  [waveform]  [⏸ / ▶]  [00:12]  [✓ 发送]

    @ViewBuilder
    private var tapRecordingBar: some View {
        let isCurrentlyRecording = voiceService.state == .recording
        let isPaused = voiceService.state == .paused

        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Cancel
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    voiceService.cancelRecording()
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        isTapRecording = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(DSColor.error)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("取消录音")

                // Waveform (fills remaining space)
                tapRecordingWaveform
                    .frame(maxWidth: .infinity)

                // Pause / Resume
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    if isCurrentlyRecording {
                        voiceService.pauseRecording()
                    } else if isPaused {
                        voiceService.resumeRecording()
                    }
                } label: {
                    Image(systemName: isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DSColor.onSurface)
                        .frame(width: 36, height: 36)
                        .background(DSColor.surfaceContainerHigh)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPaused ? "继续录音" : "暂停录音")
                .padding(.trailing, 8)

                // Elapsed timer
                Text(formattedRecordingTime(voiceService.elapsedSeconds))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(isPaused ? DSColor.onSurfaceVariant : DSColor.error)
                    .monospacedDigit()
                    .frame(width: 42, alignment: .trailing)
                    .padding(.trailing, 8)

                // Send
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    handleTapRecordingSend()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(DSColor.onPrimary)
                        .frame(width: 36, height: 36)
                        .background(DSColor.primary)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("发送录音")
                .padding(.trailing, 8)
            }
            .frame(height: 56)
            .padding(.horizontal, 4)
            .background(DSColor.surface)
        }
    }

    @ViewBuilder
    private var tapRecordingWaveform: some View {
        let bars = voiceService.waveformHistory
        let barCount = min(30, bars.count)
        HStack(alignment: .center, spacing: 2) {
            ForEach(0 ..< barCount, id: \.self) { i in
                let level = i < bars.count ? bars[i] : 0.04
                RoundedRectangle(cornerRadius: 1)
                    .fill(voiceService.state == .paused
                          ? DSColor.onSurfaceVariant.opacity(0.4)
                          : DSColor.amberArchival)
                    .frame(width: 3, height: max(4, CGFloat(level) * 28))
                    .animation(.easeOut(duration: 0.05), value: level)
            }
        }
        .frame(height: 36)
    }

    private func formattedRecordingTime(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%02d:%02d", m, s)
    }

    private func handleTapToRecord() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
            isTapRecording = true
        }
        Task { @MainActor in
            await voiceService.startRecording()
        }
    }

    private func handleTapRecordingSend() {
        Task { @MainActor in
            guard let result = await voiceService.stopAndTranscribe() else {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                    isTapRecording = false
                }
                flashTranscribeFailedToast()
                return
            }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                isTapRecording = false
            }
            onPressToTalkSend(result)
        }
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
                // Surface a recoverable error so the user knows transcription
                // failed and their audio was NOT silently discarded.
                flashTranscribeFailedToast()
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
                // Keep the audio file — it will be surfaced via the failed-toast
                // so the user can retry rather than losing their content.
                flashTranscribeFailedToast()
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

    private func flashTranscribeFailedToast() {
        showTranscribeFailed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            showTranscribeFailed = false
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
