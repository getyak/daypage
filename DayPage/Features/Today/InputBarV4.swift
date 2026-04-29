import SwiftUI
import CoreLocation
import PhotosUI
import UIKit

// MARK: - InputBarV4  "Capture v2 · STREAM dock"
//
// Capture v2 surface, faithful to the design-handoff STREAM variation:
// a centered, compact liquid-glass capsule with three slots —
//
//   [+ more]  [ mic-hero (amber, 56×44) ]  [ ✏ pen ]
//
// + opens the attachment menu (camera / album / file / location).
// mic-hero: tap → Flomo-style recording (separate bar);
//           long-press (>= 0.35s) → WeChat-style press-to-talk
//           (drag up to cancel, drag left to transcribe-into-draft,
//            release to send).
// pen: expands the dock into a full-width text composer above; send
//      arrow on the right replaces the dock while composing.
//
// Hint line beneath the dock ("点击录音 · 长按发送") sets expectation;
// it morphs to recording status while the gesture is active.
//
// Design notes from chat:
//  - Dock is centered and compact, not edge-to-edge — "优雅美观简洁"
//  - Glass material: ultraThin + warm border highlight + soft drop shadow
//  - Mic-hero is the only filled control. Side buttons are translucent.
//  - All English/Chinese helper labels above the dock have been killed
//    in favor of the universal mic / + / pen glyphs (design note 03).

struct InputBarV4: View {

    // MARK: Bindings (identical surface to V2/V3)

    @Binding var text: String
    var isSubmitting: Bool
    var isLocating: Bool
    var pendingLocation: Memo.Location?
    var locationAuthStatus: CLAuthorizationStatus
    var isProcessingPhoto: Bool
    var pendingAttachments: [PendingAttachment]
    var onFetchLocation: () -> Void
    var onClearLocation: () -> Void
    var onAddPhoto: ([PhotosPickerItem]) -> Void
    var onCapturePhoto: () -> Void
    var onRemoveAttachment: (String) -> Void
    var onStartVoiceRecording: () -> Void
    var onPressToTalkSend: (VoiceRecordingResult) -> Void
    var onPressToTalkTranscribe: (String) -> Void
    var onAddFile: () -> Void
    var onSubmit: () -> Void

    // MARK: Private State

    @FocusState private var isFocused: Bool
    @State private var showAttachmentMenu: Bool = false
    @State private var photosPickerItems: [PhotosPickerItem] = []
    @State private var pressToTalkPhase: PressToTalkPhase = .idle
    @State private var userExpandedText: Bool = false
    /// True while a "录音太短" hint is visible. Prevents committing a
    /// meaningless one-frame recording while gracefully nudging the user
    /// toward the hold gesture.
    @State private var showTooShortToast: Bool = false
    /// True while composing-mode mic is actively recording for transcription.
    @State private var isComposingTranscribe: Bool = false

    @StateObject private var voiceService = VoiceService.shared

    @Namespace private var morphNS

    /// Recording floor below which a press-and-release is treated as
    /// accidental noise. Capture v2 boundary: respect the user's time —
    /// a sub-second silent clip carries no meaning, drop it with a hint.
    private static let minRecordingSeconds: Int = 1

    /// True when the active recording is below the meaning threshold AND
    /// the captured waveform is silent. Both gates so a brief but audible
    /// "嗯" / "对" / "好" still goes through.
    private var isRecordingTooShort: Bool {
        let belowFloor = voiceService.elapsedSeconds < Self.minRecordingSeconds
        let isSilent = voiceService.waveformHistory.allSatisfy { $0 < 0.05 }
        return belowFloor && isSilent
    }

    // MARK: Derived

    private var isComposing: Bool {
        userExpandedText || !text.isEmpty || !pendingAttachments.isEmpty || pendingLocation != nil
    }

