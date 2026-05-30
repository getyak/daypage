import SwiftUI

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
                            // motion-exception: dual-ring pulse 1.6s is the only allowed motion in v4
                            .easeInOut(duration: 1.6).repeatForever(autoreverses: true),
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
                            // motion-exception: dual-ring pulse 1.6s is the only allowed motion in v4
                            .easeInOut(duration: 1.6).repeatForever(autoreverses: true),
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
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.60), lineWidth: 0.5))

                    // Mic icon in center
                    Image(systemName: mode == .transcribing ? "waveform" : "mic.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(Color(red: 0.365, green: 0.188, blue: 0.0)) // warm dark amber
                }
                .frame(width: 142, height: 142)
                .onAppear {
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
                            Text("Cancel")
                                .font(DSFonts.inter(size: 11, weight: .medium))
                        }
                        .foregroundColor(Color.white.opacity(0.55))

                        VStack(spacing: 4) {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Transcribe")
                                .font(DSFonts.inter(size: 11, weight: .medium))
                        }
                        .foregroundColor(Color.white.opacity(0.55))
                    }
                    .padding(.top, 8)
                } else if mode == .cancelArmed {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.left")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Release to cancel")
                            .font(DSFonts.inter(size: 12, weight: .medium))
                    }
                    .foregroundColor(DSTokens.Colors.recordingRed)
                    .padding(.top, 8)
                } else if mode == .transcribeArmed {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Release to transcribe")
                            .font(DSFonts.inter(size: 12, weight: .medium))
                    }
                    .foregroundColor(Color(red: 0.30, green: 0.55, blue: 1.0))
                    .padding(.top, 8)
                }

                // Status + timer
                VStack(spacing: 6) {
                    Text(statusText)
                        .font(DSFonts.inter(size: 15, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.90))

                    Text(formattedTime(elapsedSeconds))
                        .font(DSFonts.jetBrainsMono(size: 24, weight: .medium))
                        .foregroundColor(Color.white)
                        .monospacedDigit()

                    if mode == .transcribing {
                        ProgressView()
                            .tint(Color.white.opacity(0.80))
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
                                Text("Cancel")
                                    .font(DSFonts.inter(size: 12, weight: .medium))
                            }
                            .foregroundColor(mode == .cancelArmed ? DSTokens.Colors.recordingRed : Color.white.opacity(0.75))
                            .frame(width: 72, height: 56)
                            .background(Color.white.opacity(mode == .cancelArmed ? 0.25 : 0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        // Save / Transcribe
                        Button {
                            // Parent handles action via gesture release
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: mode == .transcribeArmed ? "text.bubble" : "checkmark")
                                    .font(.system(size: 16, weight: .semibold))
                                Text(mode == .transcribeArmed ? "Transcribe" : "Save")
                                    .font(DSFonts.inter(size: 12, weight: .medium))
                            }
                            .foregroundColor(mode == .transcribeArmed ? Color(red: 0.30, green: 0.55, blue: 1.0) : Color.white.opacity(0.90))
                            .frame(width: 72, height: 56)
                            .background(Color.white.opacity(mode == .transcribeArmed ? 0.25 : 0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.92)))
    }

    // MARK: - Status Text

    private var statusText: String {
        switch mode {
        case .recording: return "Listening…"
        case .cancelArmed: return "Release to cancel"
        case .transcribeArmed: return "Release to transcribe"
        case .transcribing: return "Transcribing…"
        }
    }

    // MARK: - Helpers (kept for compatibility — waveform param still accepted)

    // Legacy gesture hint pill — unused by v4 overlay but kept to avoid breaking callers
    @ViewBuilder
    private func gestureHintPill(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(color)
            Text(label)
                .font(.custom("Inter-Regular", size: 11))
                .foregroundColor(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.10))
        .clipShape(Capsule())
    }

    // MARK: - Helpers

    private func formattedTime(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%02d:%02d", m, s)
    }
}
