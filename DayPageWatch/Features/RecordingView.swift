import SwiftUI
import AVFoundation
import WatchKit
import os

// MARK: - RecordingView

/// Full recording UI backed by AVAudioRecorder (16 kHz / M4A).
/// When idle, rotating the Digital Crown adjusts the max recording duration (30–180 s).
struct RecordingView: View {

    @StateObject private var model = WatchRecordingModel()

    /// Proxy value for the Digital Crown — mirrors model.maxDuration as a Double.
    @State private var crownValue: Double = 60

    /// True when the watch is in Always-On Display (AOD) low-luminance mode.
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            // Waveform icon — static in AOD to reduce OLED burn-in / power draw
            Image(systemName: model.state == .recording ? "waveform" : "waveform.circle")
                .font(.system(size: 36))
                .foregroundStyle(model.state == .recording ? .red : .tint)
                .accessibilityLabel(model.state == .recording ? "Recording in progress" : "Ready to record")

            // Elapsed time or status
            // In AOD the timer already ticks at 1 Hz — suppress the numeric animation
            // so no frame-level updates run between ticks.
            Text(statusText)
                .font(.title3.monospacedDigit())
                .contentTransition(.numericText())
                .animation(isLuminanceReduced ? nil : .default, value: model.elapsed)
                .privacySensitive(false)

            // Countdown bar — hidden in AOD (animated content wastes power on OLED)
            if model.state == .recording && !isLuminanceReduced {
                ProgressView(value: Double(model.elapsed), total: Double(model.maxDuration))
                    .progressViewStyle(.linear)
                    .tint(model.elapsed >= model.maxDuration - 10 ? .red : .green)
                    .accessibilityLabel("Recording time: \(model.elapsed) of \(model.maxDuration) seconds")
            }

            // Duration picker hint — only visible while idle, hidden in AOD
            if model.state == .idle && !isLuminanceReduced {
                Text("Limit: \(model.maxDuration)s")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Recording limit: \(model.maxDuration) seconds. Rotate crown to adjust.")
            }

