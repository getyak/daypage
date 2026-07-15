import SwiftUI
import DayPageServices

// MARK: - DockVoiceGesture
//
// Issue #821: whole-dock press-to-talk. The WeChat-style hold gesture used to
// live on the 50×44 mic orb only (PressToTalkButton), which made blind
// thumb-presses miss. This modifier lifts the same state machine onto the
// ENTIRE dock capsule: press anywhere on the dock and hold ≥0.35s to record.
//
// Two invariants from the interaction audit:
//   1. Input drives displacement directly — the press-dip (scale 0.985) and
//      the cancel/transcribe color interpolation are written straight from
//      `onChanged`, never wrapped in withAnimation, so they track the finger.
//   2. The gesture host never unmounts — the dock container stays in the
//      hierarchy across idle ↔ recording; only its CONTENT cross-fades.
//      Swapping the host view mid-gesture would silently drop `onEnded`.
//
// Child buttons (+ / caret / mic / sparkle) keep their tap semantics: a tap
// releases inside the 0.35s threshold and is ignored by this gesture (the
// Button fires normally). Once recording commits, `isDockRecording` flips and
// callers gate their Button actions on it so the release-after-hold can never
// double-fire a tap action.

/// Continuous drag progress reported while recording, both in 0…1.
/// Drives the capsule's background interpolation so the finger position is
/// visible BEFORE the threshold commits (no surprise state flips).
struct DockDragProgress: Equatable {
    var cancel: CGFloat = 0      // upward drag / cancelSwipeThreshold
    var transcribe: CGFloat = 0  // leftward drag / transcribeSwipeThreshold
}

struct DockVoiceGestureModifier: ViewModifier {

    // MARK: Callbacks (same contract as PressToTalkButton)

    var onPressStart: () -> Void
    var onReleaseSend: () -> Void
    var onReleaseCancel: () -> Void
    var onReleaseTranscribe: () -> Void
    var onPhaseChange: (PressToTalkPhase) -> Void
    var onDragProgress: (DockDragProgress) -> Void

    // MARK: Constants

    /// Hold duration separating a child-button tap from press-to-talk.
    private let longPressThreshold: TimeInterval = 0.35

    // MARK: State

