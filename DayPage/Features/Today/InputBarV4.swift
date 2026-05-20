import SwiftUI
import CoreLocation
import Photos
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
    var onSetLocation: ((Memo.Location) -> Void)?
    var onClearLocation: () -> Void
    var onAddPhoto: ([PhotosPickerItem]) -> Void
    var onCapturePhoto: () -> Void
    var onRemoveAttachment: (String) -> Void
    var onStartVoiceRecording: () -> Void
    var onPressToTalkSend: (VoiceRecordingResult) -> Void
    var onPressToTalkTranscribe: (String) -> Void
    var onAddFile: () -> Void
    var onSubmit: () -> Void
    var onAddPhotoAsset: ((PHAsset) -> Void)? = nil
    // US-012: batch photo progress bar
    var batchPhotoProgress: Double = 0
    var batchPhotoTotal: Int = 0

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
    /// US-015: placeholder suffix shown in secondary color after the template prefix.
    /// Cleared as soon as the user edits the text beyond the prefix.
    @State private var templateSuffix: String = ""
    /// The template that was last tapped, used to detect when the user diverges.
    @State private var activeTemplate: SmartTemplate? = nil
    /// The template shown this session — computed once so it doesn't reshuffle on re-render.
    @State private var currentTemplate: SmartTemplate = SmartTemplate.current()

    @StateObject private var voiceService = VoiceService.shared
    @StateObject private var contextProvider = ComposerContextProvider.shared

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
            Haptics.soft()
            withAnimation(morphAnimation) { composerState = .open }
        case (.open, .collapsing):
            composerState = .collapsing
            Haptics.soft()
            withAnimation(morphAnimation) { composerState = .idle }
        default:
            break
        }
    }

    // MARK: Derived

    private var isComposing: Bool {
        composerState == .open || composerState == .expanding || !text.isEmpty || !pendingAttachments.isEmpty || pendingLocation != nil
    }

    /// Whether the visible content layer should render the expanded composer.
    /// Unlike `isComposing`, this excludes the `.expanding` transient — so the
    /// branch swap happens *inside* the spring's withAnimation block (when
    /// state lands on `.open`) instead of snapping at the start of expansion.
    /// Content-bearing predicates (text/attachments/location) still force the
    /// composer on, so externally-set drafts surface immediately. (#314)
    private var showsComposerContent: Bool {
        composerState == .open
            || composerState == .collapsing
            || !text.isEmpty
            || !pendingAttachments.isEmpty
            || pendingLocation != nil
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

            // US-012: batch progress bar when processing >3 photos
            if isProcessingPhoto && batchPhotoTotal > 3 {
                VStack(spacing: 4) {
                    ProgressView(value: batchPhotoProgress)
                        .tint(DSColor.amberAccent)
                        .padding(.horizontal, 16)
                    Text("Processing \(Int(batchPhotoProgress * Double(batchPhotoTotal))) / \(batchPhotoTotal) photos")
                        .font(DSFonts.inter(size: 11))
                        .foregroundColor(DSColor.inkMuted)
                }
                .padding(.vertical, 4)
            }

            if let loc = pendingLocation {
                locationChipRow(loc: loc)
            }

            // Morphing surface (#314): a single rounded-rect background that
            // grows from the compact pill geometry into the expanded composer.
            // The shape is always present — only its corner radius and the
            // intrinsic height of its content change, so SwiftUI can animate
            // every in-between frame continuously rather than swapping two
            // unrelated shapes.
            morphingInputSurface
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
                    Text(NSLocalizedString("input.toast.too_short", comment: ""))
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
                .accessibilityLabel(NSLocalizedString("input.a11y.too_short", comment: ""))
                .accessibilityHidden(!showTooShortToast)
            } else if showMicHintToast {
                HStack(spacing: 6) {
                    Image(systemName: "hand.tap")
                        .font(.system(size: 11, weight: .semibold))
                    Text(NSLocalizedString("input.toast.mic_hint", comment: ""))
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
                .accessibilityLabel(NSLocalizedString("input.a11y.mic_hint", comment: ""))
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
        .onChange(of: pendingAttachments.count) { newCount in
            // US-012: medium haptic when an attachment is added; removal haptic
            // fires at the xmark button so we only trigger here on count increase.
            if newCount > 0 {
                Haptics.medium()
            }
        }
    }

    // MARK: - Input Surface (idle Capsule ↔ composer RoundedRectangle)
    //
    // Idle and composer carry their own backgrounds so each can use the shape
    // that actually fits — a true Capsule for the idle three-button pill (so
    // the half-circle end caps read as a real pill, not a small card), and a
    // 24pt RoundedRectangle for the expanded composer card. Linearly morphing
    // between Capsule and RoundedRectangle is not geometrically meaningful
    // (#258); the two branches cross-fade inside one VStack and the existing
    // spring animates the height change.

    private var morphingInputSurface: some View {
        // Two visually distinct shapes — Capsule for idle (carried on
        // dockContent itself), RoundedRectangle 24pt for the expanded
        // composer. A linear morph between them is not geometrically
        // meaningful (#258), so the two branches cross-fade inside the
        // same VStack and the surrounding spring animates the height change.
        VStack(spacing: 6) {
            if showsComposerContent {
                composerContent
                    .background(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .strokeBorder(
                                        LinearGradient(
                                            colors: [Color.white.opacity(0.55), Color.white.opacity(0.12)],
                                            startPoint: .top, endPoint: .bottom
                                        ),
                                        lineWidth: 0.6
                                    )
                            )
                            .shadow(color: Color(hex: "2D1E0A").opacity(0.10), radius: 24, x: 0, y: 8)
                            .shadow(color: Color(hex: "2D1E0A").opacity(0.06), radius: 4, x: 0, y: 1)
                    )
                    .padding(.horizontal, 16)
                    .transition(.opacity)
            } else {
                dockContent
                    .transition(.opacity)
                dockHintLabel
                    .transition(.opacity)
            }
        }
        .padding(.top, 10)
        .padding(.bottom, showsComposerContent ? 14 : 8)
        .animation(morphAnimation, value: showsComposerContent)
    }

    // Idle dock — three equal-weight icon+label keys inside a true Capsule.
    // Width is content-driven (HStack hugs its children), so the pill sits
    // centered with generous horizontal breathing room on either side. The
    // capsule background lives on this view (not on the morphing surface)
    // because the expanded composer uses a different shape entirely (#258).
    private var dockContent: some View {
        HStack(spacing: 4) {
            // LEFT — More (+)
            dockLabelButton(
                systemImage: "plus",
                title: NSLocalizedString("input.dock.more", comment: ""),
                accessibilityLabel: NSLocalizedString("input.a11y.more_attachments", comment: "")
            ) {
                showAttachmentMenu = true
            }

            // CENTER — mic. Press-to-talk is still the hero gesture but the
            // visual weight is restrained to match the icon+label siblings:
            // a 22pt mic glyph paired with a "Record" label inside the same
            // capsule tap target. PressToTalkButton sits behind the HStack as
            // the gesture host; the visual is the HStack itself.
            HStack(spacing: 6) {
                PressToTalkButton(
                    onPressStart: handlePressToTalkStart,
                    onReleaseSend: handlePressToTalkReleaseSend,
                    onReleaseCancel: handlePressToTalkReleaseCancel,
                    onReleaseTranscribe: handlePressToTalkReleaseTranscribe,
                    onPhaseChange: { pressToTalkPhase = $0 },
                    onTapShortRelease: handleMicTap,
                    size: 22,
                    idleBackgroundColor: .clear,
                    idleIconColor: DSColor.inkPrimary
                )
                .frame(width: 22, height: 22)
                Text(NSLocalizedString("input.dock.record", comment: ""))
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(DSColor.inkPrimary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Capsule())
            .accessibilityLabel(NSLocalizedString("input.a11y.mic", comment: ""))
            .accessibilityHint(NSLocalizedString("input.a11y.mic_hint_full", comment: ""))

            // RIGHT — Text composer expand
            dockLabelButton(
                systemImage: "square.and.pencil",
                title: NSLocalizedString("input.dock.text", comment: ""),
                accessibilityLabel: NSLocalizedString("input.a11y.write_text", comment: "")
            ) {
                transition(to: .expanding)
                isFocused = true
            }
            .accessibilityIdentifier("expand-text-composer")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.92))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color(hex: "2D1E0A").opacity(0.06), lineWidth: 0.5)
                )
                .shadow(color: Color(hex: "2D1E0A").opacity(0.06), radius: 10, x: 0, y: 3)
                .shadow(color: Color(hex: "2D1E0A").opacity(0.04), radius: 2, x: 0, y: 1)
        )
    }

    // Icon + text label key — Get-style: SF Symbol on the left, label on the
    // right, both centered as a single tap target. Used for the "+ More" and
    // "✎ Text" slots; mic uses an analogous layout but routes through
    // PressToTalkButton so it can host the long-press gesture.
    @ViewBuilder
    private func dockLabelButton(
        systemImage: String,
        title: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.soft()
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .regular))
                Text(title)
                    .font(.system(size: 14, weight: .regular))
            }
            .foregroundStyle(DSColor.inkPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    // Hint label below the dock — JetBrains Mono uppercase, like the design.
    // Morphs based on press-to-talk phase so the gesture stays legible.
    private var dockHintLabel: some View {
        let raw: String
        switch pressToTalkPhase {
        case .idle:            raw = NSLocalizedString("input.hint.idle", comment: "")
        case .preRecording:    raw = NSLocalizedString("input.hint.pre_recording", comment: "")
        case .recording:       raw = NSLocalizedString("input.hint.recording", comment: "")
        case .cancelArmed:     raw = NSLocalizedString("input.hint.cancel_armed", comment: "")
        case .transcribeArmed: raw = NSLocalizedString("input.hint.transcribe_armed", comment: "")
        case .transcribing:    raw = NSLocalizedString("input.hint.transcribing", comment: "")
        }
        return Text(raw)
            .font(DSType.mono9)
            .tracking(1.4)
            .textCase(.uppercase)
            .foregroundStyle(DSColor.inkSubtle)
            .frame(height: 12)
            .animation(.easeInOut(duration: 0.18), value: pressToTalkPhase)
    }

    // MARK: - Composing Card Morph (US-008 / US-010)
    //
    // Full-width rounded-rect card that the idle capsule morphs into.
    // US-010: The icon toolbar row has been lifted out of this card and moved
    // into a .toolbar { ToolbarItemGroup(placement: .keyboard) } on the
    // TextField so it rides attached to the keyboard instead of forming a
    // second layer beneath it. The card now only contains the text field.
    //
    // Layout (composing):
    //   ┌────────────────────────────────────┐
    //   │  TextField (with breathing caret)  │
    //   └────────────────────────────────────┘
    //   ══════ keyboard appears ══════════════
    //   │ [⬇] [🎙] [📷] [🖼] [📍]  ···  [↑]  │  ← keyboard toolbar
    //   ══════════════════════════════════════

    // MARK: - Drag Handle (US-011)
    //
    // 36×4 gray capsule at the card top. Swipe-up > 32pt or single tap
    // triggers collapse. Matches iOS sheet language.

    private var dragHandle: some View {
        Capsule()
            .fill(Color(UIColor.tertiaryLabel))
            .frame(width: 36, height: 4)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .frame(width: 60)
            .contentShape(Rectangle())
            // Single tap — accessibility equivalent of swipe-up
            .onTapGesture {
                Haptics.medium()
                transition(to: .collapsing)
                isFocused = false
            }
            .accessibilityLabel("下拉收起卡片")
            .accessibilityHint("点击以收起文字输入卡片")
            .accessibilityAddTraits(.isButton)
            // Drag gesture — upward translation > 32pt collapses
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onEnded { value in
                        if value.translation.height < -32 {
                            Haptics.medium()
                            transition(to: .collapsing)
                            isFocused = false
                        }
                    }
            )
    }

    // Composer content rendered inside the morphing surface (#314).
    // Background/border/shadow now live on the shared surface so the pill ↔
    // card morph stays geometrically continuous; this view only contributes
    // intrinsic height + interior layout.
    private var composerContent: some View {
        VStack(spacing: 0) {
            // US-011: drag-to-collapse handle
            HStack {
                Spacer()
                dragHandle
                Spacer()
            }

            // US-014: Context Spotlight Strip — horizontal chip bar above TextField
            let chips = contextProvider.chips
            if !chips.isEmpty {
                SpotlightStripView(
                    chips: chips,
                    onInsertText: { value in
                        if text.isEmpty {
                            text = value
                        } else {
                            text += (text.hasSuffix(" ") ? "" : " ") + value
                        }
                    },
                    onInsertLocation: { loc in
                        onSetLocation?(loc) ?? onFetchLocation()
                    }
                )
                .padding(.top, 2)
                Divider()
                    .background(DSColor.inkFaint)
                    .padding(.horizontal, 16)
            }

            // US-016: Inline Lens Strip — recent 24 h thumbnails for one-tap attach.
            InlineLensStrip { asset in
                onAddPhotoAsset?(asset)
            }

            // US-015: Smart Template hint row — only when draft is empty.
            if text.isEmpty && pendingAttachments.isEmpty {
                SmartTemplateRow(template: currentTemplate) { tpl in
                    activeTemplate = tpl
                    templateSuffix = tpl.placeholder
                    text = tpl.prefix
                    isFocused = true
                    Haptics.soft()
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

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
                    .padding(.bottom, 14)
                    .onTapGesture { isFocused = true }
                    .accessibilityIdentifier("memo-input")
                    // US-010: Keyboard-attached toolbar replaces the in-card
                    // icon row. Rides up with the keyboard; disappears on dismiss.
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            keyboardToolbarContent
                        }
                    }
                    // US-015: clear placeholder suffix when user edits text.
                    .onChange(of: text) { newValue in
                        if let tpl = activeTemplate, !templateSuffix.isEmpty {
                            if newValue != tpl.prefix {
                                templateSuffix = ""
                                activeTemplate = nil
                            }
                        }
                    }

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

            // US-015: secondary-style placeholder suffix shown below the text field
            // while the user hasn't yet typed beyond the template prefix.
            if !templateSuffix.isEmpty {
                HStack {
                    Text(templateSuffix)
                        .font(DSType.serifBody16)
                        .foregroundStyle(Color.secondary)
                        .allowsHitTesting(false)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.15), value: templateSuffix.isEmpty)
            }
        }
        // Background / border / shadow intentionally not applied here —
        // morphingInputSurface owns the single shared shape (#314).
    }

    // MARK: - Keyboard Toolbar (US-010)
    //
    // Replaces the in-card icon row. Lives in .toolbar(placement: .keyboard)
    // on the TextField so it floats directly above the keyboard and disappears
    // when the keyboard is dismissed — no residual height placeholder.
    //
    // iPad wide keyboard: ToolbarItemGroup lays items in a single row that
    // UIKit clips to safe bounds, so no overflow risk.

    @ViewBuilder
    private var keyboardToolbarContent: some View {
        // Collapse — dismiss keyboard, return to idle capsule.
        Button {
            transition(to: .collapsing)
            isFocused = false
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(DSColor.inkMuted)
        }
        .accessibilityLabel("收起，回到语音模式")

        // Mic orb — in keyboard toolbar the matchedGeometryEffect is dropped
        // (toolbar renders outside the SwiftUI namespace tree). A plain amber
        // circle button provides the same affordance at 28pt visual size.
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
                .shadow(color: DSColor.amberAccent.opacity(0.40), radius: 6, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isComposingTranscribe ? "停止语音转文字" : "语音转文字")

        // Camera
        Button {
            onCapturePhoto()
        } label: {
            Image(systemName: "camera")
                .font(.system(size: 19, weight: .light))
                .foregroundStyle(DSColor.inkMuted)
        }
        .accessibilityLabel("拍照")

        // Photo library
        PhotosPicker(selection: $photosPickerItems, matching: .images, photoLibrary: .shared()) {
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 19, weight: .light))
                .foregroundStyle(DSColor.inkMuted)
        }
        .accessibilityLabel("相册")

        // Location
        Button {
            pendingLocation != nil ? onClearLocation() : onFetchLocation()
        } label: {
            Image(systemName: pendingLocation != nil ? "mappin.circle.fill" : "mappin.and.ellipse")
                .font(.system(size: 19, weight: .light))
                .foregroundStyle(pendingLocation != nil ? DSColor.amberAccent : DSColor.inkMuted)
        }
        .accessibilityLabel(pendingLocation != nil ? "清除位置" : "添加位置")

        Spacer()

        // Send button — reuses the same 5-affordance component
        sendButton
    }

    private func handleComposingMicTap() {
        Haptics.soft()
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
        isFocused = false
        transition(to: .collapsing)
    }

    /// Single tap on the mic — open the persistent (Flomo-style) recording
    /// sheet. The user controls pause / resume / save / discard from inside
    /// VoiceRecordingView; we don't start VoiceService here, the sheet does
    /// it itself in `.onAppear`.
    /// Also flashes a hint toast so users discover that long-press sends directly.
    private func handleMicTap() {
        Haptics.soft()
        flashMicHintToast()
        onStartVoiceRecording()
    }

    private func handlePressToTalkStart() {
        Haptics.soft()
        Task { await voiceService.startRecording() }
    }

    private func handlePressToTalkReleaseSend() {
        // Boundary: a sub-second silent press is almost always a mis-tap.
        // Cancel the recording, warn-haptic, and surface the toast — don't
        // commit a meaningless 0:00 voice memo.
        if isRecordingTooShort {
            Haptics.warningNotification()
            voiceService.cancelRecording()
            flashTooShortToast()
            return
        }
        Haptics.medium()
        Task {
            if let result = await voiceService.stopAndTranscribe() {
                onPressToTalkSend(result)
            }
        }
    }

    private func handlePressToTalkReleaseCancel() {
        Haptics.light()
        voiceService.cancelRecording()
    }

    private func handlePressToTalkReleaseTranscribe() {
        // Same floor as the send path — a transcribe gesture on a silent
        // sub-second clip would burn an API call and return nothing.
        if isRecordingTooShort {
            Haptics.warningNotification()
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
        Haptics.medium()
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
            Image(systemName: icon).font(DSType.mono11).foregroundStyle(DSColor.inkMuted)
            Text(label).font(DSType.labelSM).foregroundStyle(DSColor.inkMuted).lineLimit(1)
            Button {
                Haptics.light()
                onRemoveAttachment(att.id)
            } label: {
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
            Text(locationLabel(loc)).font(DSType.labelSM).foregroundStyle(DSColor.amberAccent).lineLimit(1)
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
            .onAppear {
                isHigh = true
                // US-012: 0.15s delay so the haptic fires after the caret visually appears.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    Haptics.rigid(intensity: 0.3)
                }
            }
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
