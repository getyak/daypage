import SwiftUI
import DayPageServices

// MARK: - WaveformStripView
//
// A pure, reusable waveform strip — renders an array of normalized magnitudes
// (0…1) as rounded amber bars. Faithful to composer.jsx:33-46 `Waveform`:
//   • each bar: `width`pt wide, `gap`pt apart, height scaled to `maxHeight`
//   • per-bar opacity = 0.55 + 0.45 * magnitude (louder → brighter)
//   • 80ms linear height transition per bar (the only motion exception here)
//
// The design default strip is 64 bars · 2pt width · 2pt gap · 36pt height
// (RecordingSheet); the Dynamic Island mini strip reuses this at 18 bars ·
// 1.6pt width · 1.5pt gap · 18pt height.

struct WaveformStripView: View {

    /// Normalized magnitudes, each in 0…1. The view renders `bars.count` bars.
    let bars: [Float]
    /// Bar color (design: accentSoft #F5EDE3 on the dark recording surface).
    var color: Color = DSTokens.Colors.accentSoft
    /// Width of each bar in points.
    var barWidth: CGFloat = 2
    /// Horizontal gap between bars in points.
    var gap: CGFloat = 2
    /// Maximum bar height in points (loudest sample reaches this).
    var maxHeight: CGFloat = 36

    var body: some View {
        HStack(alignment: .center, spacing: gap) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, raw in
                let mag = CGFloat(min(max(raw, 0), 1))
                Capsule(style: .continuous)
                    .fill(color.opacity(0.55 + 0.45 * Double(mag)))
                    .frame(width: barWidth, height: max(barWidth, mag * maxHeight))
                    // motion-exception: 80ms bar-height easing mirrors the
                    // design's `transition: height 80ms linear`.
                    .animation(.linear(duration: 0.08), value: mag)
            }
        }
        .frame(height: maxHeight)
        .frame(maxWidth: .infinity)
        .clipped()
    }
}

// MARK: - RecordingSheetView
//
// Dark warm bottom sheet shown while the user is actively recording — the v8
// 「日式美术馆」 recording surface (composer.jsx:414-481). Sits at the bottom of
// the screen above the home indicator:
//   • recordingBg (#2D1E0C @ 0.92) surface, 34pt corner radius, 22pt padding
//   • header: pulsing recordingRed dot + "录音中" mono label · 28pt mono timer
//   • 64-bar amber waveform inside a faint inset trough
//   • live transcript preview line + blinking caret
//   • dual buttons: 取消 (cancel) / 停止并转写 (stop & transcribe)
//
// Presentation-only: the parent owns recording state and wires the two
// callbacks. It accepts a live `[Float]` waveform so it consumes the same
// VoiceService.waveformHistory the old overlay accepted but never rendered.

struct RecordingSheetView: View {

    /// Elapsed recording time in whole seconds (drives the mono timer).
    let elapsedSeconds: Int
    /// Live normalized waveform magnitudes (0…1) from the recorder.
    let waveform: [Float]
    /// Optional live transcript preview (partial STT). Empty → placeholder line.
    var transcriptPreview: String = ""
    /// Cancel — discard the recording.
    let onCancel: () -> Void
    /// Stop & transcribe — finish the recording and run STT.
    let onAccept: () -> Void

    @State private var pulse: Bool = false
    @State private var caretOn: Bool = true
    @State private var didWarnLong: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Timer tint: off-white by default, amber past 5:00, red past 9:00.
    /// Thresholds are shared via `RecordingLimits`; colors are `DSColor`
    /// semantic tokens (keeps the design-tokens drift check green). This sheet's
    /// palette reads against the dark warm surface.
    private var timerColor: Color {
        switch RecordingLimits.stage(for: elapsedSeconds) {
        case .critical: return DSTokens.Colors.recordingRed
        case .warning:  return DSColor.warnAmber
        case .normal:   return DSColor.onRecording
        }
    }

    /// Fixed 64-bar strip: pad/trim the incoming history to exactly 64 samples
    /// so the trough never reflows. Newest samples sit at the right edge.
    private var normalizedBars: [Float] {
        let count = 64
        if waveform.count >= count {
            return Array(waveform.suffix(count))
        }
        return Array(repeating: Float(0), count: count - waveform.count) + waveform
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header — status dot + label · timer
            HStack(alignment: .center) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(DSTokens.Colors.recordingRed)
                        .frame(width: 10, height: 10)
                        .overlay(
                            Circle()
                                .fill(DSTokens.Colors.recordingRed.opacity(0.18))
                                .frame(width: 18, height: 18)
                        )
                        .scaleEffect(reduceMotion ? 1 : (pulse ? 1.0 : 0.7))
                        .opacity(reduceMotion ? 1 : (pulse ? 1.0 : 0.6))
                        .animation(
                            reduceMotion ? nil :
                                .easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                            value: pulse
                        )

                    Text(NSLocalizedString("recording.sheet.status", comment: "Recording status label"))
                        .font(DSFonts.jetBrainsMono(size: 12, weight: .medium))
                        .tracking(1.4)
                        .textCase(.uppercase)
                        .foregroundColor(DSTokens.Colors.accentSoft)
                }