    @State private var currentPhase: PressToTalkPhase = .idle
    @State private var lastTranslation: CGSize = .zero
    @State private var pressStartTime: Date? = nil
    @State private var thresholdTask: Task<Void, Never>? = nil
    /// Finger-down dip. Set on press without animation intent leaking into
    /// the gesture math; released through Motion.press so the rebound feels
    /// physical and interruptible.
    @State private var pressDip: Bool = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(pressDip ? 0.985 : 1.0)
            .animation(Motion.press, value: pressDip)
            .simultaneousGesture(dragGesture)
    }

    // MARK: - Gesture

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if currentPhase == .idle {
                    pressStartTime = Date()
                    pressDip = true
                    currentPhase = .preRecording
                    onPhaseChange(.preRecording)
                    // Clock-based commit: a perfectly still hold must record
                    // too (DragGesture.onChanged only re-fires on movement).
                    thresholdTask?.cancel()
                    thresholdTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: UInt64(longPressThreshold * 1_000_000_000))
                        guard !Task.isCancelled else { return }
                        commitToRecordingIfNeeded()
                    }
                }

                // Movement past the threshold also commits (finger moved
                // before the timer fired) — single entry point.
                if currentPhase == .preRecording,
                   let start = pressStartTime,
                   Date().timeIntervalSince(start) >= longPressThreshold {
                    commitToRecordingIfNeeded()
                }

                guard currentPhase != .idle && currentPhase != .preRecording else { return }

                lastTranslation = value.translation

                // Direct-drive progress: continuous 0…1 toward each arm
                // threshold, written every frame with NO animation so the
                // capsule tint tracks the finger exactly.
                let dy = max(0, -value.translation.height)
                let dx = max(0, -value.translation.width)
                onDragProgress(DockDragProgress(
                    cancel: min(1, dy / InputTokens.cancelSwipeThreshold),
                    transcribe: min(1, dx / InputTokens.transcribeSwipeThreshold)
                ))

                let newPhase = derivePhase(from: value.translation)
                if newPhase != currentPhase {
                    switch newPhase {
                    case .cancelArmed:     InputTokens.cancelArmHaptic()
                    case .transcribeArmed: InputTokens.transcribeArmHaptic()
                    default: break
                    }
                    currentPhase = newPhase
                    onPhaseChange(newPhase)
                }
            }
            .onEnded { value in
                thresholdTask?.cancel()
                thresholdTask = nil
                pressDip = false

                // Tap released inside the threshold: this was a child-button
                // tap (or a stray tap on the capsule). No-op here — the
                // Button owns the interaction.
                if currentPhase == .preRecording {
                    currentPhase = .idle
                    onPhaseChange(.idle)
                    pressStartTime = nil
                    lastTranslation = .zero
                    onDragProgress(DockDragProgress())
                    return
                }
                guard currentPhase != .idle else { return }

                let translation = value.translation != .zero ? value.translation : lastTranslation
                let endPhase = derivePhase(from: translation)

                switch endPhase {
                case .cancelArmed:
                    InputTokens.cancelReleaseHaptic()
                    onReleaseCancel()
                case .transcribeArmed:
                    InputTokens.transcribeReleaseHaptic()
                    currentPhase = .transcribing
                    onPhaseChange(.transcribing)
                    onReleaseTranscribe()
                    pressStartTime = nil
                    lastTranslation = .zero
                    onDragProgress(DockDragProgress())
                    return
                default:
                    InputTokens.sendReleaseHaptic()
                    onReleaseSend()
                }

                currentPhase = .idle
                onPhaseChange(.idle)
                pressStartTime = nil
                lastTranslation = .zero
                onDragProgress(DockDragProgress())
            }
    }

    // MARK: - Helpers

    private func commitToRecordingIfNeeded() {
        guard currentPhase == .preRecording else { return }
        HapticFeedback.heavy()
        onPressStart()
        currentPhase = .recording
        onPhaseChange(.recording)
    }

    /// Cancel wins over transcribe on ambiguous diagonals (safer default).
    private func derivePhase(from translation: CGSize) -> PressToTalkPhase {
        let dy = -translation.height
        let dx = -translation.width
        let upCrossed = dy >= InputTokens.cancelSwipeThreshold
        let leftCrossed = dx >= InputTokens.transcribeSwipeThreshold
        if upCrossed && dy >= dx { return .cancelArmed }
        if leftCrossed { return .transcribeArmed }
        return .recording
    }
}

extension View {
    func dockVoiceGesture(
        onPressStart: @escaping () -> Void,
        onReleaseSend: @escaping () -> Void,
        onReleaseCancel: @escaping () -> Void,
        onReleaseTranscribe: @escaping () -> Void,
        onPhaseChange: @escaping (PressToTalkPhase) -> Void,
        onDragProgress: @escaping (DockDragProgress) -> Void
    ) -> some View {
        modifier(DockVoiceGestureModifier(
            onPressStart: onPressStart,
            onReleaseSend: onReleaseSend,
            onReleaseCancel: onReleaseCancel,
            onReleaseTranscribe: onReleaseTranscribe,
            onPhaseChange: onPhaseChange,
            onDragProgress: onDragProgress
        ))
    }
}

// MARK: - DockRecordingCapsuleContent
//
// The in-place recording chamber (#821 design B). While recording, the dock
// capsule does NOT get replaced — it grows taller and cross-fades its content
// into this view, so the recording surface lives exactly where the finger is
// pressing instead of teleporting to the screen top/bottom the way the old
// DynamicIsland + RecordingSheet pair did.
//
// Layout (≈112pt tall, inside the same glass capsule):
//   ● 录音中          0:07      ← pulsing red dot · mono timer
//   ▂▄▆▅▃▂▁▂▄▆▅▃▂▁▂▄▆▅          ← live 48-bar waveform, level-driven
//   ↑ 上滑取消 · ← 左滑转文字     ← quiet mono guidance
//
// Cancel / transcribe arming tints the whole chamber CONTINUOUSLY with the
// drag progress (0…1), so the user watches the surface warm toward red /
// blue as the finger travels — the threshold haptic lands on an expected
// state, never a surprise.

