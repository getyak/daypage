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

    /// Observed so switching capture mode in Settings re-renders the gestures.
    @ObservedObject private var settings = WatchSettingsStore.shared

    /// Proxy value for the Digital Crown — mirrors model.maxDuration as a Double.
    @State private var crownValue: Double = 60

    /// Press-mode: true while the finger has slid up far enough to arm cancel.
    @State private var pressCancelArmed = false

    /// True when the watch is in Always-On Display (AOD) low-luminance mode.
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    /// Vertical drag distance (points) past which a press-mode hold arms cancel.
    private let pressCancelThreshold: CGFloat = 40

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
            Spacer(minLength: 0)

            // Hero ring (tappable) — the visual + interactive center of gravity.
            recordingActionButton

            // Two-line caption: a bold primary line + a quiet secondary line.
            VStack(spacing: 3) {
                Text(primaryLine)
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(isActive ? stateColor : .primary)
                    .contentTransition(.numericText())
                    .animation(isLuminanceReduced ? nil : .snappy(duration: 0.28), value: model.elapsed)
                    .animation(.snappy(duration: 0.28), value: primaryLine)

                Text(secondaryLine)
                    .font(.caption2)
                    .foregroundStyle(isActive ? stateColor.opacity(0.85) : .secondary)
                    .animation(.snappy(duration: 0.25), value: secondaryLine)
            }
            .privacySensitive(false)

            Spacer(minLength: 0)
        }
        .animation(.spring(duration: 0.38, bounce: 0.18), value: model.state)
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

    /// Accent color for the current state — drives ring, waveform, and text.
    private var stateColor: Color {
        switch model.state {
        case .confirmStop:            return .orange
        case .recording:              return model.elapsed >= model.maxDuration - 10 ? .red : Color(red: 1.0, green: 0.27, blue: 0.23)
        case .processing, .uploading: return .cyan
        case .done:                   return .green
        case .failed:                 return .red
        case .idle:                   return .accentColor
        }
    }

    private var isActive: Bool {
        model.state == .recording || model.state == .confirmStop
    }

    /// The hero control — a ring that pulses while recording and fills with
    /// elapsed progress. Its gesture wiring depends on the capture mode:
    ///   - `.tap`   a Button (tap start/stop) + a long-press-to-cancel gesture
    ///   - `.press` a press-and-hold DragGesture (hold = record, release = send,
    ///              slide up = cancel)
    private var recordingActionButton: some View {
        Group {
            if isLuminanceReduced {
                // AOD: static ring only, no controls (OLED burn-in + not tappable).
                RecordingRing(state: model.state, progress: 0, color: stateColor.opacity(0.6))
                    .allowsHitTesting(false)
            } else {
                switch settings.captureMode {
                case .tap:   tapModeRing
                case .press: pressModeRing
                }
            }
        }
    }

    private var ring: some View {
        RecordingRing(
            state: model.state,
            progress: model.maxDuration > 0 ? Double(model.elapsed) / Double(model.maxDuration) : 0,
            color: pressCancelArmed ? .orange : stateColor
        )
    }

    // MARK: Tap mode

    private var tapModeRing: some View {
        Button(action: tapPrimaryAction) {
            ring
        }
        .buttonStyle(RingButtonStyle())
        // Long-press while recording discards the clip (cancel affordance).
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                if model.state == .recording || model.state == .confirmStop {
                    model.cancelRecording()
                }
            }
        )
        .accessibilityLabel(ringAccessibilityLabel)
        .accessibilityHint(model.state == .recording ? "长按取消录音" : "")
    }

    // MARK: Press mode

    private var pressModeRing: some View {
        ring
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        // First touch of a hold starts recording.
                        if model.state == .idle {
                            model.start()
                        }
                        // Arm/disarm cancel based on how far up the finger slid.
                        let slidUp = value.translation.height < -pressCancelThreshold
                        if slidUp != pressCancelArmed {
                            pressCancelArmed = slidUp
                            WKInterfaceDevice.current().play(.click)
                        }
                    }
                    .onEnded { _ in
                        defer { pressCancelArmed = false }
                        guard model.state == .recording || model.state == .confirmStop else {
                            // Released on a non-recording state (e.g. failed) — reset.
                            if case .failed = model.state { model.reset() }
                            return
                        }
                        if pressCancelArmed {
                            model.cancelRecording()   // slid up → discard
                        } else {
                            model.stopAndSendImmediately()  // released in place → send
                        }
                    }
            )
            .accessibilityLabel(ringAccessibilityLabel)
            .accessibilityHint("按住录音，松手发送，上滑取消")
    }

    /// Bold primary caption under the ring — the CTA when idle, the clock when recording.
    private var primaryLine: String {
        switch model.state {
        case .idle:        return settings.captureMode == .press ? "按住录音" : "轻点录音"
        case .recording:
            if pressCancelArmed { return "松手取消" }
            let remaining = model.maxDuration - model.elapsed
            return remaining <= 10 ? "还剩 \(remaining) 秒" : formattedTime(model.elapsed)
        case .confirmStop: return "松开即停"
        case .processing:  return "保存中"
        case .uploading:   return "同步中"
        case .done:        return "已同步"
        case .failed(let msg): return msg
        }
    }

    /// Quiet secondary caption — context for the primary line.
    private var secondaryLine: String {
        switch model.state {
        case .idle:        return "\(model.maxDuration) 秒 · 转表冠调节"
        case .recording:
            if pressCancelArmed { return "松手丢弃这段" }
            return settings.captureMode == .press ? "松手发送 · 上滑取消" : "轻点停止 · 长按取消"
        case .confirmStop: return "轻点继续"
        case .processing:  return "正在写入"
        case .uploading:   return "发送到 iPhone"
        case .done:        return "已存入今天"
        case .failed:      return "轻点屏幕重试"
        }
    }

    private var ringAccessibilityLabel: String {
        switch model.state {
        case .idle:        return "开始录音"
        case .recording:   return "停止录音，已录 \(model.elapsed) 秒"
        case .confirmStop: return "取消停止，继续录音"
        case .failed:      return "重试"
        default:           return primaryLine
        }
    }

    /// Tap-mode primary action: toggles start / stop-with-confirm, cancels the
    /// pending stop, or resets from failure. (Press mode routes through the
    /// DragGesture instead and never calls this.)
    private func tapPrimaryAction() {
        if case .confirmStop = model.state {
            model.cancelStop()
        } else {
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
    }

    private func formattedTime(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - RecordingRing

/// The hero control: a circular ring that fills with elapsed progress and, while
/// recording, breathes (subtle scale pulse) and shows a live waveform inside.
/// All motion is spring-driven and derives from the current state, so state
/// changes are interruptible and never jump (apple-design §3, §4, §8).
private struct RecordingRing: View {

    let state: WatchRecordingModel.State
    let progress: Double
    let color: Color

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    /// Drives the breathing pulse and the waveform phase while recording.
    @State private var pulse = false

    private var isRecording: Bool {
        if case .recording = state { return true }
        if case .confirmStop = state { return true }
        return false
    }

    private var isBusy: Bool {
        state == .processing || state == .uploading
    }

    var body: some View {
        ZStack {
            // Track ring — the empty channel.
            Circle()
                .stroke(Color.white.opacity(0.14), lineWidth: 6)

            // Progress ring — fills clockwise from 12 o'clock while recording.
            if isRecording {
                Circle()
                    .trim(from: 0, to: max(0.001, min(progress, 1)))
                    .stroke(
                        AngularGradient(
                            colors: [color.opacity(0.7), color],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.5), value: progress)
            }

            // Center content.
            centerContent
        }
        .frame(width: 108, height: 108)
        .scaleEffect(isRecording && pulse && !isLuminanceReduced ? 1.04 : 1.0)
        .animation(
            isRecording && !isLuminanceReduced
                ? .easeInOut(duration: 0.85).repeatForever(autoreverses: true)
                : .spring(duration: 0.35, bounce: 0.2),
            value: pulse
        )
        .onChange(of: isRecording) { recording in
            pulse = recording
        }
        .onAppear { pulse = isRecording }
    }

    @ViewBuilder
    private var centerContent: some View {
        switch state {
        case .idle, .failed:
            Image(systemName: state == .idle ? "mic.fill" : "arrow.clockwise")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(color)
                .transition(.scale.combined(with: .opacity))

        case .recording, .confirmStop:
            WaveformBars(color: color, animating: !isLuminanceReduced)
                .frame(width: 46, height: 34)
                .transition(.scale.combined(with: .opacity))

        case .processing, .uploading:
            Image(systemName: state == .processing ? "waveform" : "arrow.up.circle")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(color)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: isBusy)
                .transition(.scale.combined(with: .opacity))

        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(color)
                .transition(.scale.combined(with: .opacity))
        }
    }
}

// MARK: - WaveformBars

/// Five bars that rise and fall to convey "actively capturing" — a lightweight,
/// deterministic stand-in for a real level meter (apple-design §8: hint activity).
private struct WaveformBars: View {

    let color: Color
    let animating: Bool

    @State private var phase = false

    /// Per-bar min/max heights (0–1). Staggered so the group ripples.
    private let bars: [(min: CGFloat, max: CGFloat)] = [
        (0.35, 0.7), (0.55, 1.0), (0.4, 0.85), (0.6, 1.0), (0.3, 0.65),
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(bars.indices, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 5, height: (phase ? bars[i].max : bars[i].min) * 34)
                    .animation(
                        animating
                            ? .easeInOut(duration: 0.42)
                                .repeatForever(autoreverses: true)
                                .delay(Double(i) * 0.08)
                            : .default,
                        value: phase
                    )
            }
        }
        .frame(maxHeight: .infinity)
        .onAppear { if animating { phase = true } }
    }
}

