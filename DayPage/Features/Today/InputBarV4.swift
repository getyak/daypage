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
    @State private var composerState: ComposerState = .idle
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

    /// Spring spec shared by expanding / collapsing transitions (per AC).
    private static let composerSpring = Animation.spring(response: 0.42, dampingFraction: 0.78)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Animation used for the liquid morph — degrades to a simple fade when
    /// Reduce Motion is enabled (AC: Reduced Motion 降级).
    private var morphAnimation: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.2)
            : Self.composerSpring
    }

    // Geometry IDs for matchedGeometryEffect
    private enum MorphID: Hashable {
        case surface   // idle capsule ↔ composing card background
        case micOrb    // amber orb persists across both states
    }

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

    // MARK: - State machine

    /// Central transition function. All state changes must flow through here.
    /// Transition is debounced: in-flight expanding/collapsing blocks new requests.
    @MainActor
    func transition(to next: ComposerState) {
        // Debounce: reject new transitions while a spring is in-flight.
        guard composerState != .expanding && composerState != .collapsing else { return }
        guard composerState != next else { return }

        switch (composerState, next) {
        case (.idle, .expanding):
            composerState = .expanding
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            withAnimation(morphAnimation) { composerState = .open }
        case (.open, .collapsing):
            composerState = .collapsing
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            withAnimation(morphAnimation) { composerState = .idle }
        default:
            break
        }
    }

    // MARK: Derived

    private var isComposing: Bool {
        composerState == .open || composerState == .expanding || !text.isEmpty || !pendingAttachments.isEmpty || pendingLocation != nil
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

            // Liquid Morph — idle capsule ↔ composing card.
            // matchedGeometryEffect(id: .surface) carries the background shape
            // through the spring so every in-between frame is geometrically
            // continuous (AC: 录屏验证任意一帧截图取出来形状都能解释从哪来).
            if isComposing {
                composingCardMorph
            } else {
                VStack(spacing: 8) {
                    streamDockMorph
                    dockHintLabel
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 14)
            }
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
    // US-008: matchedGeometryEffect on the capsule background so it morphs into
    // the composing card shape. The mic orb also carries its own effect so it
    // slides to the card's bottom-left corner rather than disappearing.
    private var streamDockMorph: some View {
        HStack(spacing: 6) {
            // LEFT — More (+)
            dockSideButton(systemImage: "plus", accessibilityLabel: "更多附件") {
                showAttachmentMenu = true
            }

            // CENTER — amber mic orb. matchedGeometryEffect makes it travel
            // to the card bottom-left corner while shrinking 64→28 (AC).
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
            .matchedGeometryEffect(id: MorphID.micOrb, in: morphNS)
            .shadow(color: Color(hex: "5D3000").opacity(0.50), radius: 28, x: 0, y: 12)
            .shadow(color: Color(hex: "5D3000").opacity(0.20), radius: 4, x: 0, y: 2)
            .accessibilityLabel("麦克风")
            .accessibilityHint("单击进入录音页；长按说话松手发送")

            // RIGHT — Aa (text expand). Fades out as composer opens (AC: Aa 淡出).
            dockTextButton(accessibilityLabel: "写文字") {
                transition(to: .expanding)
                isFocused = true
            }
            .accessibilityIdentifier("expand-text-composer")
        }
        .padding(6)
        // Glass capsule — matchedGeometryEffect on the whole HStack so SwiftUI
        // interpolates position, size, and corner radius to the card shape.
        .matchedGeometryEffect(id: MorphID.surface, in: morphNS)
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
                .font(DSFonts.serif(size: 16, weight: .medium))
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

    // MARK: - Composing Card Morph (US-008)
    //
    // Full-width rounded-rect card that the idle capsule morphs into.
    // matchedGeometryEffect(id: .surface) connects its background to the capsule's.
    // matchedGeometryEffect(id: .micOrb) keeps the amber orb alive, shrinking it
    // to 28×28 and placing it in the bottom-left toolbar as a "voice entry" button.
    //
    // Layout:
    //   ┌────────────────────────────────────┐
    //   │  TextField (with breathing caret)  │
    //   ├────────────────────────────────────┤
    //   │ [⬇] [🎙28] [📷] [🖼] [📍]  ···  [↑] │
    //   └────────────────────────────────────┘

    private var composingCardMorph: some View {
        VStack(spacing: 0) {
            // Text field — full width, no border, generous padding
            ZStack(alignment: .topLeading) {
                TextField("记一笔…", text: $text, axis: .vertical)
                    .font(DSType.serifBody16)
                    .foregroundStyle(DSColor.inkPrimary)
                    .focused($isFocused)
                    .lineLimit(1...8)
                    // Hide native caret; breathing caret below takes over.
                    .tint(.clear)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
                    .onTapGesture { isFocused = true }
                    .accessibilityIdentifier("memo-input")

                // Aa → caret cross-fade (AC: Aa 淡出 = TextField caret 淡入, 同位置, 200ms).
                // Both views occupy the same top-leading slot; opacity mirrors isComposing.
                Group {
                    if isFocused || !text.isEmpty {
                        // Caret fades in
                        BreathingCaretView()
                            .transition(.opacity)
                    } else {
                        // "Aa" label fades out — same position as the caret so it reads
                        // as a continuous crossfade rather than two separate elements.
                        Text("Aa")
                            .font(DSFonts.serif(size: 16, weight: .medium))
                            .foregroundStyle(DSColor.inkSubtle)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: isFocused || !text.isEmpty)
                .padding(.leading, 20)
                .padding(.top, 18)
            }

            // Icon toolbar row
            HStack(spacing: 0) {
                // Collapse — dismiss keyboard, return to idle capsule.
                toolbarIconButton(
                    systemImage: "chevron.down",
                    accessibilityLabel: "收起，回到语音模式"
                ) {
                    transition(to: .collapsing)
                    isFocused = false
                }

                // Mic orb — morphed from the 64pt idle orb to 28pt here (AC).
                // Tapping it in composing mode triggers voice-to-text.
                // matchedGeometryEffect is on the 28pt orb circle so SwiftUI
                // interpolates size continuously (64→28) without counting the
                // touch-target padding (44pt frame outside the effect scope).
                Button {
                    handleComposingMicTap()
                } label: {
                    Circle()
                        .fill(DSColor.amberAccent)
                        .frame(width: 28, height: 28)
                        .overlay(
                            Image(systemName: isComposingTranscribe ? "waveform" : "mic")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                        )
                        .matchedGeometryEffect(id: MorphID.micOrb, in: morphNS)
                        .shadow(color: DSColor.amberAccent.opacity(0.40), radius: 6, x: 0, y: 2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isComposingTranscribe ? "停止语音转文字" : "语音转文字")
                .frame(width: 44, height: 44)

                // Camera
                toolbarIconButton(systemImage: "camera", accessibilityLabel: "拍照") {
                    onCapturePhoto()
                }

                // Photo library
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
        // Card — matchedGeometryEffect on the whole VStack mirrors the surface
        // geometry from the idle capsule for a continuous positional morph.
        .matchedGeometryEffect(id: MorphID.surface, in: morphNS)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.55), Color.white.opacity(0.12)],
                        startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.6)
        )
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .shadow(color: Color(hex: "2D1E0A").opacity(0.10), radius: 24, x: 0, y: 8)
        .shadow(color: Color(hex: "2D1E0A").opacity(0.06), radius: 4, x: 0, y: 1)
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

    // MARK: - Send Button (US-009: 5 adaptive shapes)

    /// Derives the send-button affordance from current draft content.
    private var sendAffordance: SendAffordance {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasPhoto = pendingAttachments.contains { if case .photo = $0 { return true }; return false }
        let hasLocation = pendingLocation != nil
        let totalItems = (hasText ? 1 : 0) + pendingAttachments.count + (hasLocation ? 1 : 0)

        if totalItems == 0 { return .empty }
        if hasText && hasPhoto { return .textAndPhoto }
        if hasText { return .textOnly }
        if hasLocation && !hasText && pendingAttachments.isEmpty { return .locationOnly }
        return .multimodal(count: totalItems)
    }

    @State private var breathingOpacity: Double = 1.0

    private var sendButton: some View {
        let affordance = sendAffordance
        let isDisabled = isSubmitting || affordance == .empty
        return Button(action: handleSend) {
            ZStack {
                // Background layer
                SendAffordanceBG(affordance: affordance, breathingOpacity: breathingOpacity)
                    .frame(width: 44, height: 44)
                // Foreground icon layer
                if isSubmitting {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(0.8)
                } else {
                    SendAffordanceIcon(affordance: affordance, breathingOpacity: breathingOpacity)
                }
            }
            .frame(width: 44, height: 44)
            .shadow(
                color: affordance.shadowColor,
                radius: 8, x: 0, y: 4
            )
            .animation(.spring(response: 0.32, dampingFraction: 0.8), value: affordance)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(affordance.accessibilityLabel)
        .accessibilityIdentifier("memo-send")
        .onAppear { startBreathing() }
        .onChange(of: affordance) { _ in startBreathing() }
    }

    private func startBreathing() {
        withAnimation(
            .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
        ) {
            breathingOpacity = 0.45
        }
    }

    // MARK: - Actions

    private func handleSend() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            transition(to: .collapsing)
            isFocused = false
            return
        }
        onSubmit()
        transition(to: .collapsing)
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

// MARK: - BreathingCaretView

/// Custom text-input caret that pulses opacity 0.6→1.0 every 800ms while visible.
/// Shown in place of the native UITextView caret (which is hidden via .tint(.clear)).
/// Positioned at the top-leading edge of the TextField; does not track cursor offset.
private struct BreathingCaretView: View {

    @State private var isHigh: Bool = false

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(DSColor.amberAccent)
            .frame(width: 2, height: 18)
            .opacity(isHigh ? 1.0 : 0.6)
            // motion-exception: caret breathing 800ms documented in PRD US-013 / FR-20
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isHigh)
            .onAppear { isHigh = true }
    }
}

// MARK: - US-009: Send Affordance (5 shapes)

/// The 5 visual states of the send button, driven by draft composition.
enum SendAffordance: Equatable {
    case empty                  // 空态: 浅色 mic.fill 圆环, 呼吸动画
    case textOnly               // 仅文本: 实心琥珀 arrow.up
    case textAndPhoto           // 文本+照片: camera.fill + arrow.up 复合
    case locationOnly           // 仅位置: mappin.and.arrow.up
    case multimodal(count: Int) // 多模态: 琥珀 ring 带光晕脉动

    var accessibilityLabel: String {
        switch self {
        case .empty:              return "按住说"
        case .textOnly:           return "发送"
        case .textAndPhoto:       return "记下这一刻"
        case .locationOnly:       return "标记此处"
        case .multimodal(let n):  return "发送 \(n) 项"
        }
    }

    var shadowColor: Color {
        switch self {
        case .empty:     return .clear
        case .textOnly:  return DSColor.amberAccent.opacity(0.32)
        case .textAndPhoto: return DSColor.amberAccent.opacity(0.32)
        case .locationOnly: return DSColor.amberAccent.opacity(0.32)
        case .multimodal: return DSColor.amberAccent.opacity(0.40)
        }
    }
}

/// The icon layer inside the send button circle.
private struct SendAffordanceIcon: View {
    let affordance: SendAffordance
    let breathingOpacity: Double

    var body: some View {
        Group {
            switch affordance {
            case .empty:
                Image(systemName: "mic.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(DSColor.amberAccent.opacity(breathingOpacity))

            case .textOnly:
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)

            case .textAndPhoto:
                // Composite: camera behind, small arrow.up overlaid top-right
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Image(systemName: "arrow.up")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .offset(x: 5, y: -5)
                }

            case .locationOnly:
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)

            case .multimodal:
                // Amber ring with a small arrow.up in center
                ZStack {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.8), lineWidth: 2)
                        .frame(width: 28, height: 28)
                        .opacity(breathingOpacity)
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: affordance)
    }
}

/// The background circle of the send button.
private struct SendAffordanceBG: View {
    let affordance: SendAffordance
    let breathingOpacity: Double

    var body: some View {
        Group {
            switch affordance {
            case .empty:
                // Light translucent ring — AC: 空态明确不再用 18% 透明琥珀圆
                Circle()
                    .strokeBorder(
                        DSColor.amberAccent.opacity(breathingOpacity * 0.7),
                        lineWidth: 1.5
                    )
            case .textOnly, .textAndPhoto, .locationOnly:
                Circle().fill(DSColor.amberAccent)
            case .multimodal:
                Circle().fill(DSColor.amberAccent)
            }
        }
    }
}
