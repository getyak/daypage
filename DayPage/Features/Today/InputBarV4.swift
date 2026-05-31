import SwiftUI
import CoreLocation
import Photos
import PhotosUI
import UIKit

// MARK: - BlinkingModifier (composer.jsx caret animation)
private struct BlinkingModifier: ViewModifier {
    @State private var visible = true
    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever()) {
                    visible = false
                }
            }
    }
}

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
    /// Opens the v8 WriteSheet bottom-sheet composer (design composer.jsx:183).
    /// The dock's text affordance routes here; if unset it falls back to the
    /// inline morph so the dock keeps working in isolation/previews.
    var onOpenWriteSheet: (() -> Void)? = nil
    var onPressToTalkSend: (VoiceRecordingResult) -> Void
    var onPressToTalkTranscribe: (String) -> Void
    var onAddFile: () -> Void
    var onSubmit: () -> Void
    var onAddPhotoAsset: ((PHAsset) -> Void)? = nil
    // US-012: batch photo progress bar
    var batchPhotoProgress: Double = 0
    var batchPhotoTotal: Int = 0
    /// Toggle this bool (flip its value) from the parent to programmatically
    /// open the composer and focus the text field.
    var requestFocusToggle: Bool = false

    // MARK: Private State

    @FocusState private var isFocused: Bool
    @State private var showAttachmentMenu: Bool = false
    @State private var photosPickerItems: [PhotosPickerItem] = []
    /// Triggers the system Photos picker from the "+" attachment menu.
    /// The inline 相册 button in the bottom strip uses its own
    /// `PhotosPicker { … }` wrapper, but the popover's 相册 tile is a
    /// plain Button — we can't wrap a PhotosPicker around a tile inside
    /// the popover (a Sheet inside a Sheet behaves badly), so we use
    /// the `.photosPicker(isPresented:)` modifier instead and let the
    /// popover flip this flag after dismissing itself.
    @State private var showPhotosPicker: Bool = false
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

    /// Expand / collapse easing shared by the composer morph.
    /// Design composer.jsx:520 morphs on cubic-bezier(.2,.8,.2,1) at 280ms;
    /// a 300ms timing curve (within the 280–320ms band) replaces the previous
    /// generic spring so the open/close reads as a calm museum slide, not a
    /// bouncy spring.
    private static let composerSpring = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.3)

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
                        .font(DSType.label)
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
                        .font(DSType.label)
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
                onPickPhoto: {
                    // Bug fix (#332 follow-up): the popover's 相册 tile used to
                    // close the sheet and do nothing else, which is why uploads
                    // never started. We can't wrap a PhotosPicker around the tile
                    // (sheet-in-sheet behaves badly), so we dismiss the popover
                    // and then flip a flag that the `.photosPicker(isPresented:)`
                    // modifier below picks up. The 0.35s delay lets the popover's
                    // dismiss animation finish before iOS tries to present the
                    // photo picker on top of it.
                    showAttachmentMenu = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        showPhotosPicker = true
                    }
                },
                onAddFile: { showAttachmentMenu = false; onAddFile() },
                onAddLocation: { showAttachmentMenu = false; onFetchLocation() },
                isLocating: isLocating,
                hasPendingLocation: pendingLocation != nil
            )
        }
        .photosPicker(
            isPresented: $showPhotosPicker,
            selection: $photosPickerItems,
            matching: .images,
            photoLibrary: .shared()
        )
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
        .onChange(of: requestFocusToggle) { _ in
            transition(to: .expanding)
            isFocused = true
        }
        // v8 recording surface — dark bottom sheet + top Dynamic-Island capsule.
        // Presented as a full-screen overlay so the sheet anchors to the screen
        // bottom and the island to the top, independent of the dock's position.
        // The press-to-talk drag gesture (PressToTalkButton) still drives the
        // state machine; the sheet's buttons mirror cancel / stop-&-transcribe.
        .overlay { recordingSurface }
    }

    // MARK: - Recording Surface (v8 sheet + island)

    @ViewBuilder
    private var recordingSurface: some View {
        if overlayMode != nil {
            ZStack {
                // Warm dim scrim — same recordingBg as the sheet for cohesion.
                DSTokens.Colors.recordingBg.opacity(0.34)
                    .ignoresSafeArea()
                    .transition(.opacity)

                DynamicIslandView(
                    elapsedSeconds: voiceService.elapsedSeconds,
                    waveform: voiceService.waveformHistory,
                    expanded: true
                )

                RecordingSheetView(
                    elapsedSeconds: voiceService.elapsedSeconds,
                    waveform: voiceService.waveformHistory,
                    transcriptPreview: "",
                    onCancel: {
                        handlePressToTalkReleaseCancel()
                        pressToTalkPhase = .idle
                    },
                    onAccept: {
                        handlePressToTalkReleaseTranscribe()
                    }
                )
            }
            .ignoresSafeArea()
            .animation(.spring(response: 0.32, dampingFraction: 0.85), value: overlayMode)
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

    // STREAM dock — full-width warm pill (design composer.jsx:82-166).
    // Layout: [+36] [记下此刻 italic flex] [mic 50×44]
    // Background: rgba(255,253,250,0.84) warm-white blur, 4-layer shadow stack.
    private var streamDockMorph: some View {
        HStack(spacing: 4) {
            // LEFT — attach (+), 36×44 transparent
            Button {
                Haptics.soft()
                showAttachmentMenu = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(DSColor.inkMuted)
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("input.a11y.more_attachments", comment: ""))

            // CENTER — italic text stub, taps to open WriteSheet
            Button {
                Haptics.soft()
                if let openSheet = onOpenWriteSheet {
                    openSheet()
                } else {
                    transition(to: .expanding)
                    isFocused = true
                }
            } label: {
                HStack(spacing: 8) {
                    Text(NSLocalizedString("input.hint.placeholder", comment: "记下此刻"))
                        .font(DSFonts.serif(size: 15.5, italic: true))
                        .foregroundStyle(DSColor.inkSubtle)
                        .lineLimit(1)
                    Rectangle()
                        .fill(DSColor.amberDeep.opacity(0.5))
                        .frame(width: 2, height: 14)
                        .modifier(BlinkingModifier())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("input.a11y.write_text", comment: ""))
            .accessibilityIdentifier("expand-text-composer")

            // RIGHT — mic orb, 50×44, deep amber gradient
            PressToTalkButton(
                onPressStart: handlePressToTalkStart,
                onReleaseSend: handlePressToTalkReleaseSend,
                onReleaseCancel: handlePressToTalkReleaseCancel,
                onReleaseTranscribe: handlePressToTalkReleaseTranscribe,
                onPhaseChange: { pressToTalkPhase = $0 },
                onTapShortRelease: handleMicTap,
                size: 44,
                idleBackgroundColor: DSColor.amberDeep,
                idleIconColor: .white
            )
            .frame(width: 50, height: 44)
            .shadow(color: Color(hex: "5D3000").opacity(0.45), radius: 10, x: 0, y: 4)
            .shadow(color: Color(hex: "5D3000").opacity(0.18), radius: 1, x: 0, y: 1)
            .accessibilityLabel(NSLocalizedString("input.a11y.mic", comment: ""))
            .accessibilityHint(NSLocalizedString("input.a11y.mic_hint_full", comment: ""))
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color(red: 1, green: 253/255, blue: 250/255).opacity(0.84))
                .background(.ultraThinMaterial, in: Capsule())
        )
        .overlay(
            Capsule().strokeBorder(
                Color(red: 214/255, green: 206/255, blue: 192/255).opacity(0.55),
                lineWidth: 0.5
            )
        )
        .shadow(color: Color(hex: "3C280F").opacity(0.22), radius: 16, x: 0, y: 9)
        .shadow(color: Color(hex: "3C280F").opacity(0.08), radius: 3, x: 0, y: 1)
    }

    @ViewBuilder
    private func dockSideButton(
        systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.soft()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(DSType.headlineCaps)
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
            Haptics.soft()
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
    // The action row (collapse / mic / camera / photo / location / send) lives
    // INLINE at the bottom of this card. It used to ride in a
    // .toolbar(placement: .keyboard) accessory (US-010), but on iOS's floating
    // keyboard that accessory renders as a detached glass capsule hovering over
    // the card — the exact "second layer" US-010 set out to avoid — and it
    // crowded the last line of text. Keeping the row inside the card makes the
    // composer one continuous surface that sits above the keyboard.
    //
    // Layout (composing):
    //   ┌────────────────────────────────────┐
    //   │  TextField (native amber caret)    │
    //   │ [⬇] [🎙] [📷] [🖼] [📍]  ···  [↑]  │  ← inline action row
    //   └────────────────────────────────────┘
    //   ══════ keyboard ══════════════════════

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
            .accessibilityLabel(NSLocalizedString("input.a11y.drag_handle", comment: ""))
            .accessibilityHint(NSLocalizedString("input.a11y.drag_handle_hint", comment: ""))
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

    private var composingCardMorph: some View {
        VStack(spacing: 0) {
            // US-011: drag-to-collapse handle
            HStack {
                Spacer()
                dragHandle
                Spacer()
            }

            // US-014: Context Spotlight Strip — horizontal chip bar above TextField.
            // Context chips + the divider are a blank-canvas starting aid; once
            // the user is actually writing they only crowd the card and push the
            // writing area into a thin strip, so gate them on an empty draft
            // (matches the SmartTemplateRow condition below).
            let chips = contextProvider.chips
            if !chips.isEmpty && text.isEmpty && pendingAttachments.isEmpty {
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

            // Text field — full width, no border, generous padding.
            // The native caret (amber) tracks the real insertion point. An
            // earlier build hid it (.tint(.clear)) and drew a decorative
            // "breathing" bar pinned to the top-leading corner, which made the
            // caret look stuck at the FRONT of the text while typing.
            TextField("记一笔…", text: $text, axis: .vertical)
                .font(DSType.serifBody16)
                .foregroundStyle(DSColor.inkPrimary)
                .tint(DSColor.amberAccent)
                .focused($isFocused)
                .lineLimit(1...8)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 14)
                .onTapGesture { isFocused = true }
                .accessibilityIdentifier("memo-input")
                // US-015: clear placeholder suffix when user edits text.
                .onChange(of: text) { newValue in
                    if let tpl = activeTemplate, !templateSuffix.isEmpty {
                        if newValue != tpl.prefix {
                            templateSuffix = ""
                            activeTemplate = nil
                        }
                    }
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

            // Inline action row — one continuous surface with the card, so it
            // can never overlap the text the way the floating .keyboard toolbar
            // did on iOS's floating keyboard.
            composerActionRow
        }
        // NOTE: matchedGeometryEffect removed — see streamDockMorph for context. (#258)
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

    // MARK: - Inline Action Row
    //
    // collapse / mic / camera / photo / location · spacer · send
    // Rendered as the bottom row of the composing card so the composer is a
    // single continuous surface. Previously a .toolbar(placement: .keyboard)
    // accessory, which on iOS's floating keyboard detached into a glass capsule
    // that overlapped the text — see the Composing Card Morph note above.

    private var composerActionRow: some View {
        HStack(spacing: 6) {
            composerActionButtons
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 10)
        .tint(DSColor.inkMuted)
    }

    @ViewBuilder
    private var composerActionButtons: some View {
        // Collapse — dismiss keyboard, return to idle capsule.
        Button {
            transition(to: .collapsing)
            isFocused = false
        } label: {
            Image(systemName: "chevron.down")
                .font(DSType.h2)
                .foregroundStyle(DSColor.inkMuted)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString("input.a11y.collapse", comment: ""))

        // Mic — start/stop voice-to-text into the draft. Amber circle, 28pt.
        Button {
            handleComposingMicTap()
        } label: {
            Circle()
                .fill(DSColor.amberAccent)
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: isComposingTranscribe ? "waveform" : "mic")
                        .font(DSType.caption)
                        .foregroundStyle(.white)
                )
                .shadow(color: DSColor.amberAccent.opacity(0.40), radius: 6, x: 0, y: 2)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isComposingTranscribe
            ? NSLocalizedString("input.a11y.mic_stop_transcribe", comment: "")
            : NSLocalizedString("input.a11y.mic_transcribe", comment: ""))

        // Camera
        Button {
            onCapturePhoto()
        } label: {
            Image(systemName: "camera")
                .font(DSType.titleSM)
                .foregroundStyle(DSColor.inkMuted)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString("input.a11y.camera", comment: ""))

        // Photo library
        PhotosPicker(selection: $photosPickerItems, matching: .images, photoLibrary: .shared()) {
            Image(systemName: "photo.on.rectangle")
                .font(DSType.titleSM)
                .foregroundStyle(DSColor.inkMuted)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString("input.a11y.photo_library", comment: ""))

        // Location
        Button {
            pendingLocation != nil ? onClearLocation() : onFetchLocation()
        } label: {
            Image(systemName: pendingLocation != nil ? "mappin.circle.fill" : "mappin.and.ellipse")
                .font(DSType.titleSM)
                .foregroundStyle(pendingLocation != nil ? DSColor.amberAccent : DSColor.inkMuted)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pendingLocation != nil
            ? NSLocalizedString("input.a11y.clear_location", comment: "")
            : NSLocalizedString("input.a11y.add_location", comment: ""))

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
            .animation(Motion.spring, value: affordance)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(affordance.accessibilityLabel)
        .accessibilityIdentifier("memo-send")
        .onAppear { startBreathing() }
        .onChange(of: affordance) { _ in startBreathing() }
    }

    private func startBreathing() {
        withAnimation(Motion.breathing) {
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
                Image(systemName: "xmark").font(DSType.mono9).foregroundStyle(DSColor.inkSubtle)
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
            Image(systemName: "mappin").font(DSType.labelXS).foregroundStyle(DSColor.amberAccent)
            Text(locationLabel(loc)).font(DSType.labelSM).foregroundStyle(DSColor.amberAccent).lineLimit(1)
            Spacer()
            Button(action: onClearLocation) {
                Image(systemName: "xmark.circle.fill").font(DSType.bodySM).foregroundStyle(DSColor.inkSubtle)
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
                    .font(DSType.bodyMD)
                    .foregroundStyle(DSColor.amberAccent.opacity(breathingOpacity))

            case .textOnly:
                Image(systemName: "arrow.up")
                    .font(DSType.bodyMD)
                    .foregroundStyle(.white)

            case .textAndPhoto:
                // Composite: camera behind, small arrow.up overlaid top-right
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "camera.fill")
                        .font(DSType.bodySM)
                        .foregroundStyle(.white)
                    Image(systemName: "arrow.up")
                        .font(DSType.mono9)
                        .foregroundStyle(.white)
                        .offset(x: 5, y: -5)
                }

            case .locationOnly:
                Image(systemName: "mappin.and.ellipse")
                    .font(DSType.bodyMD)
                    .foregroundStyle(.white)

            case .multimodal:
                // Amber ring with a small arrow.up in center
                ZStack {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.8), lineWidth: 2)
                        .frame(width: 28, height: 28)
                        .opacity(breathingOpacity)
                    Image(systemName: "arrow.up")
                        .font(DSType.label)
                        .foregroundStyle(.white)
                }
            }
        }
        .animation(Motion.spring, value: affordance)
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
