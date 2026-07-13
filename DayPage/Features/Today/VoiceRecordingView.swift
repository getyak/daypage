import SwiftUI
import AVFoundation
import DayPageServices

// MARK: - VoiceRecordingView

/// Bottom sheet overlay for voice recording.
/// Displayed as a half-screen modal when the microphone button is tapped.
struct VoiceRecordingView: View {

    // MARK: Callbacks

    /// Called with the final VoiceRecordingResult after the user stops and the file is saved.
    var onComplete: (VoiceRecordingResult) -> Void

    /// Called when the user cancels (no file saved).
    var onCancel: () -> Void

    // MARK: Private State

    @StateObject private var voiceService = VoiceService.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var didWarnLong = false

    // MARK: - Timer Color

    /// Thresholds are shared via `RecordingLimits`; this legacy sheet's palette
    /// reads against the light surface.
    private var timerColor: Color {
        switch RecordingLimits.stage(for: voiceService.elapsedSeconds) {
        case .critical: return DSColor.error
        case .warning:  return DSColor.accentAmber
        case .normal:   return DSColor.onSurface
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle
            RoundedRectangle(cornerRadius: 2)
                .fill(DSColor.outline)
                .frame(width: 36, height: 4)
                .padding(.top, 12)

            // Title
            Text(NSLocalizedString("voice.recording.title", comment: "Voice memo title"))
                .headlineCapsStyle()
                .foregroundColor(DSColor.onSurface)
                .padding(.top, 20)

            Divider()
                .background(DSColor.outline)
                .padding(.top, 16)

            Spacer()

            // Timer display
            timerSection

            // Real-time waveform visualizer
            waveformView
                .padding(.horizontal, 24)
                .padding(.top, 12)

            // Post-record transcription notice
            Text(NSLocalizedString("voice.recording.autoTranscribe", value: "停止后自动转写", comment: "Voice recording — hint shown beneath waveform"))
                .bodySMStyle()
                .foregroundColor(DSColor.onSurfaceVariant.opacity(0.7))
                .padding(.top, 12)

            Spacer()

            // State message (e.g., "Transcribing…")
            statusMessage

            Spacer()

            // Control buttons
            controlButtons
                .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity)
        .background(DSColor.surface)
        .onAppear {
            didWarnLong = false
            // Guard against re-entry: a fast double-tap on the mic-hero, or a
            // previously-stuck session from a press-to-talk gesture, can land
            // us here while VoiceService is still active. Starting again would
            // tear down the live AVAudioRecorder mid-frame and orphan its file.
            // Only kick off a new recording when the service is genuinely idle.
            guard voiceService.state == .idle else { return }
            Task {
                await voiceService.startRecording()
            }
        }
        .onChange(of: voiceService.elapsedSeconds) { seconds in
            if !didWarnLong && voiceService.state == .recording && seconds >= RecordingLimits.amberThreshold {
                didWarnLong = true
                Haptics.soft()
            }
        }
        .onChange(of: voiceService.state) { newState in
            if case .failed(let msg) = newState {
                // Show the error message in the app-wide banner before dismissing.
                BannerCenter.shared.show(AppBannerModel(
                    kind: .error,
                    title: "录音失败",
                    subtitle: msg,
                    autoDismiss: true
                ))
                onCancel()
            }
        }
    }

    // MARK: - Timer Display