                Spacer()

                Text(formattedTime(elapsedSeconds))
                    .font(DSFonts.jetBrainsMono(size: 28, weight: .medium))
                    .tracking(1.5)
                    .monospacedDigit()
                    .foregroundColor(timerColor)
                    .animation(reduceMotion ? nil : Motion.fade, value: timerColor)
            }
            .padding(.bottom, 14)

            // Soft-cap hint — surfaces once the take crosses 5:00 so the user
            // knows a long recording approaches the transcription limit.
            if elapsedSeconds >= RecordingLimits.amberThreshold {
                Text(NSLocalizedString("voice_recording_soft_cap_hint", comment: "建议 5 分钟内"))
                    .font(DSFonts.jetBrainsMono(size: 11))
                    .foregroundColor(timerColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 10)
                    .transition(.opacity)
                    .animation(reduceMotion ? nil : Motion.fade, value: elapsedSeconds >= RecordingLimits.amberThreshold)
            }

            // Waveform trough — faint inset panel hosting the 64-bar strip.
            WaveformStripView(
                bars: normalizedBars,
                color: DSTokens.Colors.accentSoft,
                barWidth: 2,
                gap: 2,
                maxHeight: 36
            )
            .padding(.horizontal, 14)
            .frame(height: 56)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                    .fill(DSColor.onRecording.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                    .strokeBorder(DSColor.onRecording.opacity(0.08), lineWidth: 0.5)
            )

            // Live transcript preview + blinking caret.
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(transcriptPreview.isEmpty
                     ? NSLocalizedString("recording.sheet.listening", comment: "Recording transcript placeholder")
                     : transcriptPreview)
                    .font(DSFonts.inter(size: 13))
                    .foregroundColor(DSTokens.Colors.accentSoft.opacity(0.65))
                    .lineSpacing(2)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Rectangle()
                    .fill(DSTokens.Colors.accentSoft)
                    .frame(width: 2, height: 13)
                    .opacity(caretOn ? 1 : 0)

                Spacer(minLength: 0)
            }
            .padding(.top, 10)

            // Actions — 取消 / 停止并转写
            HStack(spacing: 10) {
                Button(action: onCancel) {
                    Text(NSLocalizedString("recording.sheet.cancel", comment: "Cancel recording"))
                        .font(DSFonts.inter(size: 14, weight: .medium))
                        .foregroundColor(DSTokens.Colors.accentSoft)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(
                            Capsule().fill(DSColor.onRecording.opacity(0.10))
                        )
                }
                .buttonStyle(.plain)

                Button(action: onAccept) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .semibold))
                        Text(NSLocalizedString("recording.sheet.accept", comment: "Stop and transcribe"))
                            .font(DSFonts.inter(size: 14, weight: .semibold))
                    }
                    .foregroundColor(DSTokens.Colors.recordingBg)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(
                        Capsule().fill(DSTokens.Colors.accentSoft)
                    )
                }
                .buttonStyle(.plain)
                // Design weights the primary button 1.6 : 1 against cancel.
                .layoutPriority(1.6)
            }
            .padding(.top, 18)
        }
        .padding(EdgeInsets(top: 22, leading: 22, bottom: 24, trailing: 22))
        .background(
            RoundedRectangle(cornerRadius: DSTokens.Radii.recording, style: .continuous)
                .fill(DSTokens.Colors.recordingBg.opacity(0.92))
        )
        .shadow(color: Color(red: 0.157, green: 0.098, blue: 0.020).opacity(0.55), radius: 30, x: 0, y: 16)
        .padding(.horizontal, 14)
        .padding(.bottom, 34)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .onAppear {
            pulse = true
            startCaretBlink()
        }
        .onChange(of: elapsedSeconds) { seconds in
            // Fire a single soft haptic the moment the take crosses 5:00.
            if !didWarnLong && seconds >= RecordingLimits.amberThreshold {
                didWarnLong = true
                Haptics.soft()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(NSLocalizedString("recording.sheet.a11y", comment: "Recording in progress"))
        .accessibilityValue(formattedTime(elapsedSeconds))
    }

    // MARK: - Helpers

    private func startCaretBlink() {
        guard !reduceMotion else { return }
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 530_000_000)
                caretOn.toggle()
            }
        }
    }

    private func formattedTime(_ seconds: Int) -> String {
        seconds.mmss
    }
}

// MARK: - Preview

#if DEBUG
struct RecordingSheetView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            DSTokens.Colors.bgWarm.ignoresSafeArea()
            RecordingSheetView(
                elapsedSeconds: 73,
                waveform: (0..<64).map { _ in Float.random(in: 0.05...1.0) },
                transcriptPreview: "昨天晚上的咖啡馆氛围超好，开到 10 点 —",
                onCancel: {},
                onAccept: {}
            )
        }
    }
}
#endif