            // Tap-anywhere hint shown in failed state
            if case .failed = model.state {
                Text("Tap anywhere to retry")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Main action button — hidden in AOD (buttons are not tappable in AOD)
            if !isLuminanceReduced {
                Button(action: handleTap) {
                    Image(systemName: model.state == .recording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(model.state == .recording ? .red : .green)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.state == .recording ? "Stop recording" : "Start recording")

                Text(model.state == .recording ? "Tap to stop" : "Tap to record")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        // Tapping anywhere in .failed state dismisses back to .idle
        .contentShape(Rectangle())
        .onTapGesture {
            if case .failed = model.state { model.reset() }
        }
        .focusable(model.state == .idle)
        .digitalCrownRotation(
            $crownValue,
            from: 30,
            through: 180,
            by: 10,
            sensitivity: .low,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .onChange(of: crownValue) { newValue in
            model.maxDuration = Int(newValue)
        }
    }

    private var statusText: String {
        switch model.state {
        case .idle:
            return "Ready"
        case .recording:
            let remaining = model.maxDuration - model.elapsed
            return remaining <= 10
                ? ":\(remaining)s left"
                : formattedTime(model.elapsed)
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
        case .failed:
            model.reset()
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
final class WatchRecordingModel: NSObject, ObservableObject {

    enum State: Equatable {
        case idle, recording, processing, uploading, done
        case failed(String)
    }

    @Published var state: State = .idle
    @Published var elapsed: Int = 0

    /// Maximum recording duration in seconds — adjusted via Digital Crown when idle.
    @Published var maxDuration: Int = 60

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var currentFileURL: URL?
    private var extSession: WKExtendedRuntimeSession?
    private var autoResetTask: Task<Void, Never>?

    private let logger = Logger(subsystem: "com.daypage.watch", category: "RecordingModel")

    // MARK: - Haptic Feedback

    private func haptic(_ hapticType: WKHapticType) {
        WKInterfaceDevice.current().play(hapticType)
    }

    // MARK: - Start

    func start() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setActive(true)
        } catch {
            logger.error("Audio session setup failed: \(error.localizedDescription)")
            state = .failed("Audio session error")
            haptic(.failure)
            return
        }

        // Request a WKExtendedRuntimeSession so the recording is not forcibly
        // suspended by the system after the display turns off.
        let ext = WKExtendedRuntimeSession()
        ext.delegate = self
        ext.start()
        extSession = ext

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
            haptic(.start)
        } catch {
            logger.error("AVAudioRecorder init failed: \(error.localizedDescription)")
            state = .failed("Record start failed")
            haptic(.failure)
            invalidateExtSession()
        }
    }

    // MARK: - Stop & Transfer

    func stopAndTransfer() {
        guard let rec = recorder, let url = currentFileURL else {
            state = .failed("No active recording")
            haptic(.failure)
            return
        }
        stopTimer()
        rec.stop()
        recorder = nil
        state = .processing
        haptic(.stop)
        invalidateExtSession()

        deactivateAudioSession()

        state = .uploading

        // Transfer via WCSession — file cleanup happens inside WatchTransferService
        // once session(_:didFinish:error:) confirms the transfer is complete.
        WatchTransferService.shared.transferAudioFile(url) { [weak self] success in
            Task { @MainActor in
                if success {
                    self?.state = .done
                    self?.scheduleAutoReset()
                } else {
                    self?.state = .failed("Transfer failed")
                    self?.haptic(.failure)
                }
            }
        }
    }

    /// Reset from .failed back to .idle so the user can try again.
    func reset() {
        stopTimer()
        recorder?.stop()
        recorder = nil
        invalidateExtSession()
        state = .idle
        elapsed = 0
    }

    // MARK: - Helpers

    private func makeFileURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.daypage.watch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = DateFormatter.watchFileStamp.string(from: Date())
        let uuid = UUID().uuidString
        return dir.appendingPathComponent("watch_\(stamp)_\(uuid).m4a")
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.state == .recording else { return }
                self.elapsed += 1
                if self.elapsed >= self.maxDuration {
                    self.stopAndTransfer()
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func invalidateExtSession() {
        extSession?.invalidate()
        extSession = nil
    }

    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            logger.error("Failed to deactivate audio session: \(error.localizedDescription)")
        }
    }

    /// After .done, wait 2 seconds then return to .idle so the user can record again.
    func scheduleAutoReset() {
        autoResetTask?.cancel()
        autoResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if case .done = self.state {
                self.state = .idle
                self.elapsed = 0
            }
        }
    }
}

// MARK: - WKExtendedRuntimeSessionDelegate

extension WatchRecordingModel: WKExtendedRuntimeSessionDelegate {

    nonisolated func extendedRuntimeSession(
        _ extendedRuntimeSession: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
        error: Error?
    ) {
        let msg = error.map { $0.localizedDescription } ?? "no error"
        // Logger is nonisolated-safe (sendable)
        Logger(subsystem: "com.daypage.watch", category: "RecordingModel")
            .warning("WKExtendedRuntimeSession invalidated — reason: \(reason.rawValue), error: \(msg)")

        // If invalidated while recording, stop cleanly on the main actor.
        Task { @MainActor [weak self] in
            guard let self, self.state == .recording else { return }
            self.stopAndTransfer()
        }
    }

    nonisolated func extendedRuntimeSessionDidStart(
        _ extendedRuntimeSession: WKExtendedRuntimeSession
    ) {
        Logger(subsystem: "com.daypage.watch", category: "RecordingModel")
            .info("WKExtendedRuntimeSession started")
    }

    nonisolated func extendedRuntimeSessionWillExpire(
        _ extendedRuntimeSession: WKExtendedRuntimeSession
    ) {
        Logger(subsystem: "com.daypage.watch", category: "RecordingModel")
            .warning("WKExtendedRuntimeSession will expire — stopping recording")
        Task { @MainActor [weak self] in
            guard let self, self.state == .recording else { return }
            self.stopAndTransfer()
        }
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
