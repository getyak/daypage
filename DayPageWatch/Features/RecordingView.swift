import SwiftUI
import AVFoundation
import WatchKit
import os
import DayPageServices

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
        if model.isMicPermissionDenied {
            micPermissionDeniedView
        } else {
            recordingContent
        }
    }

    // MARK: - Mic permission denied view

    private var micPermissionDeniedView: some View {
        VStack(spacing: 10) {
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 32))
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Text("麦克风已被拒绝")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("请在 iPhone 上 Watch app → DayPage → 隐私 → 启用麦克风")
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("麦克风权限已被拒绝。请在 iPhone 上 Watch app → DayPage → 隐私 → 启用麦克风")
    }

    // MARK: - Normal recording content

    private var recordingContent: some View {
        VStack(spacing: 12) {
            Spacer()

            // Waveform icon + elapsed time
            recordingStatusHeader

            // Progress bar (recording) + duration hint (idle)
            recordingProgressSection

            Spacer()

            // Action button row
            recordingActionButton

            Spacer()
        }
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
        .onAppear {
            model.checkMicPermission()
        }
    }

    // MARK: Recording subviews

    /// Waveform icon + elapsed / status text — static in AOD to reduce OLED burn-in.
    private var recordingStatusHeader: some View {
        Group {
            Image(systemName: (model.state == .recording || model.state == .confirmStop) ? "waveform" : "waveform.circle")
                .font(.system(size: 36))
                .foregroundStyle(model.state == .confirmStop ? .orange : (model.state == .recording ? .red : .tint))
                .accessibilityLabel(model.state == .recording ? "Recording in progress" : (model.state == .confirmStop ? "Confirming stop" : "Ready to record"))

            Text(statusText)
                .font(.title3.monospacedDigit())
                .contentTransition(.numericText())
                .animation(isLuminanceReduced ? nil : .default, value: model.elapsed)
                .privacySensitive(false)
        }
    }

    /// Countdown bar (recording/confirmStop) or duration hint (idle).
    /// Hidden entirely when the watch is in AOD mode.
    private var recordingProgressSection: some View {
        Group {
            if (model.state == .recording || model.state == .confirmStop) && !isLuminanceReduced {
                ProgressView(value: Double(model.elapsed), total: Double(model.maxDuration))
                    .progressViewStyle(.linear)
                    .tint(model.state == .confirmStop ? .orange : (model.elapsed >= model.maxDuration - 10 ? .red : .green))
                    .accessibilityLabel("Recording time: \(model.elapsed) of \(model.maxDuration) seconds")
            }

            if model.state == .idle && !isLuminanceReduced {
                Text("Limit: \(model.maxDuration)s")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Recording limit: \(model.maxDuration) seconds. Rotate crown to adjust.")
            }

            if case .failed = model.state {
                Text("Tap anywhere to retry")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Main action button — start / stop / confirm-stop / cancel.
    /// Button row is hidden in AOD (buttons are not tappable).
    private var recordingActionButton: some View {
        Group {
            if !isLuminanceReduced {
                if case .confirmStop = model.state {
                    Button(action: { model.cancelStop() }) {
                        Image(systemName: "arrow.uturn.backward.circle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel stop — keep recording")
                } else {
                    Button(action: handleTap) {
                        Image(systemName: model.state == .recording ? "stop.circle.fill" : "mic.circle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(model.state == .recording ? .red : .green)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(model.state == .recording ? "Stop recording" : "Start recording")
                }

                if case .confirmStop = model.state {
                    Text("Tap to cancel")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else {
                    Text(model.state == .recording ? "Tap to stop" : "Tap to record")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
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
        case .confirmStop:
            return "Stopping..."
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
            model.requestStop()
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
        case idle, recording, confirmStop, processing, uploading, done
        case failed(String)
    }

    @Published var state: State = .idle
    @Published var elapsed: Int = 0
    @Published var isMicPermissionDenied: Bool = false

    /// Maximum recording duration in seconds — adjusted via Digital Crown when idle.
    @Published var maxDuration: Int = 60

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var currentFileURL: URL?
    private var extSession: WKExtendedRuntimeSession?
    private var autoResetTask: Task<Void, Never>?
    private var confirmStopTask: Task<Void, Never>?

    private let logger = Logger(subsystem: "com.daypage.watch", category: "RecordingModel")

    // MARK: - Haptic Feedback

    private func haptic(_ hapticType: WKHapticType) {
        WKInterfaceDevice.current().play(hapticType)
    }

    // MARK: - Permission

    func checkMicPermission() {
        let permission = AVAudioApplication.shared.recordPermission
        isMicPermissionDenied = (permission == .denied)
    }

    // MARK: - Start

    func start() {
        // Re-check permission before attempting to record.
        checkMicPermission()
        guard !isMicPermissionDenied else { return }

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

    /// Enter a 2-second confirmation window before actually stopping.
    /// Prevents accidental stop on a single tap.
    func requestStop() {
        guard state == .recording else { return }
        state = .confirmStop
        haptic(.click)

        confirmStopTask?.cancel()
        confirmStopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled, self.state == .confirmStop else { return }
            self.stopAndTransfer()
        }
    }

    /// Cancel the pending stop and resume recording.
    func cancelStop() {
        guard state == .confirmStop else { return }
        confirmStopTask?.cancel()
        confirmStopTask = nil
        state = .recording
        haptic(.click)
    }

    /// Reset from .failed back to .idle so the user can try again.
    func reset() {
        confirmStopTask?.cancel()
        confirmStopTask = nil
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
                guard let self, self.state == .recording || self.state == .confirmStop else { return }
                self.elapsed += 1
                if self.elapsed >= self.maxDuration {
                    // Time's up — cancel any pending confirm and stop immediately
                    self.confirmStopTask?.cancel()
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

        // If invalidated while recording or awaiting confirmation, stop cleanly on the main actor.
        Task { @MainActor [weak self] in
            guard let self, self.state == .recording || self.state == .confirmStop else { return }
            self.confirmStopTask?.cancel()
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
            guard let self, self.state == .recording || self.state == .confirmStop else { return }
            self.confirmStopTask?.cancel()
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
