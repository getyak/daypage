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
    @State private var tooShortToastTask: Task<Void, Never>?
    /// True while the mic-tap affordance hint is visible ("单击打开录音页 · 长按发送语音").
    /// Shown on every short tap so users discover both interaction modes.
    @State private var showMicHintToast: Bool = false
    @State private var micHintToastTask: Task<Void, Never>?
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
                .fill(DSColor.inkFaint)
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
        // V4: transparent dock — ambient page background shows through.
        // Warm gradient veil fades the list content behind the dock.
        .background(
            LinearGradient(
                colors: [Color.clear, DSColor.bgWarm.opacity(0.92), DSColor.bgWarm],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(alignment: .top) {
            if showTooShortToast {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 11, weight: .semibold))
                    Text("再说久一点 · 至少 1 秒")
                        .font(DSType.labelSM)
                }
                .foregroundColor(DSColor.inkPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(DSColor.glassHi)
                .background(.ultraThinMaterial, in: Capsule())
                .clipShape(Capsule())
                .shadow(color: Color(hex: "2D1E0A").opacity(0.08), radius: 8, x: 0, y: 2)
                .padding(.top, -34)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .accessibilityLabel("录音太短，请按住麦克风继续说")
                .accessibilityHidden(!showTooShortToast)
            } else if showMicHintToast {
                HStack(spacing: 6) {
                    Image(systemName: "hand.tap")
                        .font(.system(size: 11, weight: .semibold))
                    Text("单击打开录音页 · 长按发送语音")
                        .font(DSType.labelSM)
                }
                .foregroundColor(DSColor.inkPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(DSColor.glassHi)
                .background(.ultraThinMaterial, in: Capsule())
                .clipShape(Capsule())
                .shadow(color: Color(hex: "2D1E0A").opacity(0.08), radius: 8, x: 0, y: 2)
                .padding(.top, -34)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .accessibilityLabel("单击打开录音页，长按发送语音")
                .accessibilityHidden(!showMicHintToast)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showTooShortToast || showMicHintToast)
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

    // STREAM dock — glass capsule wrapping three keys (design spec: glassStyle hi + radius 999).
    private var streamDock: some View {
        HStack(spacing: 6) {
            // LEFT — More (+)
            dockSideButton(systemImage: "plus", accessibilityLabel: "更多附件") {
                showAttachmentMenu = true
            }

            // CENTER — amber radial-gradient mic orb (64pt per design)
            PressToTalkButton(
                onPressStart: handlePressToTalkStart,
                onReleaseSend: handlePressToTalkReleaseSend,
                onReleaseCancel: handlePressToTalkReleaseCancel,
                onReleaseTranscribe: handlePressToTalkReleaseTranscribe,
                onPhaseChange: { pressToTalkPhase = $0 },
                onTapShortRelease: handleMicTap,
                size: 64,
                idleBackgroundColor: DSColor.amberAccent,
                idleIconColor: .white
            )
            .frame(width: 64, height: 64)
            // Radial amber orb glow matching design: inner highlight + deep shadow
            .shadow(color: Color(hex: "5D3000").opacity(0.50), radius: 28, x: 0, y: 12)
            .shadow(color: Color(hex: "5D3000").opacity(0.20), radius: 4, x: 0, y: 2)
            .accessibilityLabel("麦克风")
            .accessibilityHint("单击进入录音页；长按说话松手发送")

            // RIGHT — Aa (text expand)
            dockTextButton(accessibilityLabel: "写文字") {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    userExpandedText = true
                }
                isFocused = true
            }
            .accessibilityIdentifier("expand-text-composer")
        }
        .padding(6)
        // Glass capsule container — ultraThinMaterial + rim highlight
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(
            LinearGradient(
                colors: [Color.white.opacity(0.55), Color.white.opacity(0.12)],
                startPoint: .top, endPoint: .bottom),
            lineWidth: 0.6))
        .shadow(color: Color(hex: "2D1E0A").opacity(0.10), radius: 24, x: 0, y: 8)
        .shadow(color: Color(hex: "2D1E0A").opacity(0.06), radius: 4, x: 0, y: 1)
    }

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
                .foregroundStyle(DSColor.inkPrimary)
                .frame(width: 44, height: 44)
                .background(Color.clear)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    // "Aa" text-expand key — matches design spec's third dock slot
    @ViewBuilder
    private func dockTextButton(
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Text("Aa")
                .font(DSFonts.newYork(size: 16, weight: .medium))
                .foregroundStyle(DSColor.inkPrimary)
                .frame(width: 44, height: 44)
                .background(Color.clear)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    // Hint label below the dock — JetBrains Mono uppercase, like the design.
    // Morphs based on press-to-talk phase so the gesture stays legible.
    private var dockHintLabel: some View {
        let raw: String
        switch pressToTalkPhase {
        case .idle:            raw = "单击打开录音页 · 长按发送语音"
        case .preRecording:    raw = "再按住一下"
        case .recording:       raw = "上滑取消 · 左滑转文字 · 松开发送"
        case .cancelArmed:     raw = "松开取消"
        case .transcribeArmed: raw = "松开转文字"
        case .transcribing:    raw = "正在转文字…"
        }
        return Text(raw)
            .font(DSType.mono9)
            .tracking(1.4)
            .textCase(.uppercase)
            .foregroundStyle(DSColor.inkSubtle)
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
                .font(DSType.serifBody16)
                .foregroundStyle(DSColor.inkPrimary)
                .focused($isFocused)
                .lineLimit(1...8)
                .tint(DSColor.amberAccent)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 10)
                .onTapGesture { isFocused = true }
                .accessibilityIdentifier("memo-input")

            // Icon toolbar row
            HStack(spacing: 0) {
                // Collapse — dismiss keyboard and return to idle voice dock.
                // Draft text / attachments / location are preserved so the user
                // can re-open the composer without losing their work.
                toolbarIconButton(
                    systemImage: "chevron.down",
                    accessibilityLabel: "收起，回到语音模式"
                ) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        userExpandedText = false
                    }
                    isFocused = false
                }

                // Mic — voice-to-text mode in composing
                toolbarIconButton(
                    systemImage: isComposingTranscribe ? "waveform" : "mic",
                    tint: isComposingTranscribe ? DSColor.amberAccent : DSColor.inkMuted,
                    accessibilityLabel: isComposingTranscribe ? "停止语音转文字" : "语音转文字"
                ) {
                    handleComposingMicTap()
                }

                // Camera
                toolbarIconButton(systemImage: "camera", accessibilityLabel: "拍照") {
                    onCapturePhoto()
                }

                // Photo library (multi-select) — the icon IS the picker's label,
                // not a separate button stacked behind a transparent picker.
                // The previous ZStack + opacity(0.01) overlay broke hit-testing
                // on iOS 26.x and left the picker unreachable (#219).
                PhotosPicker(selection: $photosPickerItems, matching: .images, photoLibrary: .shared()) {
                    toolbarIconButtonContent(systemImage: "photo.on.rectangle")
                }
                .accessibilityLabel("相册")

                // Location
                toolbarIconButton(
                    systemImage: pendingLocation != nil ? "mappin.circle.fill" : "mappin.and.ellipse",
                    tint: pendingLocation != nil ? DSColor.amberAccent : DSColor.inkMuted,
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
        tint: Color = DSColor.inkMuted,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            toolbarIconButtonContent(systemImage: systemImage, tint: tint)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Bare icon glyph used as the visual label for both `toolbarIconButton`
    /// (Button-wrapped) and `PhotosPicker` (its own tappable surface).
    @ViewBuilder
    private func toolbarIconButtonContent(
        systemImage: String,
        tint: Color = DSColor.inkMuted
    ) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 20, weight: .light))
            .foregroundStyle(tint)
            .frame(width: 44, height: 44)
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
                hasContent ? DSColor.amberAccent : DSColor.amberAccent.opacity(0.18),
                in: Circle()
            )
            .shadow(
                color: hasContent ? DSColor.amberAccent.opacity(0.32) : .clear,
                radius: 8, x: 0, y: 4
            )
            .animation(.easeInOut(duration: 0.18), value: hasContent)
        }
        .buttonStyle(.plain)
        .disabled(isSubmitting || !hasContent)
        .accessibilityLabel("发送")
        .accessibilityIdentifier("memo-send")
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
    /// Also flashes a hint toast so users discover that long-press sends directly.
    private func handleMicTap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        flashMicHintToast()
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
        // Fix 2: clear competing toast before showing this one
        micHintToastTask?.cancel()
        showMicHintToast = false
        // Fix 1: cancellable Task prevents stacked timers on rapid triggers
        tooShortToastTask?.cancel()
        showTooShortToast = true
        tooShortToastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            showTooShortToast = false
        }
    }

    private func flashMicHintToast() {
        // Fix 2: clear competing toast before showing this one
        tooShortToastTask?.cancel()
        showTooShortToast = false
        // Fix 1: cancellable Task prevents stacked timers on rapid taps
        micHintToastTask?.cancel()
        showMicHintToast = true
        micHintToastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            showMicHintToast = false
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
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(DSColor.inkMuted)
            Text(label).font(.system(size: 12)).foregroundStyle(DSColor.inkMuted).lineLimit(1)
            Button { onRemoveAttachment(att.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(DSColor.inkSubtle)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(DSColor.glassLo, in: Capsule())
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
            Image(systemName: "mappin").font(.system(size: 10, weight: .semibold)).foregroundStyle(DSColor.amberAccent)
            Text(locationLabel(loc)).font(.system(size: 12)).foregroundStyle(DSColor.amberAccent).lineLimit(1)
            Spacer()
            Button(action: onClearLocation) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(DSColor.inkSubtle)
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