    @ViewBuilder
    private var timerSection: some View {
        VStack(spacing: 8) {
            // Pulsing recording indicator
            if voiceService.state == .recording {
                Circle()
                    .fill(DSColor.error)
                    .frame(width: 12, height: 12)
                    .overlay(
                        Circle()
                            .stroke(DSColor.error.opacity(0.4), lineWidth: 8)
                            .scaleEffect(1.5)
                    )
                    .animation(reduceMotion ? nil : Motion.sustain.repeatForever(autoreverses: true),
                               value: voiceService.state)
            } else if voiceService.state == .paused {
                Image(systemName: "pause.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(DSColor.onSurfaceVariant)
            } else {
                Circle()
                    .fill(DSColor.surfaceContainerHigh)
                    .frame(width: 12, height: 12)
            }

            Text(formattedTime(voiceService.elapsedSeconds))
                // TODO: no DSType match, kept raw — 56pt hero timer far exceeds the
                // mono ramp (mono9…mono11); no semantic token for a display-size mono readout.
                .font(.system(size: 56, weight: .bold, design: .monospaced))
                .foregroundColor(timerColor)
                .monospacedDigit()
                .animation(reduceMotion ? nil : Motion.fade, value: timerColor)

            if voiceService.elapsedSeconds >= RecordingLimits.amberThreshold {
                Text(NSLocalizedString("voice_recording_soft_cap_hint", comment: "建议 5 分钟内"))
                    .font(DSFonts.jetBrainsMono(size: 12, relativeTo: .caption))
                    .foregroundColor(DSColor.accentAmber)
                    .transition(.opacity)
                    .animation(reduceMotion ? nil : Motion.fade, value: voiceService.elapsedSeconds >= RecordingLimits.amberThreshold)
            }
        }
    }

    // MARK: - Waveform View

    @ViewBuilder
    private var waveformView: some View {
        let barCount = 40
        let bars = voiceService.waveformHistory
        HStack(alignment: .center, spacing: 2) {
            ForEach(0 ..< barCount, id: \.self) { i in
                let level = i < bars.count ? bars[i] : 0.04
                RoundedRectangle(cornerRadius: 1)
                    .fill(DSColor.amberArchival)
                    // Bar height maps the live meter level directly — no
                    // implicit animation. 40 per-bar easeOuts chasing a 30fps
                    // metering feed made the waveform lag its own input; the
                    // sliding history window already provides the motion.
                    .frame(width: 3, height: max(4, CGFloat(level) * 32))
            }
        }
        .frame(height: 36)
    }

    // MARK: - Status Message

    @ViewBuilder
    private var statusMessage: some View {
        switch voiceService.state {
        case .requesting:
            Text(NSLocalizedString("voice.recording.requestingMic", value: "请求麦克风权限…", comment: "Voice recording — status while requesting mic permission"))
                .bodySMStyle()
                .foregroundColor(DSColor.onSurfaceVariant)
        case .recording:
            Text(NSLocalizedString("voice.recording.status.recording", value: "正在录音", comment: "Voice recording — active status"))
                .bodySMStyle()
                .foregroundColor(DSColor.error)
        case .paused:
            Text(NSLocalizedString("voice.recording.status.paused", value: "已暂停", comment: "Voice recording — paused status"))
                .bodySMStyle()
                .foregroundColor(DSColor.onSurfaceVariant)
        case .interrupted:
            // System interruption (call / Siri / alarm). Surface the
            // localized message produced by VoiceService so the user knows
            // the audio is preserved and will auto-resume when possible.
            Text(voiceService.interruptionMessage ?? NSLocalizedString(
                "voice.interruption.paused",
                value: "录音已暂停 — 通话/Siri 结束后会自动恢复",
                comment: "Fallback shown when interruption message is missing"
            ))
                .bodySMStyle()
                .foregroundColor(DSColor.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        case .processing:
            HStack(spacing: 8) {
                ProgressView()
                    .tint(DSColor.onSurfaceVariant)
                Text(NSLocalizedString("voice.recording.status.transcribing", value: "正在转写…", comment: "Voice recording — Whisper transcribing status"))
                    .bodySMStyle()
                    .foregroundColor(DSColor.onSurfaceVariant)
            }
        case .done:
            Text("转写完成")
                .bodySMStyle()
                .foregroundColor(DSColor.onSurface)
        case .failed(let msg):
            Text(msg)
                .bodySMStyle()
                .foregroundColor(DSColor.error)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        case .idle:
            EmptyView()
        }
    }

    // MARK: - Control Buttons

    @ViewBuilder
    private var controlButtons: some View {
        let isActive = voiceService.state == .recording || voiceService.state == .paused
        let isProcessing = voiceService.state == .processing
        let canSave = isActive && !isProcessing

        // Pause / Resume row (only when active)
        if isActive {
            HStack(spacing: 0) {
                Button(action: {
                    if voiceService.state == .recording {
                        voiceService.pauseRecording()
                    } else {
                        voiceService.resumeRecording()
                    }
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: voiceService.state == .recording ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .semibold))
                        Text(voiceService.state == .recording
                            ? NSLocalizedString("voice.recording.pause", value: "暂停", comment: "Voice recording — pause button")
                            : NSLocalizedString("voice.recording.resume", value: "继续", comment: "Voice recording — resume button"))
                            .monoLabelStyle(size: 12)
                    }
                    .foregroundColor(DSColor.onSurface)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(DSColor.surfaceContainerHigh)
                }
                .buttonStyle(.plain)
                .cornerRadius(0)
                .accessibilityLabel(voiceService.state == .paused
                    ? NSLocalizedString("voice.recording.a11y.resume", value: "继续录音", comment: "Voice recording — resume button a11y label")
                    : NSLocalizedString("voice.recording.a11y.pause",  value: "暂停录音", comment: "Voice recording — pause button a11y label"))
                .accessibilityHint(NSLocalizedString("voice.recording.a11y.pause.hint", value: "暂停或继续当前录音", comment: "Voice recording — pause/resume hint"))
            }
            .padding(.horizontal, 0)
        }

        // 丢弃 | 保存 — inset rounded action bar. The old full-bleed square
        // blocks (hard 90° brown slab, English "SAVE"/"PAUSE" in an otherwise
        // Chinese flow) clashed with the app's continuous-radius card language
        // (FINDING-009).
        HStack(spacing: 12) {
            Button(action: {
                voiceService.cancelRecording()
                onCancel()
            }) {
                Text(NSLocalizedString("voice.recording.discard", comment: "Discard recording"))
                    .monoLabelStyle(size: 14)
                    .foregroundColor(isProcessing ? DSColor.onSurfaceVariant : DSColor.onSurface)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(DSColor.surfaceContainerHigh)
                    .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
            }
            .disabled(isProcessing)
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("voice.recording.a11y.discard", value: "丢弃录音", comment: "Voice recording — discard button a11y label"))
            .accessibilityHint(NSLocalizedString("voice.recording.a11y.discard.hint", value: "永久删除此次录音内容", comment: "Voice recording — discard hint"))

            // 保存 — send path: audio saves instantly, transcription runs in the
            // background via VoiceAttachmentQueue and patches the memo later.
            Button(action: {
                guard canSave else { return }
                if let result = voiceService.stopAndSaveAudio() {
                    onComplete(result)
                } else {
                    onCancel()
                }
            }) {
                Text(NSLocalizedString("voice.recording.save", value: "保存", comment: "Save recording"))
                    .monoLabelStyle(size: 14)
                    .foregroundColor(canSave ? DSColor.onPrimary : DSColor.onSurfaceVariant)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(canSave ? DSColor.primary : DSColor.surfaceContainerLow)
                    .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
            }
            .disabled(!canSave)
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("voice.recording.a11y.save", value: "保存录音", comment: "Voice recording — save button a11y label"))
            .accessibilityHint(NSLocalizedString("voice.recording.a11y.save.hint", value: "停止录音并发送给 AI 转写", comment: "Voice recording — save hint"))
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Helpers

    private func formattedTime(_ seconds: Int) -> String {
        seconds.mmss
    }
}
