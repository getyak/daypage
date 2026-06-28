import SwiftUI
import UIKit

// MARK: - PressToTalkButton
//
// Dual-mode microphone button:
//
//   Short tap (< 0.35s hold):
//     • Press-and-release inside the threshold fires `onTapShortRelease`.
//       The parent decides what that means (e.g. open a continuous-recording
//       sheet); this view emits no haptic for the short-tap path so callers
//       own the feedback story.
//
//   Long press (>= 0.35s hold):
//     WeChat-style press-to-talk flow (original behaviour, unchanged):
//     • Press-down              → start recording + light haptic
//     • Hold in place           → continue recording, live waveform
//     • Release in place        → stop + send immediately + medium haptic
//     • Drag up >= 80pt         → "cancel armed" (heavy haptic on entry)
//     • Drag left >= 80pt       → "transcribe armed" (medium haptic on entry)
//     • Release in cancel zone  → discard recording + light haptic
//     • Release in transcribe   → VoiceService.transcribe → fill text, do NOT send
//
// The overlay UI is rendered by `RecordingOverlayView` — the parent owns the
// overlay placement and mounts it while `onGestureStateChange` reports the
// gesture is active.

/// Coarse gesture phase emitted upwards so the parent can mount / dismiss the
/// RecordingOverlayView with an appropriate transition.
enum PressToTalkPhase: Equatable {
    case idle
    /// User is pressing but hasn't crossed the long press threshold yet (0-0.35s).
    /// Parent should show a brief ring + "再按住一下" hint.
    case preRecording
    case recording
    case cancelArmed
    case transcribeArmed
    /// Emitted briefly between a transcribe-armed release and the async Whisper
    /// call finishing. The parent keeps the overlay visible + swaps to a spinner.
    case transcribing
}

struct PressToTalkButton: View {

    // MARK: Inputs

    /// Called on long-press-down (>= longPressThreshold). Parent should start
    /// VoiceService.startRecording() for the press-to-talk flow.
    var onPressStart: () -> Void

    /// Called on release-in-place (long-press flow). Parent should stop-and-transcribe
    /// and submit the resulting memo immediately.
    var onReleaseSend: () -> Void

    /// Called on release in the cancel-armed zone (long-press flow). Parent should discard.
    var onReleaseCancel: () -> Void

    /// Called on release in the transcribe-armed zone (long-press flow). Parent should stop,
    /// transcribe audio, fill TodayViewModel.draftText, and NOT submit.
    var onReleaseTranscribe: () -> Void

    /// Reports phase transitions upward so parent can update the overlay state.
    var onPhaseChange: (PressToTalkPhase) -> Void

    /// Called when a simple tap (press < 0.35s then release without long-pressing) is detected.
    /// Parent can show a "按住说话" toast.
    var onTapShortRelease: () -> Void = {}

    /// Diameter of the circular button and its hit target.
    var size: CGFloat = 40

    /// Override idle-state background. Recording/cancel/transcribe phases
    /// keep their own colors regardless of this value.
    var idleBackgroundColor: Color? = nil

    /// Override idle-state icon color.
    var idleIconColor: Color? = nil

    // MARK: Constants

    /// Duration (seconds) that separates a "tap" from a "hold". Under this threshold
    /// the gesture is treated as a tap → persistent recording bar.
    private let longPressThreshold: TimeInterval = 0.25

    /// Duration of the pulsing ring animation cycle (one full scale-up + fade-out).
    private let ringAnimationDuration: TimeInterval = 0.8

    // MARK: State

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var isPressing: Bool = false
    @State private var currentPhase: PressToTalkPhase = .idle
    @State private var lastTranslation: CGSize = .zero
    @State private var pressStartTime: Date? = nil
    @State private var ringScale: CGFloat = 1.0
    @State private var ringOpacity: Double = 0.0

    // MARK: Body

    var body: some View {
        ZStack {
            // Pulsing ring — visible only during preRecording phase
            if currentPhase == .preRecording {
                Circle()
                    .stroke(DSColor.primary.opacity(ringOpacity), lineWidth: 2)
                    .frame(width: size * ringScale, height: size * ringScale)
                    .allowsHitTesting(false)
            }

            Image(systemName: "mic.fill")
                .font(.system(size: size * 0.45, weight: .regular))
                .foregroundColor(iconColor)
                .frame(width: size, height: size)
                .background(backgroundColor)
                .clipShape(Circle())
                .scaleEffect(currentPhase == .idle ? 1.0 : 1.08)
                .animation(.easeOut(duration: 0.12), value: currentPhase)
                .contentShape(Circle())
                .highPriorityGesture(dragGesture)
        }
    }

