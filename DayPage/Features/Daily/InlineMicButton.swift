import SwiftUI
import AVFoundation

// MARK: - InlineMicButton

/// Compact long-press mic button for inline use inside conversation input bars.
/// Long-press to record → release to transcribe via Whisper → fires onTranscript.
/// Keeps its own AVAudioRecorder so it does not share state with VoiceService.
struct InlineMicButton: View {

    let onTranscript: (String) -> Void

    @State private var isRecording = false
    @State private var isTranscribing = false
    @State private var recorder: AVAudioRecorder?
    @State private var tempURL: URL?
    @State private var pulseScale: CGFloat = 1.0

    // MARK: - Body

    var body: some View {
        ZStack {
            if isTranscribing {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.7)
                    .tint(DSColor.amberAccent)
                    .frame(width: 32, height: 32)
            } else {
                Circle()
                    .fill(isRecording ? DSColor.amberAccent : DSColor.amberSoft)
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: isRecording ? "mic.fill" : "mic")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(isRecording ? .white : DSColor.amberAccent)
                    )
                    .scaleEffect(pulseScale)
            }
        }
        .frame(width: 32, height: 32)
        .gesture(longPressGesture)
        .accessibilityLabel(isRecording ? "松开停止录音" : "长按录音")
        .accessibilityHint("长按开始录音，松手后自动转写为文字")
    }

    // MARK: - Gesture

    /// LongPressGesture fires on press-down; a DragGesture with minimumDistance 0
    /// catches the finger-up event to stop recording.
    private var longPressGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.25)
            .onEnded { _ in Task { await startRecording() } }
            .simultaneously(with:
                DragGesture(minimumDistance: 0)
                    .onEnded { _ in
                        guard isRecording else { return }
                        Task { await stopAndTranscribe() }
                    }
            )
    }

    // MARK: - Recording control

    private func startRecording() async {
        guard !isRecording, !isTranscribing else { return }

        guard await requestMicPermission() else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default, options: [])
            try session.setActive(true)
        } catch { return }

        let url = makeTempURL()
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        guard let rec = try? AVAudioRecorder(url: url, settings: settings) else {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            return
        }
        rec.record()
        recorder = rec
        tempURL = url

        withAnimation(.easeOut(duration: 0.15)) { isRecording = true }
        // Animate pulse only while recording.
        withAnimation(Animation.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
            pulseScale = 1.18
        }
    }

    private func stopAndTranscribe() async {
        guard isRecording, let rec = recorder, let url = tempURL else { return }

        rec.stop()
        recorder = nil
        withAnimation(.easeOut(duration: 0.15)) {
            isRecording = false
            pulseScale = 1.0
        }

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        // Discard clips that are probably accidental taps (< 4 KB).
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 4_096 else { cleanupTemp(url); return }

        isTranscribing = true
        defer { isTranscribing = false; cleanupTemp(url) }

        if let text = await VoiceService.shared.transcribeAudio(at: url), !text.isEmpty {
            onTranscript(text)
        }
    }

    // MARK: - Helpers

    private func requestMicPermission() async -> Bool {
        let status = AVAudioSession.sharedInstance().recordPermission
        switch status {
        case .granted: return true
        case .denied:  return false
        case .undetermined:
            return await withCheckedContinuation { cont in
                AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
            }
        @unknown default: return false
        }
    }

    private func makeTempURL() -> URL {
        let stamp = Int(Date().timeIntervalSince1970)
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("inline_mic_\(stamp).m4a")
    }

    private func cleanupTemp(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        tempURL = nil
    }
}
