import SwiftUI
import AVFoundation

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

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle
            RoundedRectangle(cornerRadius: 2)
                .fill(DSColor.outline)
                .frame(width: 36, height: 4)
                .padding(.top, 12)

            // Title
            Text("VOICE MEMO")
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

            // Live transcription display
            liveTranscriptView
                .padding(.horizontal, 24)
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
            Task {
                await voiceService.startRecording()
            }
        }
        .onChange(of: voiceService.state) { newState in
            if case .failed(let msg) = newState {
                // Propagate failure so TodayView can show a toast then dismiss
                // We cancel here so the overlay gets dismissed via onCancel path
                _ = msg
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
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true),
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
                .font(.system(size: 56, weight: .bold, design: .monospaced))
                .foregroundColor(DSColor.onSurface)
                .monospacedDigit()
        }
    }

    // MARK: - Live Transcript View

    @ViewBuilder
    private var liveTranscriptView: some View {
        let isRecordingOrPaused = voiceService.state == .recording || voiceService.state == .paused
        if isRecordingOrPaused || !voiceService.liveTranscript.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "waveform")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DSColor.onSurfaceVariant)
                    Text("实时转写")
                        .font(.custom("JetBrainsMono-Regular", fixedSize: 10))
                        .foregroundColor(DSColor.onSurfaceVariant)
                    Spacer()
                }

                if voiceService.liveTranscript.isEmpty {
                    Text("等待语音输入…")
                        .bodySMStyle()
                        .foregroundColor(DSColor.onSurfaceVariant.opacity(0.5))
                        .italic()
                } else {
                    Text(voiceService.liveTranscript)
                        .bodySMStyle()
                        .foregroundColor(DSColor.onSurface)
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                        .animation(.easeInOut(duration: 0.15), value: voiceService.liveTranscript)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DSColor.surfaceContainerLow)
            .cornerRadius(8)
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
                    .frame(width: 3, height: max(4, CGFloat(level) * 32))
                    .animation(.easeOut(duration: 0.05), value: level)
            }
        }
        .frame(height: 36)
    }

    // MARK: - Status Message

    @ViewBuilder
    private var statusMessage: some View {
        switch voiceService.state {
        case .requesting:
            Text("请求麦克风权限…")
                .bodySMStyle()
                .foregroundColor(DSColor.onSurfaceVariant)
        case .recording:
            Text("正在录音")
                .bodySMStyle()
                .foregroundColor(DSColor.error)
        case .paused:
            Text("已暂停")
                .bodySMStyle()
                .foregroundColor(DSColor.onSurfaceVariant)
        case .processing:
            HStack(spacing: 8) {
                ProgressView()
                    .tint(DSColor.onSurfaceVariant)
                Text("正在转写…")
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
                        Text(voiceService.state == .recording ? "PAUSE" : "RESUME")
                            .font(.custom("JetBrainsMono-Regular", fixedSize: 12))
                    }
                    .foregroundColor(DSColor.onSurface)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(DSColor.surfaceContainerHigh)
                }
                .buttonStyle(.plain)
                .cornerRadius(0)
            }
            .padding(.horizontal, 0)
        }

        // DISCARD | SAVE full-width bottom buttons
        HStack(spacing: 0) {
            // DISCARD (white bg, black text)
            Button(action: {
                voiceService.cancelRecording()
                onCancel()
            }) {
                Text("DISCARD")
                    .font(.custom("JetBrainsMono-Regular", fixedSize: 14))
                    .foregroundColor(isProcessing ? DSColor.onSurfaceVariant : DSColor.onSurface)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(DSColor.surface)
            }
            .disabled(isProcessing)
            .buttonStyle(.plain)
            .cornerRadius(0)

            // Separator
            Rectangle()
                .fill(DSColor.outlineVariant)
                .frame(width: 1, height: 56)

            // SAVE (black bg, white text)
            Button(action: {
                guard canSave else { return }
                Task {
                    if let result = await voiceService.stopAndTranscribe() {
                        onComplete(result)
                    } else {
                        onCancel()
                    }
                }
            }) {
                Text("SAVE")
                    .font(.custom("JetBrainsMono-Regular", fixedSize: 14))
                    .foregroundColor(canSave ? DSColor.onPrimary : DSColor.onSurfaceVariant)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(canSave ? DSColor.primary : DSColor.surfaceContainerLow)
            }
            .disabled(!canSave)
            .buttonStyle(.plain)
            .cornerRadius(0)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(DSColor.outlineVariant)
                .frame(height: 1)
        }
    }

    // MARK: - Helpers

    private func formattedTime(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%02d:%02d", m, s)
    }
}