    // MARK: - Gesture

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isPressing) { _, state, _ in
                state = true
            }
            .onChanged { value in
                if currentPhase == .idle {
                    pressStartTime = Date()
                    // Enter preRecording phase immediately — show ring + hint
                    currentPhase = .preRecording
                    onPhaseChange(.preRecording)
                    startRingPulse()
                }

                // Once we've held past the threshold, commit to press-to-talk mode
                if currentPhase == .preRecording,
                   let start = pressStartTime,
                   Date().timeIntervalSince(start) >= longPressThreshold {
                    emitHaptic(HapticFeedback.heavy)
                    stopRingPulse()
                    onPressStart()
                    currentPhase = .recording
                    onPhaseChange(.recording)
                }

                guard currentPhase != .idle && currentPhase != .preRecording else { return }

                lastTranslation = value.translation
                let newPhase = derivePhase(from: value.translation)

                if newPhase != currentPhase {
                    switch newPhase {
                    case .cancelArmed where currentPhase != .cancelArmed:
                        emitHaptic(InputTokens.cancelArmHaptic)
                    case .transcribeArmed where currentPhase != .transcribeArmed:
                        emitHaptic(InputTokens.transcribeArmHaptic)
                    default:
                        break
                    }
                    currentPhase = newPhase
                    onPhaseChange(newPhase)
                }
            }
            .onEnded { value in
                defer {
                    pressStartTime = nil
                }

                // Short tap — never crossed threshold, still in preRecording phase.
                // Haptic is intentionally not emitted here: the short-tap callback
                // owns its own feedback (e.g. opening a sheet) and a duplicate
                // light impact at this layer would double-buzz on every tap.
                if let start = pressStartTime,
                   Date().timeIntervalSince(start) < longPressThreshold,
                   currentPhase == .preRecording {
                    stopRingPulse()
                    currentPhase = .idle
                    onPhaseChange(.idle)
                    lastTranslation = .zero
                    onTapShortRelease()
                    return
                }

                let translation = value.translation != .zero ? value.translation : lastTranslation
                let endPhase = derivePhase(from: translation)

                switch endPhase {
                case .cancelArmed:
                    emitHaptic(InputTokens.cancelReleaseHaptic)
                    onReleaseCancel()
                case .transcribeArmed:
                    emitHaptic(InputTokens.transcribeReleaseHaptic)
                    currentPhase = .transcribing
                    onPhaseChange(.transcribing)
                    onReleaseTranscribe()
                    lastTranslation = .zero
                    return
                default:
                    emitHaptic(InputTokens.sendReleaseHaptic)
                    onReleaseSend()
                }

                currentPhase = .idle
                onPhaseChange(.idle)
                lastTranslation = .zero
            }
    }

    // MARK: - Ring Animation

    private func startRingPulse() {
        // Reduce Motion: show a calm static ring instead of an infinitely
        // expanding/fading pulse, which can cause vestibular discomfort and
        // carries a small battery cost while held. (Mirrors the guard used by
        // InputBarV4's BreathingCaretModifier.)
        guard !reduceMotion else {
            ringScale = 1.2
            ringOpacity = 0.35
            return
        }
        ringScale = 1.0
        ringOpacity = 0.5
        withAnimation(
            .easeInOut(duration: ringAnimationDuration).repeatForever(autoreverses: false)
        ) {
            ringScale = 1.35
            ringOpacity = 0.0
        }
    }

    private func stopRingPulse() {
        ringScale = 1.0
        ringOpacity = 0.0
    }

    // MARK: - Helpers

    /// Map the drag translation onto an exclusive phase. Cancel wins over
    /// transcribe when both thresholds are crossed — "cancel" is the safer
    /// default on ambiguous diagonal swipes.
    private func derivePhase(from translation: CGSize) -> PressToTalkPhase {
        let dy = -translation.height                   // positive = swipe up
        let dx = -translation.width                    // positive = swipe left
        let upCrossed = dy >= InputTokens.cancelSwipeThreshold
        let leftCrossed = dx >= InputTokens.transcribeSwipeThreshold

        if upCrossed && dy >= dx {
            return .cancelArmed
        }
        if leftCrossed {
            return .transcribeArmed
        }
        return .recording
    }

    /// V6 InputTokens express haptic intent as `() -> Void` closures that
    /// already bind to the right HapticFeedback.* call, so we just invoke.
    private func emitHaptic(_ haptic: () -> Void) {
        haptic()
    }

    // MARK: - Visual Style

    private var iconColor: Color {
        switch currentPhase {
        case .preRecording: return DSColor.primary
        case .cancelArmed: return DSColor.error
        case .transcribeArmed: return Color(red: 0.12, green: 0.30, blue: 0.65)
        case .recording: return DSColor.onPrimary
        default: return idleIconColor ?? DSColor.onSurface
        }
    }

    private var backgroundColor: Color {
        switch currentPhase {
        case .preRecording: return DSColor.primaryContainer
        case .cancelArmed: return DSColor.errorContainer
        case .transcribeArmed: return Color(red: 0.85, green: 0.92, blue: 1.0)
        case .recording, .transcribing: return DSColor.primary
        default: return idleBackgroundColor ?? DSColor.surfaceContainerHigh
        }
    }
}
