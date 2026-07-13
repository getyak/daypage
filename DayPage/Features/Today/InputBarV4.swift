import SwiftUI
import CoreLocation
import Photos
import PhotosUI
import UIKit
import DayPageModels
import DayPageServices

// MARK: - BreathingCaretModifier (composer.jsx caret animation)
//
// The idle dock caret used to hard-blink (opacity 1 → 0 every 0.6s), which on a
// deliberately quiet, museum-still home surface reads as visual noise that keeps
// tugging the eye. We replace the blink with a slow, low-contrast "breath"
// (opacity 1 → 0.3 over 1.1s) so the caret signals "writable here" without ever
// fully disappearing or demanding attention.
private struct BreathingCaretModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false
    func body(content: Content) -> some View {
        content
            .opacity(dimmed ? 0.3 : 1)
            .onAppear {
                // Vestibular-sensitive: skip the repeating motion entirely when
                // Reduce Motion is on; leave the caret in its solid state.
                guard !reduceMotion else {
                    dimmed = false
                    return
                }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    dimmed = true
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
    /// Opens the AI chat surface (AskPastView). Optional so previews and unit
    /// tests can leave it nil; the dock then hides the sparkle slot.
    var onAskAI: (() -> Void)? = nil
    var onAddPhotoAsset: ((PHAsset) -> Void)? = nil
    // US-012: batch photo progress bar
    var batchPhotoProgress: Double = 0
    var batchPhotoTotal: Int = 0
    /// Toggle this bool (flip its value) from the parent to programmatically
    /// open the composer and focus the text field.
    var requestFocusToggle: Bool = false
    /// #821: reports when a press-to-talk session owns the dock so the parent
    /// can dim the page behind the in-place recording capsule (spotlight
    /// scrim). Optional — previews and secondary hosts may omit it.
    var onRecordingActiveChange: ((Bool) -> Void)? = nil

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
    /// Live drag progress from the whole-dock voice gesture (#821). Written
    /// directly from the gesture's onChanged — drives the recording capsule's
    /// cancel/transcribe tint interpolation with zero animation lag.
    @State private var dockDragProgress = DockDragProgress()
    /// Timestamp of the last press-to-talk session end. Dock child buttons
    /// gate their tap actions on this so the finger-up that ends a recording
    /// can never double-fire the button it happens to land on.
    @State private var lastVoiceGestureEndAt: Date = .distantPast
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

    #if DEBUG
    /// One-shot latch for the `-dockVoiceDemo*` launch-arg bridges (see the
    /// onAppear in `body`). Static because the demo must run once per
    /// PROCESS, not once per view identity.
    @MainActor static var dockVoiceDemoDidRun = false
    #endif

    /// True when the active recording is below the send floor
    /// (`RecordingLimits.minSendableSeconds`, #826) — the release is treated
    /// as an accidental touch: discarded with the too-short toast, never
    /// sent or transcribed.
    private var isRecordingTooShort: Bool {
        RecordingLimits.isBelowSendFloor(voiceService.elapsedSeconds)
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

    /// Reads the cached count (recomputed once per text change, not per render).
    private var wordCount: Int { cachedWordCount }

    private var charCount: Int { text.count }

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
        // Museum-aesthetic redesign (#793 R2): the dock was reading as a
        // "ground floor" stuck to the bottom because of a full-width
        // hairline separator + warm gradient veil behind everything.
        // Both are removed: the dock now floats as a true capsule island
        // on the ambient warm canvas. Attachment / location / progress
        // rows still stack above it (they need full width when they
        // appear), but the resting dock + hint is just a capsule on the
        // page.
        VStack(spacing: 0) {
            if !pendingAttachments.isEmpty {
                attachmentPreviewRow
            }

            // US-012: batch progress bar when processing >3 photos
            if isProcessingPhoto && batchPhotoTotal > 3 {
                VStack(spacing: DSSpacing.xs) {
                    ProgressView(value: batchPhotoProgress)
                        .tint(DSColor.amberAccent)
                        .padding(.horizontal, DSSpacing.lg)
                    Text("Processing \(Int(batchPhotoProgress * Double(batchPhotoTotal))) / \(batchPhotoTotal) photos")
                        .font(DSFonts.inter(size: 11, relativeTo: .caption))
                        .foregroundColor(DSColor.inkMuted)
                }
                .padding(.vertical, DSSpacing.xs)
            }

            if let loc = pendingLocation {
                locationChipRow(loc: loc)
            }

            // Dock-only surface. The previous "composing card" morph
            // (`composingCardMorph` further down in this file) is no longer
            // reachable: it duplicated the WriteSheet's text-input surface
            // and confused users into thinking the app had two composers.
            // All rich composing now happens inside WriteSheetView. The
            // dock is a pure entry point: + (attachments) · "记下此刻"
            // (opens WriteSheet) · mic (press-to-talk). Attachment chips,
            // location chip, and recording overlay still render around the
            // dock as ambient affordances. `composingCardMorph` and its
            // helpers are intentionally left in the file as dead code; the
            // next pass will excise them once we've verified no other
            // surface depends on the templating / send-affordance internals.
            // #821: the mono hint line that used to sit under the dock is
            // gone — recording guidance now lives inside the in-place
            // capsule itself, next to where the finger actually is.
            streamDockMorph
            // Museum-aesthetic redesign (#793 R2): widen breathing room
            // so the dock reads as a floating island, not a wall-to-wall
            // toolbar. 24pt horizontal + 24pt bottom lift gives the
            // capsule visible margins on all four sides.
            .padding(.horizontal, DSSpacing.xl2)
            .padding(.top, 10)
            .padding(.bottom, DSSpacing.xl2)
        }
        // No background veil here — the dock surface itself supplies the
        // contrast against the warm canvas. A gradient behind the whole
        // section makes the dock read as "ground", which broke the
        // floating capsule comp.
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
                // #771: transient toast → glass engine (.toast role).
                .dpGlass(.toast, in: Capsule())
                .clipShape(Capsule())
                .elevation(.glass)
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
                // #771: transient toast → glass engine (.toast role).
                .dpGlass(.toast, in: Capsule())
                .clipShape(Capsule())
                .elevation(.glass)
                .padding(.top, -34)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .accessibilityLabel(NSLocalizedString("input.a11y.mic_hint", comment: ""))
                .accessibilityHidden(!showMicHintToast)
            }
        }
        // Toast show/hide → unify on the `fade` token so adjacent transient
        // hints share one curve (was an inline easeInOut(0.2)).
        .animation(Motion.fade, value: showTooShortToast || showMicHintToast)
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
                // Issue #3 (2026-07-03): 链接 tile — 从剪贴板抓 URL 一键
                // 写入草稿。剪贴板无 URL 时降级为在文本前插入 `https://`
                // 占位让用户手输，避免弹出额外 alert 打断 flow。
                onAddURL: {
                    showAttachmentMenu = false
                    let paste = UIPasteboard.general.string?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let insert: String
                    if let url = URL(string: paste),
                       let scheme = url.scheme?.lowercased(),
                       scheme == "http" || scheme == "https" {
                        insert = paste
                    } else {
                        insert = "https://"
                    }
                    text = text.isEmpty ? insert : "\(insert)\n\(text)"
                    Haptics.tapConfirm()
                },
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
        // #821 in-place recording: the capsule morph happens inside
        // streamDockMorph itself. The full-screen spotlight scrim is owned
        // by the parent (TodayView) via `onRecordingActiveChange`, because a
        // background/overlay on this bottom bar can only tint its own frame.
        .onChange(of: pressToTalkPhase) { newPhase in
            onRecordingActiveChange?(newPhase != .idle && newPhase != .preRecording)
        }
        #if DEBUG
        // Simulator-only demo bridge: `-dockVoiceDemo` walks the whole-dock
        // press-to-talk state machine without a physical finger (synthetic
        // HID long-presses never reach SwiftUI DragGesture). Mirrors the
        // launch-arg bridge used by the auth screen. Real recording starts,
        // the in-place capsule morphs in, and after 5s the send path runs —
        // the exact sequence a hold-and-release performs.
        .onAppear {
            // `-dockVoiceDemo` holds 5s (≥ the 3s floor → memo lands);
            // `-dockVoiceDemoShort` holds 1.5s (< floor → recording is
            // discarded with the too-short toast, #826). Both walk the real
            // release-send handler, so the floor decision under test is the
            // shipping one, not a test double.
            let args = ProcessInfo.processInfo.arguments
            let holdNanos: UInt64
            if args.contains("-dockVoiceDemo") { holdNanos = 5_000_000_000 }
            else if args.contains("-dockVoiceDemoShort") { holdNanos = 1_500_000_000 }
            else { return }
            // onAppear re-fires every time navigation returns to Today;
            // without this latch the demo started a SECOND unattended
            // recording minutes into the session (observed live, #826).
            guard !Self.dockVoiceDemoDidRun else { return }
            Self.dockVoiceDemoDidRun = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                handlePressToTalkStart()
                pressToTalkPhase = .recording
                try? await Task.sleep(nanoseconds: holdNanos)
                handlePressToTalkReleaseSend()
                pressToTalkPhase = .idle
            }
        }
        #endif
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
    //
    // #821 whole-dock press-to-talk: this container is the PERMANENT gesture
    // host. Press anywhere on it and hold ≥0.35s to record; the idle row
    // cross-fades into the in-place recording capsule (DockRecordingCapsule-
    // Content) while THIS view stays mounted, so the drag gesture survives
    // the morph. Never replace this container conditionally — swapping the
    // gesture host mid-press silently drops onEnded and strands a recording.
    private var streamDockMorph: some View {
        ZStack {
            if overlayMode == nil {
                dockIdleRow
                    .transition(.opacity)
            } else {
                DockRecordingCapsuleContent(
                    phase: pressToTalkPhase,
                    elapsedSeconds: voiceService.elapsedSeconds,
                    waveform: voiceService.waveformHistory,
                    dragProgress: dockDragProgress
                )
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottom)))
            }
        }
        // Morph between the 56pt idle capsule and the ~112pt recording
        // chamber rides the shared panel spring; the tint interpolation
        // inside the capsule is direct-driven and never animated.
        .dsAnimation(Motion.panel, value: overlayMode == nil)
        .dockVoiceGesture(
            onPressStart: handlePressToTalkStart,
            onReleaseSend: {
                markVoiceGestureEnd()
                handlePressToTalkReleaseSend()
            },
            onReleaseCancel: {
                markVoiceGestureEnd()
                handlePressToTalkReleaseCancel()
            },
            onReleaseTranscribe: {
                markVoiceGestureEnd()
                handlePressToTalkReleaseTranscribe()
            },
            onPhaseChange: { pressToTalkPhase = $0 },
            onDragProgress: { dockDragProgress = $0 }
        )
    }

    /// True while a press-to-talk session owns the dock. Child-button taps
    /// are swallowed both during the session and for a short grace window
    /// after it ends (the finger-up that finishes a recording may land on a
    /// button and would otherwise fire it).
    private var isDockTapBlocked: Bool {
        pressToTalkPhase != .idle
            || Date().timeIntervalSince(lastVoiceGestureEndAt) < 0.35
    }

    private func markVoiceGestureEnd() {
        lastVoiceGestureEndAt = Date()
    }

    private var dockIdleRow: some View {
        HStack(spacing: DSSpacing.xs) {
            // LEFT — attach (+), 36×44 transparent
            Button {
                guard !isDockTapBlocked else { return }
                Haptics.soft()
                showAttachmentMenu = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(DSColor.inkMuted)
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
            }
            // #150 shared press feedback — replaces .buttonStyle(.plain) so the
            // dock's chrome buttons dip on touch instead of feeling dead. Icon
            // buttons align to the AttachmentMenuPopover sample (0.97 / +0.5pt).
            .pressScale(scale: 0.97, offsetY: 0.5,
                        animation: .spring(response: 0.2, dampingFraction: 0.7))
            .accessibilityLabel(NSLocalizedString("input.a11y.more_attachments", comment: ""))

            // CENTER — silent breathing caret only, taps to open WriteSheet.
            // Previously an italic "记下此刻" hint sat next to the caret; users
            // complained it felt like prefilled text they had to delete, so the
            // affordance reduces to the caret alone. It still telegraphs
            // "tap to write" without polluting the composer with copy.
            Button {
                guard !isDockTapBlocked else { return }
                Haptics.soft()
                if let openSheet = onOpenWriteSheet {
                    openSheet()
                } else {
                    transition(to: .expanding)
                    isFocused = true
                }
            } label: {
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(DSColor.amberDeep.opacity(0.35))
                        .frame(width: 2, height: 14)
                        .modifier(BreathingCaretModifier())
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 6)
                .contentShape(Rectangle())
            }
            // #150 shared press feedback for the "tap to write" caret slot.
            .pressScale(scale: 0.98,
                        animation: .spring(response: 0.2, dampingFraction: 0.7))
            .accessibilityLabel(NSLocalizedString("input.a11y.write_text", comment: ""))
            .accessibilityIdentifier("expand-text-composer")

            // RIGHT — mic orb, 50×44, deep amber gradient.
            // #821: press-to-talk moved up to the whole-dock gesture; the
            // orb itself is now a plain tap target (Flomo-style recording
            // sheet) and the visual anchor that telegraphs "voice lives
            // here". Long-pressing it records like anywhere else on the dock.
            Button {
                guard !isDockTapBlocked else { return }
                handleMicTap()
            } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 19.8, weight: .regular))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(DSColor.amberDeep)
                    .clipShape(Circle())
                    .contentShape(Circle())
            }
            // #150 press feedback on the mic orb. The amber glow scales with the
            // orb (it sits on the Button frame), reading as "the lit orb presses
            // in". respectsReduceMotion keeps it calm when Reduce Motion is on.
            .pressScale(scale: 0.94,
                        animation: .spring(response: 0.22, dampingFraction: 0.72))
            .frame(width: 50, height: 44)
            // Amber glow that makes the send/mic button read as "lit". Kept as a
            // deliberate colored halo (not a neutral DSElevation), but sourced
            // from the dark-adaptive `accentOnBg` so it doesn't sink into the
            // charcoal canvas in dark mode the way hardcoded #5D3000 did.
            .shadow(color: DSColor.accentOnBg.opacity(0.45), radius: 10, x: 0, y: 4)
            .shadow(color: DSColor.accentOnBg.opacity(0.18), radius: 1, x: 0, y: 1)
            .accessibilityLabel(NSLocalizedString("input.a11y.mic", comment: ""))
            .accessibilityHint(NSLocalizedString("input.a11y.mic_hint_full", comment: ""))
            .accessibilityIdentifier("dock-mic-button")

            // FAR-RIGHT — AI chat sparkle. The amber sparkle is the dock's
            // entry into AskPastView (D1 「和过去对话」). We only render the
            // slot when `onAskAI` is wired, so previews and unit tests can
            // omit it cleanly. Visual weight is intentionally lighter than
            // the mic (no filled orb, just a tinted glyph) — the mic is the
            // primary recording action; the sparkle is the calm AI side-door.
            if onAskAI != nil {
                Button {
                    guard !isDockTapBlocked else { return }
                    Haptics.tapConfirm()
                    onAskAI?()
                } label: {
                    Image(systemName: "sparkles")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(DSColor.amberDeep)
                        .frame(width: 40, height: 44)
                        .contentShape(Rectangle())
                }
                // #150 press feedback for the calm AI side-door sparkle.
                .pressScale(scale: 0.97, offsetY: 0.5,
                            animation: .spring(response: 0.2, dampingFraction: 0.7))
                .accessibilityLabel(NSLocalizedString("input.a11y.ask_ai", comment: "Open AI chat"))
                .accessibilityIdentifier("dock-ask-ai-button")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        // Liquid Glass vNext (Phase 1 demo): dual-track dock capsule.
        // iOS 26 → native .glassEffect (refraction + specular + interactive),
        // iOS 16–25 → warm faux-glass fallback. See docs/liquid-glass-vNext.md.
        .dpGlass(.control, in: Capsule())
        // The dock is the app's highest-frequency surface — it must read as
        // clearly lifted. DSElevation.floating carries a two-layer drop that
        // switches to black-at-higher-opacity in dark mode, so the dock keeps
        // its lift on the charcoal canvas instead of vanishing like the old
        // hardcoded warm-ink (#3C280F) shadow did.
        .elevation(.floating)
    }

    // MARK: - Word/Char Count Footer

    private var countFooter: some View {
        // Same single-counter rule as WriteSheetView (FINDING-013): CJK
        // segmentation makes words ≈ characters, so showing both repeats one
        // number. Characters for CJK-dominant drafts, words for latin.
        let wordsLabel = wordCount == 1
            ? NSLocalizedString("writesheet.count.words.one", comment: "1 word")
            : String(format: NSLocalizedString("writesheet.count.words.other", comment: "%d words"), wordCount)
        let isCJKDominant = charCount > 0 && wordCount * 10 >= charCount * 8
        let countLabel = isCJKDominant
            ? "\(charCount) \(NSLocalizedString("writesheet.count.chars", comment: "chars"))"
            : wordsLabel
        return HStack {
            Spacer()
            Text(countLabel)
                .font(DSType.mono10)
                .tracking(1.0)
                .textCase(.uppercase)
                .monospacedDigit()
                .foregroundColor(DSColor.inkMuted)
                .accessibilityLabel(countLabel)
                .accessibilityIdentifier("composer-word-count")
        }
        .padding(.horizontal, DSSpacing.xl)
        .padding(.top, DSSpacing.xs)
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
            .padding(.top, DSSpacing.sm)
            .padding(.bottom, DSSpacing.xs)
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
                    .padding(.horizontal, DSSpacing.lg)
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

            // Live word/char count — fades in only while text is non-empty.
            if !text.isEmpty {
                countFooter
                    .transition(.opacity)
                    .animation(Motion.fade, value: text.isEmpty)
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
                .padding(.horizontal, DSSpacing.xl)
                .padding(.top, 14)
                .padding(.bottom, 14)
                .onTapGesture { isFocused = true }
                .accessibilityIdentifier("memo-input")
                // Seed the cached count for any pre-filled draft (templates,
                // restored text) so the footer is correct before the first edit.
                .onAppear { cachedWordCount = TextCount.words(text) }
                // US-015: clear placeholder suffix when user edits text.
                // Single onChange owns BOTH the suffix reset and the cached word
                // count + milestone haptic. Previously a second `onChange(of:
                // wordCount)` forced SwiftUI to re-run the O(n) word scan every
                // body pass just to diff its trigger value.
                .onChange(of: text) { newValue in
                    if let tpl = activeTemplate, !templateSuffix.isEmpty {
                        if newValue != tpl.prefix {
                            templateSuffix = ""
                            activeTemplate = nil
                        }
                    }
                    let newCount = TextCount.words(newValue)
                    cachedWordCount = newCount
                    if newValue.isEmpty { lastMilestone = 0 }
                    let milestone = newCount / 50
                    if milestone > lastMilestone {
                        lastMilestone = milestone
                        if !reduceMotion { Haptics.soft() }
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
                .padding(.horizontal, DSSpacing.xl)
                .padding(.bottom, DSSpacing.sm)
                .transition(.opacity)
                // Template-suffix fade → `fade` token (was inline easeInOut(0.15)).
                .animation(Motion.fade, value: templateSuffix.isEmpty)
            }

            // Inline action row — one continuous surface with the card, so it
            // can never overlap the text the way the floating .keyboard toolbar
            // did on iOS's floating keyboard.
            composerActionRow
        }
        // NOTE: matchedGeometryEffect removed — see streamDockMorph for context. (#258)
        // Liquid Glass vNext (#769): the expanded card used to draw its own
        // iOS-16-era faux glass (`.ultraThinMaterial` + a cold white-gradient
        // rim) while the collapsed dock had already moved to the dual-track
        // engine — so opening the composer visibly "dropped a generation".
        // Route it through the same `.dpGlass(.panel)` dispatcher: iOS 26 →
        // native `.glassEffect`, iOS 16–25 → the warm faux-glass fallback
        // (matching the collapsed capsule), Reduce Transparency → opaque warm
        // fill. The cold white rim is gone; the rim now comes from the engine.
        .dpGlass(.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, DSSpacing.lg)
        .padding(.top, 10)
        .padding(.bottom, 14)
        // Expanded composer card lift → DSElevation.glass (two-layer, dark-mode
        // adaptive), replacing the hardcoded warm-ink shadow that disappeared
        // against the dark canvas.
        .elevation(.glass)
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
        .padding(.horizontal, DSSpacing.md)
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
    @State private var lastMilestone: Int = 0
    /// Cached word count. `wordCount` was a computed property calling the O(n)
    /// `TextCount.words(text)`; because SwiftUI re-evaluates it on every body
    /// pass (and to diff `onChange(of: wordCount)`), it ran the full-text scan
    /// multiple times per keystroke. Recompute once per real text change.
    @State private var cachedWordCount: Int = 0

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
        .onAppear { startBreathing(for: affordance) }
        .onChange(of: affordance) { startBreathing(for: $0) }
    }

    /// The ambient "breathing" pulse is only ever visible for the `.empty`
    /// (translucent mic ring) and `.multimodal` (white ring) affordances —
    /// every other state paints a solid amber fill that masks `breathingOpacity`
    /// entirely. Previously a `repeatForever` animation was (re)started for ALL
    /// states, so while the user was simply typing (`.textOnly`) an invisible,
    /// perpetual animation kept driving state changes and the compositor for no
    /// visual payoff. Gate it to the states that use it, reset the rest to solid,
    /// and honor Reduce Motion (a frozen mid-pulse value would otherwise stick).
    private func startBreathing(for affordance: SendAffordance) {
        let usesBreathing: Bool
        switch affordance {
        case .empty, .multimodal: usesBreathing = true
        case .textOnly, .textAndPhoto, .locationOnly: usesBreathing = false
        }
        guard usesBreathing, !reduceMotion else {
            withAnimation(Motion.fade) { breathingOpacity = 1.0 }
            return
        }
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
        // Fire the commit haptic on THIS frame (causality) — the memo's
        // async append later fires `.successNotification()` on completion, but
        // waiting for the disk write to feed back reads as "half a beat late".
        // Mirrors WriteSheetView.handleSave(), which already commits on tap.
        Haptics.commit()
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
        // Send path: audio is saved instantly, transcription runs in the
        // background via VoiceAttachmentQueue and patches the memo later.
        // No await needed here — the memo lands within one frame.
        if let result = voiceService.stopAndSaveAudio() {
            onPressToTalkSend(result)
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
            HStack(spacing: DSSpacing.sm) {
                ForEach(pendingAttachments) { att in attachmentChip(att) }
            }
            .padding(.horizontal, DSSpacing.lg)
            .padding(.vertical, 6)
        }
    }

    private func attachmentChip(_ att: PendingAttachment) -> some View {
        let (icon, label) = chipContent(att)
        return HStack(spacing: DSSpacing.xs) {
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
        HStack(spacing: DSSpacing.xs) {
            Image(systemName: "mappin").font(DSType.labelXS).foregroundStyle(DSColor.amberAccent)
            Text(locationLabel(loc)).font(DSType.labelSM).foregroundStyle(DSColor.amberAccent).lineLimit(1)
            Spacer()
            Button(action: onClearLocation) {
                Image(systemName: "xmark.circle.fill").font(DSType.bodySM).foregroundStyle(DSColor.inkSubtle)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, DSSpacing.lg)
        .padding(.vertical, 6)
    }

    private func locationLabel(_ loc: Memo.Location) -> String {
        if let name = loc.name, !name.isEmpty { return name }
        // Reverse geocoding hasn't resolved yet — "37.7858, -122.4064" reads
        // as debug output, not a place (FINDING-007). Say what's happening
        // instead; the coordinates still ride along in the memo metadata.
        if loc.lat != nil, loc.lng != nil {
            return NSLocalizedString("composer.location.resolving", value: "已定位 · 解析地名中…", comment: "Location chip while reverse geocoding")
        }
        return NSLocalizedString("composer.location.unknown", value: "未知位置", comment: "Location chip fallback")
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
            case .empty, .textOnly, .locationOnly:
                // Single-glyph affordances share ONE Image (conditional
                // systemName) instead of separate view branches, so SwiftUI
                // identity stays stable across mic ⇄ send ⇄ pin swaps and
                // `contentTransition(.symbolEffect(.replace))` can morph the
                // glyph in place on iOS 17+ (plain crossfade on iOS 16).
                Image(systemName: simpleGlyphName)
                    .font(DSType.bodyMD)
                    .foregroundStyle(simpleGlyphColor)
                    .modifier(SymbolReplaceTransition())

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
        // Affordance transitions are already animated by the parent button's
        // `.animation(Motion.spring, value: affordance)` (which wraps this icon),
        // so an inner copy only made SwiftUI interpolate the same change twice.
        // Removed for a single, crisp morph. (P2 #7)
    }

    /// Glyph for the single-Image affordances (`.empty` / `.textOnly` /
    /// `.locationOnly`). Composite affordances render their own branches;
    /// their fallthrough here is unreachable.
    private var simpleGlyphName: String {
        switch affordance {
        case .empty:        return "mic.fill"
        case .locationOnly: return "mappin.and.ellipse"
        default:            return "arrow.up"
        }
    }

    private var simpleGlyphColor: Color {
        switch affordance {
        case .empty: return DSColor.amberAccent.opacity(breathingOpacity)
        default:     return .white
        }
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

// MARK: - SymbolReplaceTransition

/// Morphs an SF Symbol glyph swap in place (mic.fill ⇄ arrow.up ⇄ mappin)
/// instead of crossfading. iOS 17+ only (`ContentTransition.symbolEffect`);
/// inert on iOS 16 and under Reduce Motion — same pattern as
/// `CommitArmBounce` in SwipeableMemoCard.swift.
private struct SymbolReplaceTransition: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *), !reduceMotion {
            content.contentTransition(.symbolEffect(.replace))
        } else {
            content
        }
    }
}
