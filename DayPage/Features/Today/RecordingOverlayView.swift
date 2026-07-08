import SwiftUI
import DayPageServices

// MARK: - RecordingOverlayMode

/// Visual state of the press-to-talk overlay. Mirrors the three gesture states
/// produced by PressToTalkButton (US-008).
enum RecordingOverlayMode: Equatable {
    /// Holding in place — default waveform + timer.
    case recording
    /// Drag up crossed the cancel threshold — discard on release.
    case cancelArmed
    /// Drag left crossed the transcribe threshold — fill text on release.
    case transcribeArmed
    /// Whisper call is running after a transcribe-armed release.
    case transcribing
}

// MARK: - RecordingOverlayView
//
// Full-screen recording overlay centered on a Day-Orb-style radial gradient core,
// with dual concentric ring pulse animation per capture.jsx:474-475.
// Replaces the old card-style overlay.

struct RecordingOverlayView: View {

    let mode: RecordingOverlayMode
    let elapsedSeconds: Int
    let waveform: [Float]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Dual-pulse halo animation state
    @State private var pulseOuter: Bool = false
    @State private var pulseInner: Bool = false

    var body: some View {
        ZStack {
            // Dimmed background — warm dark recording scrim (design token),
            // not pure black, to match the v8 「日式美术馆」 recording sheet.
            DSTokens.Colors.recordingBg.opacity(0.88).ignoresSafeArea()

            VStack(spacing: 24) {
                // Orb with dual-pulse halo
                ZStack {
                    // Outer ring pulse — soft amber halo (design token accentSoft).
                    Circle()
                        .stroke(
                            DSTokens.Colors.accentSoft.opacity(pulseOuter ? 0.18 : 0.55),
                            lineWidth: 1.5
                        )
                        .frame(width: 142, height: 142)
                        .scaleEffect(pulseOuter ? 1.10 : 0.85)
                        .animation(
                            // motion-exception: dual-ring pulse 1.6s is the only allowed motion in v4.
                            // Reduce Motion → no repeatForever pulse; the ring holds its calm resting pose.
                            reduceMotion ? nil : .easeInOut(duration: 1.6).repeatForever(autoreverses: true),
                            value: pulseOuter
                        )

                    // Inner ring pulse — 0.3s phase offset via delayed onAppear
                    Circle()
                        .stroke(
                            DSTokens.Colors.accentSoft.opacity(pulseInner ? 0.18 : 0.55),
                            lineWidth: 1.5
                        )
                        .frame(width: 130, height: 130)
                        .scaleEffect(pulseInner ? 1.10 : 0.85)
                        .animation(
                            // motion-exception: dual-ring pulse 1.6s is the only allowed motion in v4.
                            // Reduce Motion → no repeatForever pulse; the ring holds its calm resting pose.
                            reduceMotion ? nil : .easeInOut(duration: 1.6).repeatForever(autoreverses: true),
                            value: pulseInner
                        )

                    // Inner core: 110pt radial gradient orb
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color(red: 1.0, green: 0.851, blue: 0.659),  // #FFD9A8
                                    Color(red: 0.659, green: 0.329, blue: 0.106) // #A8541B
                                ],
                                center: .init(x: 0.35, y: 0.30),
                                startRadius: 0,
                                endRadius: 55
                            )
                        )
                        .frame(width: 110, height: 110)
                        .shadow(color: Color(red: 1.0, green: 0.608, blue: 0.302).opacity(0.55), radius: 20, x: 0, y: 0)
                        .overlay(Circle().strokeBorder(DSColor.onRecording.opacity(0.60), lineWidth: 0.5))

                    // Mic icon in center
                    Image(systemName: mode == .transcribing ? "waveform" : "mic.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(Color(red: 0.365, green: 0.188, blue: 0.0)) // warm dark amber
                }
                .frame(width: 142, height: 142)
                .onAppear {
                    // Reduce Motion: leave both halo rings at their calm resting
                    // pose instead of starting an infinite dual-ring pulse
                    // (vestibular comfort + a small battery saving while the
                    // overlay is held). Mirrors the guards already added to
                    // PressToTalkButton.startRingPulse() and InlineMicButton.
                    guard !reduceMotion else { return }
                    pulseOuter = true
                    // 0.3s phase offset for inner ring
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        pulseInner = true
                    }
                }