struct DockRecordingCapsuleContent: View {

    let phase: PressToTalkPhase
    let elapsedSeconds: Int
    let waveform: [Float]
    let dragProgress: DockDragProgress

    @State private var pulse: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Fixed 48-bar strip; newest samples at the right edge.
    private var bars: [Float] {
        let count = 48
        if waveform.count >= count { return Array(waveform.suffix(count)) }
        return Array(repeating: Float(0), count: count - waveform.count) + waveform
    }

    private var isCancelArming: Bool { dragProgress.cancel >= dragProgress.transcribe }

    /// Continuous arm tint: red for cancel, ink-blue for transcribe.
    private var armTint: Color {
        isCancelArming ? DSTokens.Colors.recordingRed : Color(red: 0.24, green: 0.42, blue: 0.78)
    }

    private var armProgress: CGFloat {
        max(dragProgress.cancel, dragProgress.transcribe)
    }

    private var statusLabel: String {
        switch phase {
        case .cancelArmed:
            return NSLocalizedString("dockvoice.status.cancel", value: "松手取消", comment: "Release to cancel")
        case .transcribeArmed:
            return NSLocalizedString("dockvoice.status.transcribe", value: "松手转文字", comment: "Release to transcribe")
        case .transcribing:
            return NSLocalizedString("dockvoice.status.transcribing", value: "正在转写", comment: "Transcribing")
        default:
            return NSLocalizedString("dockvoice.status.recording", value: "录音中", comment: "Recording")
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            // Header — pulsing dot + status · mono timer
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 7) {
                    // A recording tally-light should read as EMITTING, not as a
                    // painted dot. Flat `recordingRed` at 8pt sat only 5:1 off
                    // the brown substrate and visually dissolved into it. The
                    // hue stays (it is shared with the sheet / overlay / Dynamic
                    // Island — changing the token would ripple); what it gains
                    // is a halo, so it glows like a live indicator.
                    Circle()
                        .fill(DSTokens.Colors.recordingRed)
                        .frame(width: 8, height: 8)
                        .shadow(color: DSTokens.Colors.recordingRed.opacity(0.9), radius: 5)
                        .shadow(color: DSTokens.Colors.recordingRed.opacity(0.5), radius: 10)
                        .scaleEffect(reduceMotion ? 1 : (pulse ? 1.0 : 0.72))
                        .opacity(reduceMotion ? 1 : (pulse ? 1.0 : 0.6))
                        .animation(
                            reduceMotion ? nil : .easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                            value: pulse
                        )
                    Text(statusLabel)
                        .font(DSFonts.jetBrainsMono(size: 11, weight: .medium, relativeTo: .caption))
                        .tracking(1.3)
                        .textCase(.uppercase)
                        // Warm amber instead of flat cream — the chamber is lit
                        // by the amber orb the finger is still holding, so its
                        // labels should carry that light too (10.7:1, well past AA).
                        .foregroundColor(DSColor.warnAmber)
                        .animation(nil, value: statusLabel)
                }
                Spacer()
                Text(elapsedSeconds.mmss)
                    .font(DSFonts.jetBrainsMono(size: 20, weight: .medium, relativeTo: .title3))
                    .tracking(1.2)
                    .monospacedDigit()
                    .foregroundColor(DSColor.onRecording)
            }