    private var overlayMode: RecordingOverlayMode? {
        switch pressToTalkPhase {
        case .idle, .preRecording: return nil
        case .recording:           return .recording
        case .cancelArmed:         return .cancelArmed
        case .transcribeArmed:     return .transcribeArmed
        case .transcribing:        return .transcribing
        }
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            if let mode = overlayMode {
                RecordingOverlayView(
                    mode: mode,
                    elapsedSeconds: voiceService.elapsedSeconds,
                    waveform: voiceService.waveformHistory
                )
                .animation(.spring(response: 0.28, dampingFraction: 0.85), value: mode)
            }

            Rectangle()
                .fill(DSColor.outlineVariant.opacity(0.5))
                .frame(height: 0.5)

            if !pendingAttachments.isEmpty {
                attachmentPreviewRow
            }

            if let loc = pendingLocation {
                locationChipRow(loc: loc)
            }

            // STREAM dock layout:
            // - composing → INK-style: full-width text area + icon toolbar row
            // - idle      → centered three-slot dock with hint label below
            Group {
                if isComposing {
                    composingToolbarLayout
                } else {
                    VStack(spacing: 8) {
                        streamDock
                        dockHintLabel
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 14)
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: isComposing)
        }
        .background(DSColor.backgroundWarm)
        .overlay(alignment: .top) {
            if showTooShortToast {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 11, weight: .semibold))
                    Text("再说久一点 · 至少 1 秒")
                        .font(.custom("Inter-Regular", size: 11))
                }
                .foregroundColor(DSColor.onSurface)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(DSColor.surfaceContainerHigh)
                .clipShape(Capsule())
                .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 2)
                .padding(.top, -34)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .accessibilityLabel("录音太短，请按住麦克风继续说")
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showTooShortToast)
        .sheet(isPresented: $showAttachmentMenu) {
            AttachmentMenuPopover(
                onCapturePhoto: { showAttachmentMenu = false; onCapturePhoto() },
                onPickPhoto: { showAttachmentMenu = false },
                onAddFile: { showAttachmentMenu = false; onAddFile() },
                onAddLocation: { showAttachmentMenu = false; onFetchLocation() },
                isLocating: isLocating,
                hasPendingLocation: pendingLocation != nil
            )
        }
        .onChange(of: photosPickerItems) { newItems in
            guard !newItems.isEmpty else { return }
            onAddPhoto(newItems)
            photosPickerItems = []
        }
    }

    // MARK: - STREAM Dock (idle state)
    //
    // Centered three-slot capsule, faithful to VariationStream.jsx:
    //   - 40pt `+` (more)        opens attachment menu
    //   - 56×44 amber mic-hero   tap = Flomo record · long-press = WeChat send
    //   - 40pt pen               expands to text composer
    //
    // The capsule itself is wrapped in `.ultraThinMaterial` with a layered
    // shadow stack approximating the iOS 26 Liquid Glass treatment from the
    // design canvas (inner highlight + soft drop shadow).

    // STREAM dock — three free-floating glass discs.
    //
    // No outer container: the page (and any list content behind it) shows
    // through between the three buttons. Each disc carries its own
    // ultraThinMaterial fill, fine inner highlight, and a soft warm-amber
    // drop shadow so the surface reads as elevated glass over the page,
    // not a solid pill.
    private var streamDock: some View {
        HStack(spacing: 18) {
            // LEFT — More
            dockSideButton(
                systemImage: "plus",
                accessibilityLabel: "更多附件"
            ) {
                showAttachmentMenu = true
            }

            // CENTER — Mic-hero (amber, slightly larger, the only filled CTA)
            //
            // Tap (< 0.35s)  → enter Flomo-style continuous recording sheet
            //                  (VoiceRecordingView, half-screen, pause/resume/save).
            // Long-press     → WeChat-style press-to-talk, release to send.
            //
            // The two paths are intentionally distinct: a tap is for "I want
            // to talk for a while, control pause/save myself"; a hold is for
            // "I want to dictate one quick thought and let go to send".
            PressToTalkButton(
                onPressStart: handlePressToTalkStart,
                onReleaseSend: handlePressToTalkReleaseSend,
                onReleaseCancel: handlePressToTalkReleaseCancel,
                onReleaseTranscribe: handlePressToTalkReleaseTranscribe,
                onPhaseChange: { pressToTalkPhase = $0 },
                onTapShortRelease: handleMicTap,
                size: 56,
                idleBackgroundColor: DSColor.accentAmber,
                idleIconColor: .white
            )
            .frame(width: 56, height: 56)
            .shadow(color: DSColor.accentAmber.opacity(0.32), radius: 14, x: 0, y: 8)
            .shadow(color: DSColor.accentAmber.opacity(0.18), radius: 4, x: 0, y: 2)
            .accessibilityLabel("麦克风")
            .accessibilityHint("单击进入录音页；长按说话松手发送")

            // RIGHT — Pen (expand text composer)
            dockSideButton(
                systemImage: "square.and.pencil",
                accessibilityLabel: "写文字"
            ) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    userExpandedText = true
                }
                isFocused = true
            }
        }
    }

    // Translucent glass disc — 44pt. ultraThinMaterial + warm hairline +
    // soft drop shadow so it reads as a floating glass coin over the page.
    @ViewBuilder
    private func dockSideButton(
        systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(DSColor.onBackgroundPrimary)
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(0.55), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.10), radius: 10, x: 0, y: 6)
                .shadow(color: Color.black.opacity(0.04), radius: 2, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    // Hint label below the dock — JetBrains Mono uppercase, like the design.
    // Morphs based on press-to-talk phase so the gesture stays legible.
    private var dockHintLabel: some View {
        let raw: String
        switch pressToTalkPhase {
        case .idle:            raw = "点击进入录音 · 长按发送"
        case .preRecording:    raw = "再按住一下"
        case .recording:       raw = "上滑取消 · 左滑转文字 · 松开发送"
        case .cancelArmed:     raw = "松开取消"
        case .transcribeArmed: raw = "松开转文字"
        case .transcribing:    raw = "正在转文字…"
        }
        return Text(raw)
            .font(.custom("JetBrainsMono-Regular", size: 9))
            .tracking(1.4)
            .textCase(.uppercase)
            .foregroundStyle(DSColor.onBackgroundSubtle)
            .frame(height: 12)
            .animation(.easeInOut(duration: 0.18), value: pressToTalkPhase)
    }

    // MARK: - Composing Toolbar Layout (INK-style)
    //
    // Full-width text area on top, then a flat icon toolbar row:
    //   [mic]  [camera]  [photo]  [location]  ········  [↑ send]
    // The mic in this mode triggers voice-to-text (fills the text field)
    // rather than sending a standalone voice memo.

    private var composingToolbarLayout: some View {
        VStack(spacing: 0) {
            // Text field — full width, no border, generous padding
            TextField("记一笔…", text: $text, axis: .vertical)
                .font(.custom("Inter-Regular", size: 17))
                .foregroundStyle(DSColor.onBackgroundPrimary)
                .focused($isFocused)
                .lineLimit(1...8)
                .tint(DSColor.accentAmber)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 10)
                .onTapGesture { isFocused = true }

            // Icon toolbar row
            HStack(spacing: 0) {
                // Mic — voice-to-text mode in composing
                toolbarIconButton(
                    systemImage: isComposingTranscribe ? "waveform" : "mic",
                    tint: isComposingTranscribe ? DSColor.accentAmber : DSColor.onBackgroundMuted,
                    accessibilityLabel: isComposingTranscribe ? "停止语音转文字" : "语音转文字"
                ) {
                    handleComposingMicTap()
                }

                // Camera
                toolbarIconButton(systemImage: "camera", accessibilityLabel: "拍照") {
                    onCapturePhoto()
                }

                // Photo library (multi-select)
                ZStack {
                    toolbarIconButton(systemImage: "photo.on.rectangle", accessibilityLabel: "相册") {}
                    PhotosPicker(selection: $photosPickerItems, matching: .images, photoLibrary: .shared()) {
                        Color.clear.frame(width: 44, height: 44)
                    }
                    .opacity(0.01)
                }

                // Location
                toolbarIconButton(
                    systemImage: pendingLocation != nil ? "mappin.circle.fill" : "mappin.and.ellipse",
                    tint: pendingLocation != nil ? DSColor.accentAmber : DSColor.onBackgroundMuted,
                    accessibilityLabel: pendingLocation != nil ? "清除位置" : "添加位置"
                ) {
                    pendingLocation != nil ? onClearLocation() : onFetchLocation()
                }

                Spacer()

                // Send button
                sendButton
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }

    @ViewBuilder
    private func toolbarIconButton(
        systemImage: String,
        tint: Color = DSColor.onBackgroundMuted,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func handleComposingMicTap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if isComposingTranscribe {
            // Stop recording and transcribe into text field
            isComposingTranscribe = false
            Task {
                if let result = await voiceService.stopAndTranscribe(),
                   let t = result.transcript, !t.isEmpty {
                    onPressToTalkTranscribe(t)
                }
            }
        } else {
            // Start recording for transcription
            isComposingTranscribe = true
            Task { await voiceService.startRecording() }
        }
    }

    // MARK: - Send Button

    private var sendButton: some View {
        let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Button(action: handleSend) {
            Group {
                if isSubmitting {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 44, height: 44)
            .background(
                hasContent ? DSColor.accentAmber : DSColor.accentAmber.opacity(0.18),
                in: Circle()
            )
            .shadow(
                color: hasContent ? DSColor.accentAmber.opacity(0.32) : .clear,
                radius: 8, x: 0, y: 4
            )
            .animation(.easeInOut(duration: 0.18), value: hasContent)
        }
        .buttonStyle(.plain)
        .disabled(isSubmitting || !hasContent)
    }

    // MARK: - Actions

    private func handleSend() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { userExpandedText = false }
            isFocused = false
            return
        }
        onSubmit()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { userExpandedText = false }
    }

    /// Single tap on the mic — open the persistent (Flomo-style) recording
    /// sheet. The user controls pause / resume / save / discard from inside
    /// VoiceRecordingView; we don't start VoiceService here, the sheet does
    /// it itself in `.onAppear`.
    private func handleMicTap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onStartVoiceRecording()
    }

    private func handlePressToTalkStart() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task { await voiceService.startRecording() }
    }

    private func handlePressToTalkReleaseSend() {
        // Boundary: a sub-second silent press is almost always a mis-tap.
        // Cancel the recording, warn-haptic, and surface the toast — don't
        // commit a meaningless 0:00 voice memo.
        if isRecordingTooShort {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            voiceService.cancelRecording()
            flashTooShortToast()
            return
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task {
            if let result = await voiceService.stopAndTranscribe() {
                onPressToTalkSend(result)
            }
        }
    }

    private func handlePressToTalkReleaseCancel() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        voiceService.cancelRecording()
    }

    private func handlePressToTalkReleaseTranscribe() {
        // Same floor as the send path — a transcribe gesture on a silent
        // sub-second clip would burn an API call and return nothing.
        if isRecordingTooShort {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            voiceService.cancelRecording()
            flashTooShortToast()
            // Critical: the transcribe branch in PressToTalkButton.onEnded
            // early-returns past the unconditional `.idle` reset that the
            // send/cancel paths fall through to. Without this line the
            // RecordingOverlayView stays mounted in `.transcribing` until
            // the user kicks off a new gesture.
            pressToTalkPhase = .idle
            return
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task {
            if let result = await voiceService.stopAndTranscribe(),
               let t = result.transcript, !t.isEmpty {
                onPressToTalkTranscribe(t)
            }
        }
    }

    private func flashTooShortToast() {
        showTooShortToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            showTooShortToast = false
        }
    }

    // MARK: - Attachment Preview

    private var attachmentPreviewRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingAttachments) { att in attachmentChip(att) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    private func attachmentChip(_ att: PendingAttachment) -> some View {
        let (icon, label) = chipContent(att)
        return HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(DSColor.onBackgroundMuted)
            Text(label).font(.system(size: 12)).foregroundStyle(DSColor.onBackgroundMuted).lineLimit(1)
            Button { onRemoveAttachment(att.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(DSColor.onBackgroundSubtle)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(DSColor.surfaceSunken, in: Capsule())
    }

    private func chipContent(_ att: PendingAttachment) -> (icon: String, label: String) {
        switch att {
        case .photo(let r): return ("photo", r.fileURL.lastPathComponent)
        case .voice(let r): return ("mic",   r.filePath.split(separator: "/").last.map(String.init) ?? "Voice")
        case .file(let r):  return ("doc",   r.fileName)
        }
    }

    private func locationChipRow(loc: Memo.Location) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "mappin").font(.system(size: 10, weight: .semibold)).foregroundStyle(DSColor.accentAmber)
            Text(locationLabel(loc)).font(.system(size: 12)).foregroundStyle(DSColor.accentAmber).lineLimit(1)
            Spacer()
            Button(action: onClearLocation) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(DSColor.onBackgroundSubtle)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func locationLabel(_ loc: Memo.Location) -> String {
        if let name = loc.name, !name.isEmpty { return name }
        if let lat = loc.lat, let lng = loc.lng {
            return String(format: "%.4f, %.4f", lat, lng)
        }
        return "Unknown location"
    }
}
