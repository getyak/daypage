import AppIntents
import AVFoundation
import WatchKit

// MARK: - StartRecordingIntent

/// App Intent triggered by the Watch Action Button to start a recording.
/// Uses a minimal AVAudioRecorder for quick-start recording without UI.
/// Wraps recording in WKExtendedRuntimeSession(.audioRecording) so watchOS
/// does not suspend the process mid-recording.
@available(watchOS 9.0, *)
struct StartRecordingIntent: AppIntent {

    static let title: LocalizedStringResource = "Start DayPage Recording"
    static let description: LocalizedStringResource = "Quickly start a voice recording from the Action button"

    @MainActor
    func perform() async throws -> some IntentResult {
        let extSession = WKExtendedRuntimeSession()
        extSession.start()

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setActive(true)
        } catch {
            extSession.invalidate()
            return .result(dialog: "Audio session error")
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.daypage.watch", isDirectory: true)
            .appendingPathComponent("action_\(Date().timeIntervalSince1970).m4a")

        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.record()

        // Record for 30 seconds then auto-stop
        try await Task.sleep(nanoseconds: 30_000_000_000)
        recorder.stop()
        extSession.invalidate()
        try? AVAudioSession.sharedInstance().setActive(false)

        // Transfer via WCSession
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            WatchTransferService.shared.transferAudioFile(url) { _ in
                continuation.resume()
            }
        }

        return .result(dialog: "Recording saved")
    }
}
