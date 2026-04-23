import SwiftUI
import UIKit

// MARK: - PressToTalkButton
//
// Dual-mode microphone button:
//
//   Short tap (< 0.35s hold):
//     • Tap → emit onTap, parent switches to "recording bar" mode
//             (PressToTalkButton is no longer visible while recording bar is shown)
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
    case recording
    case cancelArmed
    case transcribeArmed
    /// Emitted briefly between a transcribe-armed release and the async Whisper
    /// call finishing. The parent keeps the overlay visible + swaps to a spinner.
    case transcribing
}

struct PressToTalkButton: View {

    // MARK: Inputs

    /// Called on short tap (< longPressThreshold). Parent should switch to
    /// the persistent recording bar mode.
    var onTap: () -> Void = {}

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
    private let longPressThreshold: TimeInterval = 0.35

    // MARK: State

    @GestureState private var isPressing: Bool = false
    @State private var currentPhase: PressToTalkPhase = .idle
    @State private var lastTranslation: CGSize = .zero
    @State private var pressStartTime: Date? = nil

    // MARK: Body

    var body: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: size * 0.45, weight: .regular))
            .foregroundColor(iconColor)
            .frame(width: size, height: size)
            .background(backgroundColor)
            .clipShape(Circle())
            .scaleEffect(currentPhase == .idle ? 1.0 : 1.08)
            .animation(.easeOut(duration: 0.12), value: currentPhase)
            .contentShape(Circle())
            .accessibilityLabel("点击说话")
            .accessibilityHint("单击开始录音；长按说话松手发送")
            .highPriorityGesture(dragGesture)
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
                    // Don't start recording yet — wait to see if this becomes a long press
                }

                // Once we've held past the threshold, commit to press-to-talk mode
                if currentPhase == .idle,
                   let start = pressStartTime,
                   Date().timeIntervalSince(start) >= longPressThreshold {
                    emitHaptic(InputTokens.pressDownHaptic)
                    onPressStart()
                    currentPhase = .recording
                    onPhaseChange(.recording)
                }

                guard currentPhase != .idle else { return }

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

                // Short tap — delegate to onTap for persistent recording bar
                if let start = pressStartTime,
                   Date().timeIntervalSince(start) < longPressThreshold,
                   currentPhase == .idle {
                    emitHaptic(InputTokens.pressDownHaptic)
                    currentPhase = .idle
                    onPhaseChange(.idle)
                    lastTranslation = .zero
                    onTap()
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

    private func emitHaptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let g = UIImpactFeedbackGenerator(style: style)
        g.prepare()
        g.impactOccurred()
    }

    // MARK: - Visual Style

    private var iconColor: Color {
        switch currentPhase {
        case .cancelArmed: return DSColor.error
        case .transcribeArmed: return Color(red: 0.12, green: 0.30, blue: 0.65)
        case .recording: return DSColor.onPrimary
        default: return idleIconColor ?? DSColor.onSurface
        }
    }

    private var backgroundColor: Color {
        switch currentPhase {
        case .cancelArmed: return DSColor.errorContainer
        case .transcribeArmed: return Color(red: 0.85, green: 0.92, blue: 1.0)
        case .recording, .transcribing: return DSColor.primary
        default: return idleBackgroundColor ?? DSColor.surfaceContainerHigh
        }
    }
}
