import SwiftUI

// MARK: - DynamicIslandView
//
// Top-center recording capsule — a lightweight in-app stand-in for the system
// Dynamic Island / Live Activity, shown ONLY while a recording is active
// (composer.jsx:485-520).
//
// Design:
//   • black pill pinned 11pt below the top, horizontally centered
//   • expanded (recording): 248×37pt — pulsing recordingRed dot + mono timer
//     on the left, an 18-bar mini amber waveform on the right
//   • collapsed: 126×37pt time-only (used during the brief expand/collapse
//     transition); we never render an idle pill — the view simply isn't
//     mounted when there's nothing to record.
//
// Per the build brief: "do not render an idle black pill — only while
// recording." Callers mount this conditionally on the recording flag, so the
// view assumes it is always live when present.

struct DynamicIslandView: View {

    /// Elapsed recording time in whole seconds (drives the mono timer).
    let elapsedSeconds: Int
    /// Live normalized waveform magnitudes (0…1) from the recorder.
    let waveform: [Float]
    /// When false, the capsule renders collapsed (time-only) — used only as a
    /// transient state; callers normally pass `true` while recording.
    var expanded: Bool = true

    @State private var pulse: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let collapsedWidth: CGFloat = 126
    private let expandedWidth: CGFloat = 248
    private let height: CGFloat = 37

    // Duration warning thresholds — kept in lockstep with RecordingSheetView so
    // the capsule timer and the sheet timer warm together on long takes.
    private static let amberThreshold = 300  // 5:00
    private static let redThreshold   = 540  // 9:00
    private static let warnAmber = Color(red: 1.0, green: 0.70, blue: 0.35)

    /// Timer tint: off-white by default, amber past 5:00, red past 9:00.
    private var timerColor: Color {
        if elapsedSeconds >= Self.redThreshold {
            return DSTokens.Colors.recordingRed
        } else if elapsedSeconds >= Self.amberThreshold {
            return Self.warnAmber
        } else {
            return DSTokens.Colors.accentSoft
        }
    }

    /// Fixed 18-bar mini strip, newest samples right-aligned.
    private var miniBars: [Float] {
        let count = 18
        if waveform.count >= count {
            return Array(waveform.suffix(count))
        }
        return Array(repeating: Float(0), count: count - waveform.count) + waveform
    }

    var body: some View {
        HStack(spacing: 8) {
            if expanded {
                // Left — pulsing dot + mono timer
                HStack(spacing: 8) {
                    Circle()
                        .fill(DSTokens.Colors.recordingRed)
                        .frame(width: 8, height: 8)
                        .scaleEffect(reduceMotion ? 1 : (pulse ? 1.0 : 0.6))
                        .opacity(reduceMotion ? 1 : (pulse ? 1.0 : 0.55))
                        .animation(
                            reduceMotion ? nil :
                                .easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                            value: pulse
                        )

                    Text(formattedTime(elapsedSeconds))
                        .font(DSFonts.jetBrainsMono(size: 11, weight: .medium))
                        .tracking(1.0)
                        .monospacedDigit()
                        .foregroundColor(timerColor)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: timerColor)
                }

                Spacer(minLength: 6)

                // Right — 18-bar mini waveform
                WaveformStripView(
                    bars: miniBars,
                    color: DSTokens.Colors.accentSoft,
                    barWidth: 1.6,
                    gap: 1.5,
                    maxHeight: 18
                )
                .frame(width: 96, height: 18)
            } else {
                // Collapsed — time only, centered
                Text(formattedTime(elapsedSeconds))
                    .font(DSFonts.jetBrainsMono(size: 11, weight: .medium))
                    .tracking(1.0)
                    .monospacedDigit()
                    .foregroundColor(timerColor)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: timerColor)
            }
        }
        .padding(.leading, expanded ? 16 : 0)
        .padding(.trailing, expanded ? 12 : 0)
        .frame(width: expanded ? expandedWidth : collapsedWidth, height: height)
        .background(
            Capsule(style: .continuous).fill(Color.black)
        )
        .animation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.82), value: expanded)
        .padding(.top, 11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .transition(.move(edge: .top).combined(with: .opacity))
        .onAppear { pulse = true }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(NSLocalizedString("recording.island.a11y", comment: "Recording live activity"))
        .accessibilityValue(formattedTime(elapsedSeconds))
    }

    // MARK: - Helpers

    private func formattedTime(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Preview

#if DEBUG
struct DynamicIslandView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            DSTokens.Colors.bgWarm.ignoresSafeArea()
            DynamicIslandView(
                elapsedSeconds: 42,
                waveform: (0..<18).map { _ in Float.random(in: 0.1...1.0) },
                expanded: true
            )
        }
    }
}
#endif
