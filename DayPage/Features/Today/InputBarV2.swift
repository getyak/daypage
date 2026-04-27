import SwiftUI
import CoreLocation
import PhotosUI
import UIKit

// MARK: - InputBarV2
//
// Fromm 风格输入栏：圆角描边文本输入框，左侧 `+` 按钮
//（打开 AttachmentMenuPopover），右侧根据上下文切换按钮
//（空白时显示麦克风，有文本时显示发送）。
//
// 与旧版 InputBarView 共存；TodayView 通过 Settings 中的
// @AppStorage("useInputBarV2") 开关选择使用哪个。
//
// 旧版键盘附件工具栏的 5 个图标被有意移除——所有
// 附件入口都在 `+` 弹出菜单中（US-007 AC）。

struct InputBarV2: View {

    // MARK: 绑定

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
    /// 当按住说话原地松手产生完成的录音时调用。
    /// 父视图应立即暂存并提交。
    var onPressToTalkSend: (VoiceRecordingResult) -> Void
    /// 当按住说话左滑松手产生转写文本时调用。
    /// 父视图应填充 draftText；不提交。
    var onPressToTalkTranscribe: (String) -> Void
    var onAddFile: () -> Void
    var onSubmit: () -> Void

    // MARK: 私有状态

    @FocusState private var isFocused: Bool
    @State private var showAttachmentMenu: Bool = false
    @State private var photosPickerItem: PhotosPickerItem? = nil
    @State private var showPhotosPicker: Bool = false
    @State private var showVoiceSheet: Bool = false

    /// 功能开关——为 true 时，右侧麦克风按钮为微信风格
    /// 按住说话手势（US-008）。为 false 时，点击麦克风打开
    /// 旧版 VoiceRecordingView 弹出页。在设置 → 外观中切换。
    @AppStorage("usePressToTalk") private var usePressToTalk: Bool = true

    /// VoiceService 单例，用于按住说话浮层中
    /// 的实时波形 + 计时显示。
    @StateObject private var voiceService = VoiceService.shared

    /// 当前按住说话手势阶段；驱动浮层可见性和样式。
    @State private var pressToTalkPhase: PressToTalkPhase = .idle

    // MARK: 主体

    var body: some View {
        VStack(spacing: 0) {
            // 按住说话浮层——用户按住麦克风时悬浮在输入栏上方。
            // 显示波形 + 计时器 + 滑动提示。
            if let overlayMode = pressToTalkOverlayMode {
                RecordingOverlayView(
                    mode: overlayMode,
                    elapsedSeconds: voiceService.elapsedSeconds,
                    waveform: voiceService.waveformHistory
                )
                .animation(.spring(response: 0.28, dampingFraction: 0.85), value: overlayMode)
            }

            // 输入行上方的细分割线——使用 outlineVariant，
            // 使其看起来是微妙的接缝而非硬分割条。结合下方
            // 匹配 surface 的背景，输入栏和系统 TabBar
            // 融合成一个底部区域，而非堆叠成两条栏。
            Rectangle()
                .fill(DSColor.outlineVariant.opacity(0.6))
                .frame(height: 0.5)

            // 暂存附件预览行
            if !pendingAttachments.isEmpty {
                attachmentPreviewRow
            }

            // 位置标签行
            if let loc = pendingLocation {
                locationChipRow(loc: loc)
            }

            // 主行：[+] [圆角文本输入框] [麦克风 | 发送]
            HStack(alignment: .bottom, spacing: 8) {
                plusButton
                textFieldCapsule
                rightActionButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(DSColor.surface)
        }
        // 附件弹出菜单，固定在 `+` 按钮上方
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
        // 点击外部关闭——覆盖 InputBar 区域；弹出菜单按钮
        // 通过上方的处理函数自行关闭菜单。
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

    // MARK: - 加号按钮

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

    // MARK: - 文本输入胶囊

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
                // TextEditor 有约 8pt 上下系统内边距；用负值抵消，
                // 使胶囊高度与视觉内容高度匹配。
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

    // MARK: - 右侧操作（麦克风或发送）

    @ViewBuilder
    private var rightActionButton: some View {
        let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         || !pendingAttachments.isEmpty

        if hasContent {
            // 发送按钮
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
            // 按住说话（US-008）：按住录制，松手发送，
            // 上滑取消，左滑仅转写。
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
            // 旧版麦克风按钮——点击打开 VoiceRecordingView 弹出页。
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

    // MARK: - 按住说话处理函数

    /// 将当前手势阶段映射到 RecordingOverlayView 模式。
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
            // 丢弃音频文件——仅转写路径不暂存语音附件。
            try? FileManager.default.removeItem(at: result.fileURL)
            voiceService.reset()
            pressToTalkPhase = .idle
        }
    }

    // MARK: - 附件标签行

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

    // MARK: - 位置标签

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

    // MARK: - 辅助方法

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