                // Directional gesture arrows (US-008)
                if mode == .recording {
                    HStack(spacing: 80) {
                        VStack(spacing: 4) {
                            Image(systemName: "arrow.left")
                                .font(.system(size: 14, weight: .semibold))
                            Text(L10n.Recording.cancel)
                                .font(DSFonts.inter(size: 11, weight: .medium))
                        }
                        .foregroundColor(DSColor.onRecording.opacity(0.55))
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(Text(L10n.Recording.cancelHintA11yLabel))

                        VStack(spacing: 4) {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 14, weight: .semibold))
                            Text(L10n.Recording.transcribe)
                                .font(DSFonts.inter(size: 11, weight: .medium))
                        }
                        .foregroundColor(DSColor.onRecording.opacity(0.55))
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(Text(L10n.Recording.transcribeHintA11yLabel))
                    }
                    .padding(.top, 8)
                } else if mode == .cancelArmed {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.left")
                            .font(.system(size: 14, weight: .semibold))
                        Text(L10n.Recording.releaseToCancel)
                            .font(DSFonts.inter(size: 12, weight: .medium))
                    }
                    .foregroundColor(DSTokens.Colors.recordingRed)
                    .padding(.top, 8)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text(L10n.Recording.releaseToCancel))
                } else if mode == .transcribeArmed {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .semibold))
                        Text(L10n.Recording.releaseToTranscribe)
                            .font(DSFonts.inter(size: 12, weight: .medium))
                    }
                    .foregroundColor(DSColor.transcribeBlue)
                    .padding(.top, 8)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text(L10n.Recording.releaseToTranscribe))
                }

                // Status + timer
                VStack(spacing: 6) {
                    Text(statusText)
                        .font(DSFonts.inter(size: 15, weight: .medium))
                        .foregroundColor(DSColor.onRecording.opacity(0.90))

                    Text(formattedTime(elapsedSeconds))
                        .font(DSFonts.jetBrainsMono(size: 24, weight: .medium))
                        .foregroundColor(DSColor.onRecording)
                        .monospacedDigit()

                    if mode == .transcribing {
                        ProgressView()
                            .tint(DSColor.onRecording.opacity(0.80))
                            .scaleEffect(0.85)
                    }
                }

                // Cancel / Save buttons
                if mode == .recording || mode == .cancelArmed || mode == .transcribeArmed {
                    HStack(spacing: 20) {
                        // Cancel
                        Button {
                            // Parent handles dismiss via gesture; placeholder action
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 16, weight: .semibold))
                                Text(L10n.Recording.cancel)
                                    .font(DSFonts.inter(size: 12, weight: .medium))
                            }
                            .foregroundColor(mode == .cancelArmed ? DSTokens.Colors.recordingRed : DSColor.onRecording.opacity(0.75))
                            .frame(width: 72, height: 56)
                            .background(DSColor.onRecording.opacity(mode == .cancelArmed ? 0.25 : 0.12))
                            .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(Text(L10n.Recording.cancelA11yLabel))
                        .accessibilityHint(Text(L10n.Recording.cancelA11yHint))

                        // Save / Transcribe
                        Button {
                            // Parent handles action via gesture release
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: mode == .transcribeArmed ? "text.bubble" : "checkmark")
                                    .font(.system(size: 16, weight: .semibold))
                                Text(mode == .transcribeArmed ? L10n.Recording.transcribe : L10n.Recording.save)
                                    .font(DSFonts.inter(size: 12, weight: .medium))
                            }
                            .foregroundColor(mode == .transcribeArmed ? Color(red: 0.30, green: 0.55, blue: 1.0) : DSColor.onRecording.opacity(0.90))
                            .frame(width: 72, height: 56)
                            .background(DSColor.onRecording.opacity(mode == .transcribeArmed ? 0.25 : 0.15))
                            .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(Text(mode == .transcribeArmed ? L10n.Recording.transcribeA11yLabel : L10n.Recording.saveA11yLabel))
                        .accessibilityHint(Text(mode == .transcribeArmed ? L10n.Recording.transcribeA11yHint : L10n.Recording.saveA11yHint))
                    }
                }
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.92)))
    }

    // MARK: - Status Text

    private var statusText: String {
        switch mode {
        case .recording: return L10n.Recording.listeningString
        case .cancelArmed: return L10n.Recording.releaseToCancelString
        case .transcribeArmed: return L10n.Recording.releaseToTranscribeString
        case .transcribing: return L10n.Recording.transcribingString
        }
    }

    // MARK: - Helpers

    private func formattedTime(_ seconds: Int) -> String {
        seconds.mmss
    }
}