// MARK: - RingButtonStyle

/// Press feedback: instant scale-down on touch-down, spring back on release
/// (apple-design §1: respond on press, §4: spring, not a fixed transition).
private struct RingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1.0)
            .animation(.spring(duration: 0.3, bounce: 0.35), value: configuration.isPressed)
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

    /// Maximum recording duration in seconds — adjusted via Digital Crown when
    /// idle, seeded from and persisted back to `WatchSettingsStore` so the
    /// crown and the Settings page stay one source of truth.
    @Published var maxDuration: Int = 60 {
        didSet {
            guard maxDuration != oldValue else { return }
            settings.maxDuration = maxDuration
        }
    }

    /// The watch's capture configuration (quality, haptics, max duration).
    let settings: WatchSettingsStore

    init(settings: WatchSettingsStore = .shared) {
        self.settings = settings
        super.init()
        self.maxDuration = settings.maxDuration
    }

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var currentFileURL: URL?
    private var autoResetTask: Task<Void, Never>?
    private var confirmStopTask: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?

    private let logger = Logger(subsystem: "com.daypage.watch", category: "RecordingModel")

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    // MARK: - Haptic Feedback

    private func haptic(_ hapticType: WKHapticType) {
        // Gate the two user-facing "you did a thing" haptics on their toggles;
        // failure/click/confirm feedback always plays (it's error/safety UX,
        // not a preference).
        switch hapticType {
        case .start where !settings.hapticsOnStart: return
        case .stop where !settings.hapticsOnStop:   return
        default: break
        }
        WKInterfaceDevice.current().play(hapticType)
    }

    // MARK: - Permission

    func checkMicPermission() {
        isMicPermissionDenied = (AVAudioApplication.shared.recordPermission == .denied)
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
            state = .failed("音频初始化失败")
            haptic(.failure)
            return
        }

        let url = makeFileURL()
        currentFileURL = url

        // Mono AAC (M4A). Sample rate + encoder quality come from the user's
        // audio-quality setting (low/medium/high).
        let quality = settings.audioQuality
        let recorderSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: quality.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: quality.encoderQuality.rawValue,
        ]

        do {
            let rec = try AVAudioRecorder(url: url, settings: recorderSettings)
            rec.isMeteringEnabled = false
            rec.record()
            recorder = rec
            elapsed = 0
            startTimer()
            registerInterruptionObserver()
            state = .recording
            haptic(.start)
        } catch {
            logger.error("AVAudioRecorder init failed: \(error.localizedDescription)")
            deactivateAudioSession()
            state = .failed("录音启动失败")
            haptic(.failure)
        }
    }

    // MARK: - Interruption Handling

    /// Observe `AVAudioSession` interruptions (incoming call, alarm, Siri) so a
    /// mid-recording interruption saves what was captured instead of silently
    /// dropping it. Without this, the recorder is stopped by the system and the
    /// user is left staring at a "recording" ring that never finishes — the
    /// classic real-device failure the simulator never reproduces.
    private func registerInterruptionObserver() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                self?.handleInterruption(note)
            }
        }
    }

    private func removeInterruptionObserver() {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard state == .recording || state == .confirmStop,
              let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }

        // Only .began matters: the system has paused our recorder. We do not try
        // to resume on .ended — a partial voice memo is more useful to the user
        // than a lost one, so we finalize and transfer what we have.
        if type == .began {
            logger.info("Audio interruption began — finalizing partial recording")
            confirmStopTask?.cancel()
            confirmStopTask = nil
            if elapsed >= 1 {
                stopAndTransfer()
            } else {
                // Too short to be worth keeping — discard and surface the reason.
                stopTimer()
                recorder?.stop()
                recorder = nil
                removeInterruptionObserver()
                deactivateAudioSession()
                state = .failed("录音被打断")
                haptic(.failure)
            }
        }
    }

    // MARK: - Stop & Transfer

    func stopAndTransfer() {
        guard let rec = recorder, let url = currentFileURL else {
            state = .failed("没有正在进行的录音")
            haptic(.failure)
            return
        }
        stopTimer()
        rec.stop()
        recorder = nil
        removeInterruptionObserver()
        state = .processing
        haptic(.stop)
        deactivateAudioSession()

        state = .uploading

        // Transfer via WCSession — file cleanup happens inside WatchTransferService
        // once session(_:didFinish:error:) confirms the transfer is complete.
        WatchTransferService.shared.transferAudioFile(url, duration: Double(elapsed)) { [weak self] success in
            Task { @MainActor in
                if success {
                    self?.state = .done
                    self?.scheduleAutoReset()
                } else {
                    self?.state = .failed("同步失败")
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
        removeInterruptionObserver()
        state = .idle
        elapsed = 0
    }

    /// Discard an in-progress recording without sending it. Used by both
    /// capture modes' cancel affordance (tap-mode long-press, press-mode
    /// slide-up). Deletes the temp file so it never enters the transfer queue,
    /// and returns straight to `.idle` — cancelling is not a failure.
    func cancelRecording() {
        guard state == .recording || state == .confirmStop else { return }
        confirmStopTask?.cancel()
        confirmStopTask = nil
        stopTimer()
        recorder?.stop()
        recorder = nil
        removeInterruptionObserver()
        deactivateAudioSession()
        if let url = currentFileURL {
            try? FileManager.default.removeItem(at: url)
            currentFileURL = nil
        }
        state = .idle
        elapsed = 0
        haptic(.click)
    }

    /// Press-mode stop: end the recording and send immediately, with no 2-second
    /// confirmation window (the release *is* the deliberate action). Reuses the
    /// same finalize+transfer path as the timed stop.
    func stopAndSendImmediately() {
        guard state == .recording || state == .confirmStop else { return }
        confirmStopTask?.cancel()
        confirmStopTask = nil
        // A press shorter than ~1s is almost always an accidental tap in
        // press-mode — discard rather than ship a 0-second clip.
        if elapsed < 1 {
            cancelRecording()
            return
        }
        stopAndTransfer()
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

// MARK: - Date Formatter

extension DateFormatter {
    static let watchFileStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
