import SwiftUI
import UIKit

// MARK: - PressToTalkButton
//
// WeChat-style press-to-talk microphone button for InputBarV2 (US-008).
//
// Gesture flow (via DragGesture(minimumDistance: 0)):
//   • Press-down              → start recording + light haptic
//   • Hold in place           → continue recording, live waveform
//   • Release in place        → stop + send immediately + medium haptic
//   • Drag up >= 80pt         → "cancel armed" (heavy haptic on entry)
//   • Drag left >= 80pt       → "transcribe armed" (medium haptic on entry)
//   • Release in cancel zone  → discard recording + light haptic
//   • Release in transcribe   → VoiceService.transcribe → fill text, do NOT send
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

    /// Called on press-down. Parent should start VoiceService.startRecording().
    var onPressStart: () -> Void

    /// Called on release-in-place. Parent should stop-and-transcribe and then
    /// submit the resulting memo immediately.
    var onReleaseSend: () -> Void

    /// Called on release in the cancel-armed zone. Parent should discard.
    var onReleaseCancel: () -> Void

    /// Called on release in the transcribe-armed zone. Parent should stop,
    /// transcribe audio, fill TodayViewModel.draftText, and NOT submit.
    var onReleaseTranscribe: () -> Void

    /// Reports phase transitions upward so parent can update the overlay state.
    var onPhaseChange: (PressToTalkPhase) -> Void

    /// Diameter of the circular button and its hit target. Defaults to 40pt
    /// (V2 inline mic). V3 voice-first home uses 80pt as the primary FAB.
    var size: CGFloat = 40

    // MARK: State

    /// Tracked via @GestureState so SwiftUI resets it automatically when the
    /// gesture ends (including edge cases like the touch leaving the hit area).
    @GestureState private var isPressing: Bool = false

    /// The last emitted phase. We keep it as @State (not @GestureState) so we
    /// can fire precisely-once haptics on phase-entry edges.
    @State private var currentPhase: PressToTalkPhase = .idle

    /// Latest drag translation (for reading on release — @GestureState resets
    /// before onEnded runs on some iOS versions).
    @State private var lastTranslation: CGSize = .zero

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
            .accessibilityLabel("按住说话")
            .accessibilityHint("松手发送，上滑取消，左滑转文字")
            // highPriorityGesture so the outer ScrollView doesn't steal the drag
            .highPriorityGesture(dragGesture)
    }

    // MARK: - Gesture

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isPressing) { _, state, _ in
                state = true
            }
            .onChanged { value in
                // First-edge: transitioning from idle → recording triggers
                // the press-start haptic + recording start.
                if currentPhase == .idle {
                    emitHaptic(InputTokens.pressDownHaptic)
                    onPressStart()
                    currentPhase = .recording
                    onPhaseChange(.recording)
                }

                lastTranslation = value.translation
                let newPhase = derivePhase(from: value.translation)

                if newPhase != currentPhase {
                    // Phase-entry haptics (fire precisely on the transition).
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
                let translation = value.translation != .zero ? value.translation : lastTranslation
                let endPhase = derivePhase(from: translation)

                switch endPhase {
                case .cancelArmed:
                    emitHaptic(InputTokens.cancelReleaseHaptic)
                    onReleaseCancel()
                case .transcribeArmed:
                    emitHaptic(InputTokens.transcribeReleaseHaptic)
                    // Parent will run Whisper asynchronously — briefly sit in
                    // .transcribing so the overlay can show a spinner.
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
        default: return DSColor.onSurface
        }
    }

    private var backgroundColor: Color {
        switch currentPhase {
        case .cancelArmed: return DSColor.errorContainer
        case .transcribeArmed: return Color(red: 0.85, green: 0.92, blue: 1.0)
        case .recording, .transcribing: return DSColor.primary
        default: return DSColor.surfaceContainerHigh
        }
    }
}