            // Live waveform — level-driven, 80ms linear per bar (the only
            // motion here; matches the design's `transition: height 80ms`).
            //
            // The bars were flat `accentSoft` cream, which on the brown
            // substrate read as ash — the one element that should feel ALIVE
            // was the deadest thing in the chamber. Warm amber ties the
            // waveform to the mic orb the user just pressed, and a floor keeps
            // silence legible as a quiet line rather than invisible dust.
            WaveformStripView(
                bars: bars,
                color: DSColor.warnAmber,
                barWidth: 2.5,
                gap: 2.5,
                maxHeight: 26
            )

            // Guidance — quiet mono hints; the armed direction brightens
            // with the live drag progress (direct-drive, no animation).
            HStack(spacing: 12) {
                Label {
                    Text(NSLocalizedString("dockvoice.hint.cancel", value: "上滑取消", comment: ""))
                } icon: {
                    Image(systemName: "arrow.up")
                }
                .font(DSFonts.jetBrainsMono(size: 9, relativeTo: .caption2))
                .tracking(1.0)
                .foregroundColor(DSColor.warnAmber.opacity(
                    phase == .cancelArmed ? 1.0 : 0.45 + 0.4 * dragProgress.cancel
                ))

                Label {
                    Text(NSLocalizedString("dockvoice.hint.transcribe", value: "左滑转文字", comment: ""))
                } icon: {
                    Image(systemName: "arrow.left")
                }
                .font(DSFonts.jetBrainsMono(size: 9, relativeTo: .caption2))
                .tracking(1.0)
                .foregroundColor(DSColor.warnAmber.opacity(
                    phase == .transcribeArmed ? 1.0 : 0.45 + 0.4 * dragProgress.transcribe
                ))

                Spacer()

                Text(NSLocalizedString("dockvoice.hint.send", value: "松手发送", comment: ""))
                    .font(DSFonts.jetBrainsMono(size: 9, relativeTo: .caption2))
                    .tracking(1.0)
                    .foregroundColor(DSColor.warnAmber.opacity(armProgress > 0.15 ? 0.3 : 0.75))
            }
            .labelStyle(CompactHintLabelStyle())
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            // Warm dark recording surface + continuous arm tint overlay.
            // The tint opacity is DIRECTLY the drag progress — input drives
            // displacement; no withAnimation between finger and color.
            //
            // The substrate was a single flat fill with no rim, so against the
            // cream page the chamber read as a hole punched in the paper rather
            // than a lit booth resting on it. It now carries a subtle top-lit
            // gradient (the same "receives light from above" logic as the mic
            // orb) and a warm amber rim that separates it from the canvas.
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            DSTokens.Colors.recordingBg.opacity(0.97),
                            DSTokens.Colors.recordingBg.opacity(0.99)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(armTint.opacity(0.32 * armProgress))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    DSColor.warnAmber.opacity(0.22),
                                    DSColor.warnAmber.opacity(0.06)
                                ],
                                startPoint: .top, endPoint: .bottom
                            ),
                            lineWidth: 0.75
                        )
                )
        )
        // The chamber is a lit booth floating over the page — give it real lift
        // so it separates from the cream canvas instead of sitting flush in it.
        .shadow(color: Color.black.opacity(0.34), radius: 28, x: 0, y: 12)
        .shadow(color: Color.black.opacity(0.18), radius: 2, x: 0, y: 1)
        .onAppear { pulse = true }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(statusLabel)
        .accessibilityValue(elapsedSeconds.mmss)
    }
}

/// Icon+text hint with tightened spacing for the 9pt mono guidance row.
private struct CompactHintLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 8, weight: .semibold))
            configuration.title
        }
    }
}

// MARK: - Preview

#if DEBUG
struct DockRecordingCapsuleContent_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            DSTokens.Colors.bgWarm.ignoresSafeArea()
            VStack {
                Spacer()
                DockRecordingCapsuleContent(
                    phase: .recording,
                    elapsedSeconds: 7,
                    waveform: (0..<48).map { _ in Float.random(in: 0.05...1.0) },
                    dragProgress: DockDragProgress()
                )
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }
}
#endif
