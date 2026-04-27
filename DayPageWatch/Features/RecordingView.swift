import SwiftUI
import AVFoundation

// MARK: - RecordingView

/// Full recording UI backed by AVAudioRecorder (16 kHz / M4A).
struct RecordingView: View {

    @StateObject private var model = WatchRecordingModel()

    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            // Waveform icon
            Image(systemName: model.state == .recording ? "waveform" : "waveform.circle")
                .font(.system(size: 36))
                .foregroundStyle(model.state == .recording ? .red : .tint)

            // Elapsed time or status
            Text(statusText)
                .font(.title3.monospacedDigit())
                .contentTransition(.numericText())
                .animation(.default, value: model.elapsed)

            Spacer()

            // Main action button
            Button(action: handleTap) {
                Image(systemName: model.state == .recording ? "stop.circle.fill" : "mic.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(model.state == .recording ? .red : .green)
            }
            .buttonStyle(.plain)

            Text(model.state == .recording ? "Tap to stop" : "Tap to record")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }

    private var statusText: String {
        switch model.state {
        case .idle:
            return "Ready"
        case .recording:
            return formattedTime(model.elapsed)
        case .processing:
            return "Saving..."
        case .uploading:
            return "Transferring..."
        case .done:
            return "Done ✓"
        case .failed(let msg):
            return msg
        }
    }

    private func handleTap() {
        switch model.state {
        case .idle:
            model.start()
        case .recording:
            model.stopAndTransfer()
        default:
            break
        }
    }

    private func formattedTime(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - WatchRecordingModel

@MainActor
final class WatchRecordingModel: ObservableObject {

    enum State: Equatable {
        case idle, recording, processing, uploading, done
        case failed(String)
    }

    @Published var state: State = .idle
    @Published var elapsed: Int = 0

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var currentFileURL: URL?

    // MARK: - Start

    func start() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setActive(true)
        } catch {
            state = .failed("Audio session error")
            return
        }

        let url = makeFileURL()
        currentFileURL = url

        // Settings: 16 kHz Mono AAC (M4A) — smaller file, good enough for voice
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]

        do {
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.isMeteringEnabled = false
            rec.record()
            recorder = rec
            elapsed = 0
            startTimer()
            state = .recording
        } catch {
            state = .failed("Record start failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Stop & Transfer

    func stopAndTransfer() {
        guard let rec = recorder, let url = currentFileURL else {
            state = .failed("No active recording")
            return
        }
        stopTimer()
        rec.stop()
        recorder = nil
        state = .uploading

        // Transfer via WCSession — file cleanup happens inside WatchTransferService
        // once session(_:didFinish:error:) confirms the transfer is complete.
        WatchTransferService.shared.transferAudioFile(url) { [weak self] success in
            Task { @MainActor in
                if success {
                    self?.state = .done
                } else {
                    self?.state = .failed("Transfer failed")
                }
            }
        }
    }

    // MARK: - Helpers

    private func makeFileURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.daypage.watch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = DateFormatter.watchFileStamp.string(from: Date())
        return dir.appendingPathComponent("watch_\(stamp).m4a")
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard self?.state == .recording else { return }
                self?.elapsed += 1
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Date Formatter

extension DateFormatter {
    static let watchFileStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
