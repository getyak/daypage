import Foundation
import AVFoundation
import Speech
import Sentry
import DayPageStorage
import DayPageServices

// MARK: - Recording State

enum RecordingState: Equatable {
    case idle
    case requesting        // waiting for mic permission
    case recording         // actively recording
    case paused            // paused mid-recording (user-initiated)
    case interrupted       // paused by AVAudioSession interruption (call / Siri / alarm)
    case processing        // stopped, transcribing
    case done              // transcription complete / saved
    case failed(String)    // error with user-facing message

    static func == (lhs: RecordingState, rhs: RecordingState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.requesting, .requesting),
             (.recording, .recording), (.paused, .paused),
             (.interrupted, .interrupted),
             (.processing, .processing), (.done, .done):
            return true
        case let (.failed(a), .failed(b)):
            return a == b
        default:
            return false
        }
    }
}

// MARK: - VoiceRecordingResult

struct VoiceRecordingResult {
    /// Vault 相对路径，如 "raw/assets/voice_20260415_143000.m4a"
    let filePath: String
    /// 设备上的绝对 URL
    let fileURL: URL
    /// 时长（秒）
    let duration: TimeInterval
    /// Whisper 转录文本（若转录失败或尚未完成则为 nil）
    let transcript: String?
}

// MARK: - VoiceService

/// 处理麦克风权限、音频录制（AVAudioRecorder）以及 Whisper API 转录。
/// 始终在主 Actor 上运行，SwiftUI 可直接绑定到 @Published 属性。
@MainActor
final class VoiceService: NSObject, ObservableObject {

    static let shared = VoiceService()

    // MARK: Published

    @Published var state: RecordingState = .idle
    /// Set to true when Whisper transcription failed on an active connection (audio was saved).
    @Published var lastTranscriptFailed: Bool = false
    /// 录制中每秒更新的实时已过秒数
    @Published var elapsedSeconds: Int = 0
    /// 归一化音频电平 0.0–1.0，录制中约 30fps 更新
    @Published var waveformLevel: Float = 0.0
    /// 波形电平滚动历史记录（最近 40 个采样），用于条形显示
    @Published var waveformHistory: [Float] = Array(repeating: 0.04, count: 40)
    /// True once an AVAudioSession interruption has paused the recording at
    /// least once during this session. Consumed by the UI to surface a hint
    /// so the user knows audio was preserved across the interruption.
    @Published var wasInterrupted: Bool = false
    /// Human-readable message describing the current interruption state, or
    /// `nil` when no interruption is active. Cleared once recording resumes
    /// or the session terminates.
    @Published var interruptionMessage: String? = nil
    /// Live transcript while recording, when the active provider supports
    /// streaming. Cumulative — each update replaces the whole string. Empty
    /// when streaming is unavailable or nothing has been recognised yet.
    @Published var liveTranscript: String = ""

    // MARK: Private

    private var recorder: AVAudioRecorder?
    private var currentFileURL: URL?
    private var recordingStartDate: Date?
    private var timer: Timer?
    private var meteringTimer: Timer?
    /// Live-streaming ASR trio. All nil unless a streaming provider is active.
    private var streamClient: DoubaoStreamASRClient?
    private var liveCapture: LivePCMCapture?
    private var streamTask: Task<Void, Never>?
    /// Token returned by `NotificationCenter.addObserver(forName:...)` so the
    /// observer can be removed in `deinit`. Lives as long as the singleton
    /// (which is for the app lifetime) — held for symmetry / future cleanup
    /// if VoiceService becomes non-singleton.
    private var interruptionObserver: NSObjectProtocol?

    // MARK: - Init

    override init() {
        super.init()
        registerInterruptionObserver()
    }

    deinit {
        if let token = interruptionObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - AVAudioSession Interruption

    /// Registers for `AVAudioSession.interruptionNotification` so calls,
    /// Siri, alarms, and other audio-priority events can pause the recorder
    /// cleanly instead of silently corrupting the in-flight file.
    ///
    /// Without this, an interruption mid-recording would leave the
    /// recorder running against a deactivated session — the on-disk file
    /// gets truncated or empty, and the state machine remains stuck in
    /// `.recording` so the UI keeps showing waveforms that no longer
    /// reflect captured audio.
    private func registerInterruptionObserver() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                self?.handleInterruption(note)
            }
        }
    }

    /// Handles the .began / .ended phases of an AVAudioSession interruption.
    ///
    /// `.began`: pause the recorder and timers, transition to `.interrupted`,
    /// and surface a user-facing hint that the recording is preserved.
    ///
    /// `.ended`: inspect `.shouldResume`. If the system permits us to resume,
    /// reactivate the session and resume the recorder + timers; otherwise
    /// drop back to `.idle` and breadcrumb so we can track how often a
    /// recording is lost to a non-resumable interruption.
    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

        switch type {
        case .began:
            // Only act when there is something to interrupt.
            guard state == .recording else { return }
            recorder?.pause()
            stopTimer()
            stopMeteringTimer()
            wasInterrupted = true
            interruptionMessage = NSLocalizedString(
                "voice.interruption.paused",
                value: "录音已暂停 — 通话/Siri 结束后会自动恢复",
                comment: "Shown when the recording is paused by an AVAudioSession interruption"
            )
            state = .interrupted
            SentryReporter.breadcrumb(
                category: "voice",
                level: .warning,
                message: "audio interruption began — recording paused"
            )

        case .ended:
            // Only meaningful if we previously transitioned to .interrupted.
            guard state == .interrupted else { return }
            let options: AVAudioSession.InterruptionOptions
            if let rawOpts = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt {
                options = AVAudioSession.InterruptionOptions(rawValue: rawOpts)
            } else {
                options = []
            }
            if options.contains(.shouldResume) {
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                    recorder?.record()
                    startTimer()
                    startMeteringTimer()
                    interruptionMessage = nil
                    state = .recording
                    // The interruption path tore the stream down alongside the
                    // timers; bring it back or live text dies for the rest of
                    // the take even though recording resumed.
                    Task { await startLiveTranscriptionIfAvailable() }
                    SentryReporter.breadcrumb(
                        category: "voice",
                        level: .info,
                        message: "audio interruption ended — recording resumed"
                    )
                } catch {
                    interruptionMessage = nil
                    state = .failed("录音恢复失败：\(error.localizedDescription)")
                    SentryReporter.breadcrumb(
                        category: "voice",
                        level: .error,
                        message: "audio interruption resume failed: \(error)"
                    )
                }
            } else {
                // System refused to authorize resume — release everything and
                // surface state.idle so the UI offers a fresh start instead of
                // pretending the partial recording is still active.
                recorder?.stop()
                recorder = nil
                interruptionMessage = nil
                state = .idle
                SentryReporter.breadcrumb(
                    category: "voice",
                    level: .warning,
                    message: "audio interruption ended without resume — recording released"
                )
            }

        @unknown default:
            return
        }
    }

    // MARK: - Permission

    /// 请求麦克风权限（若尚未授权）。
    /// 权限被授权时返回 true。
    /// 使用 AVAudioSession API 以兼容 iOS 16。
    func requestMicrophonePermission() async -> Bool {
        let status = AVAudioSession.sharedInstance().recordPermission
        switch status {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { cont in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    cont.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    // MARK: - Start

    /// Set when `cancelRecording()` arrives while `startRecording()` is
    /// still awaiting the permission check or the detached audio-session
    /// bring-up (hundreds of ms; seconds on a cold stack). At that moment
    /// `recorder`/`currentFileURL` are still nil, so cancel's cleanup has
    /// nothing to stop — and without this flag the recorder created moments
    /// later would run unattended until process death, leaking a growing
    /// orphan .m4a and pinning the mic indicator (#826). `startRecording`
    /// consumes the flag after each await and aborts itself.
    private var cancelRequestedDuringStart = false

    /// True (and consumed) when a cancel arrived mid-start. MainActor
    /// serialization guarantees no cancel can interleave between this
    /// check and the synchronous recorder creation that follows it.
    private func consumeStartCancellation(deactivateSession: Bool) -> Bool {
        guard cancelRequestedDuringStart else { return false }
        cancelRequestedDuringStart = false
        state = .idle
        if deactivateSession {
            // The session HAS been activated by the time this call site
            // runs; the cancel path's own setActive(false) fired too early
            // to undo it. Same detached hop as activation — deactivation
            // also blocks.
            Task.detached(priority: .userInitiated) {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
        return true
    }

    /// 请求权限、设置音频会话并开始录制。
    /// 成功时将 `state` 设为 `.recording`，失败时设为 `.failed`。
    func startRecording() async {
        cancelRequestedDuringStart = false
        state = .requesting
        let granted = await requestMicrophonePermission()
        guard granted else {
            state = .failed("麦克风权限被拒绝，请在「设置 -> 隐私 -> 麦克风」中授权")
            return
        }
        if consumeStartCancellation(deactivateSession: false) { return }

        do {
            // setCategory/setActive block for hundreds of ms (seconds on a
            // cold audio stack). Running them on the main actor both froze
            // the UI and delayed the actual start of capture — a 4s press
            // could end up with <1s of audio. Hop off the main actor; the
            // AVAudioSession API is thread-safe.
            try await Task.detached(priority: .userInitiated) {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
                try session.setActive(true)
            }.value
        } catch {
            state = .failed("音频会话初始化失败：\(error.localizedDescription)")
            return
        }
        if consumeStartCancellation(deactivateSession: true) { return }

        let fileURL = makeAudioFileURL()
        currentFileURL = fileURL

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            let rec = try AVAudioRecorder(url: fileURL, settings: settings)
            rec.delegate = self
            rec.isMeteringEnabled = true
            rec.record()
            recorder = rec
            recordingStartDate = Date()
            elapsedSeconds = 0
            waveformHistory = Array(repeating: 0.04, count: 40)
            startTimer()
            startMeteringTimer()
            state = .recording
        } catch {
            state = .failed("录音启动失败：\(error.localizedDescription)")
            return
        }

        // Live transcription rides alongside the file recording rather than
        // replacing it: the .m4a on disk stays the source of truth (and the
        // input to the post-hoc transcript), while this only drives the
        // on-screen text. If it fails, recording is unaffected.
        await startLiveTranscriptionIfAvailable()
    }

    // MARK: - Live Streaming Transcription

    /// True when the active provider can transcribe while the user speaks and
    /// is actually configured. The UI reads this to decide whether to reserve
    /// space for live text.
    var canStreamLive: Bool {
        AppSettings.aiFeaturesEnabled
            && NetworkMonitor.shared.isOnline
            && ASRSettings.active.supportsStreaming
            && DoubaoASRConfig.hasCredentials
    }

    private func startLiveTranscriptionIfAvailable() async {
        guard canStreamLive else { return }

        liveTranscript = ""
        let client = DoubaoStreamASRClient()
        streamClient = client

        do {
            try await client.start()
        } catch {
            // Streaming is best-effort. The recording continues, and the
            // post-hoc transcript still runs on the saved file.
            DayPageLogger.shared.error("live ASR start failed: \(error.localizedDescription)")
            teardownLiveTranscription()
            return
        }

        // Pump: mic → converter → WebSocket. The tap fires on an audio thread,
        // so hop onto the actor before sending.
        let capture = LivePCMCapture()
        liveCapture = capture
        do {
            try capture.start { [weak self] chunk in
                Task { [weak self] in
                    guard let self, let client = await self.streamClient else { return }
                    try? await client.send(audio: chunk)
                }
            }
        } catch {
            DayPageLogger.shared.error("live PCM capture failed: \(error.localizedDescription)")
            teardownLiveTranscription()
            return
        }

        // Drain results until the server closes or we tear down.
        streamTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let client = await self.streamClient else { break }
                do {
                    guard let update = try await client.receive() else { break }
                    // Results are cumulative — replace, never append.
                    if !update.text.isEmpty { await self.setLiveTranscript(update.text) }
                    if update.isFinal { break }
                } catch {
                    DayPageLogger.shared.error("live ASR receive: \(error.localizedDescription)")
                    break
                }
            }
        }
    }

    private func setLiveTranscript(_ text: String) {
        liveTranscript = text
    }

    private func teardownLiveTranscription() {
        streamTask?.cancel()
        streamTask = nil
        liveCapture?.stop()
        liveCapture = nil
        let client = streamClient
        streamClient = nil
        Task { await client?.close() }
    }

    /// Flushes the live-streaming recognizer and returns the best transcript we
    /// can get for the take, WITHOUT tearing anything down.
    ///
    /// Why this exists: the send path used to throw the already-recognized live
    /// text away and re-transcribe the saved .m4a from scratch via the flash
    /// file endpoint — a second, separately-provisioned service that can fail
    /// while streaming works, leaving the card stuck at "转录中" forever. When
    /// streaming already produced text, that text IS the transcript; the file
    /// pass becomes an optional refinement, not the only source.
    ///
    /// Flow: stop the mic pump so no more audio flows, send the terminal frame
    /// (`isLast: true`) so the server flushes its final result, then drain for a
    /// short bounded window for an `isFinal` packet that's usually a hair more
    /// complete than the last partial. If the window elapses, we fall back to
    /// whatever `liveTranscript` already holds — never blocking the send.
    ///
    /// Returns the trimmed transcript, or "" when streaming wasn't active or
    /// produced nothing.
    private func finalizeLiveTranscript(maxWait: TimeInterval = 2.0) async -> String {
        guard let client = streamClient else {
            return liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Stop feeding the socket and cancel the background drain so we own
        // `receive()` for the flush window — two concurrent receivers on one
        // WebSocket task race for frames.
        liveCapture?.stop()
        liveCapture = nil
        streamTask?.cancel()
        streamTask = nil

        // Ask the server to flush. Best-effort: a send failure here just means
        // we return the partial text we already have.
        try? await client.send(audio: Data(), isLast: true)

        // Bounded drain, all on the main actor (no @Sendable hop needed): race
        // each `receive()` against the remaining budget so a server that never
        // sends its terminal frame can't stall the send. `receive()` on an
        // actor is itself cancellable via the timeout child task.
        let deadline = Date().addingTimeInterval(maxWait)
        while Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            let update = await withTaskGroup(of: DoubaoStreamASRClient.Update?.self) { group in
                group.addTask { try? await client.receive() }
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            guard let update else { break }        // timeout or stream closed
            if !update.text.isEmpty { setLiveTranscript(update.text) }
            if update.isFinal { break }
        }

        return liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Pause / Resume

    func pauseRecording() {
        guard state == .recording else { return }
        recorder?.pause()
        stopTimer()
        stopMeteringTimer()
        teardownLiveTranscription()
        state = .paused
    }

    func resumeRecording() {
        guard state == .paused else { return }
        recorder?.record()
        startTimer()
        startMeteringTimer()
        state = .recording
        // pauseRecording() tore the stream down (the socket would otherwise
        // time out waiting for audio). Without this the recorder resumes but
        // live text stays frozen for the rest of the take.
        Task { await startLiveTranscriptionIfAvailable() }
    }

    // MARK: - Stop & Transcribe

    /// 停止录制、保存 .m4a 文件，并返回结果。
    ///
    /// 若实时流式转写在录音期间已产出文本，则**直接把它作为 transcript 返回**，
    /// memo 落盘即 `.done`，不再入队、不再走文件极速版。仅当没有实时文本
    /// （未开流式 / 离线 / 未识别到内容）时，才把转录任务推入
    /// VoiceAttachmentQueue 由文件极速版事后补写。
    ///
    /// 返回前会给流式一个 ~2s 的短窗口冲刷最终结果（`finalizeLiveTranscript`），
    /// 因此不是零延迟，但绝不会无限等待。
    ///
    /// 用于用户显式选择"发送"的路径（长按松手→send、录音条→送出）。
    func stopAndSaveAudio() async -> VoiceRecordingResult? {
        guard let rec = recorder, let fileURL = currentFileURL else {
            state = .failed("没有活跃的录音")
            return nil
        }

        stopTimer()
        stopMeteringTimer()

        // While we flush the stream (~2s), surface "正在转写…" instead of
        // leaving the pulsing "正在录音" dot up — the mic is already off. Only
        // when streaming was actually active; a non-streaming take returns
        // instantly and shouldn't flash a processing state.
        if streamClient != nil {
            state = .processing
        }

        // Flush the live recognizer FIRST, while the socket is still open, so
        // the text the user already watched appear becomes the memo's initial
        // transcript. Only then tear the stream down. This is the fix for
        // "发送后一直转录中": streaming text that already exists is used
        // directly instead of re-running the flash file endpoint from scratch.
        let liveText = await finalizeLiveTranscript()
        teardownLiveTranscription()

        let finalDuration = Double(elapsedSeconds)
        rec.stop()
        recorder = nil

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            DayPageLogger.shared.warn("VoiceService: setActive(false) failed: \(error)")
        }

        let filePath = "raw/assets/\(fileURL.lastPathComponent)"
        lastTranscriptFailed = false

        // When live streaming gave us text, that IS the transcript — the memo
        // lands as `.done` immediately (TodayViewModel maps transcript != nil →
        // .done) and never touches the queue. Only enqueue the flash file pass
        // when we have NO live text (streaming off, offline, or nothing
        // recognized), so the audio still gets transcribed later.
        let transcript = liveText.isEmpty ? nil : liveText
        if transcript == nil {
            VoiceAttachmentQueue.shared.enqueue(audioPath: filePath, memoDate: Date())
        }

        state = .done
        return VoiceRecordingResult(
            filePath: filePath,
            fileURL: fileURL,
            duration: finalDuration,
            transcript: transcript
        )
    }

    /// 停止录制、保存 .m4a 文件、返回带 transcript 的结果（转录文本在返回前
    /// 就绪）。用于"松开手指立即把 transcript 填进输入框"的场景。
    ///
    /// 优先使用录音期间已产出的实时流式文本 —— 若有,则**不再**阻塞去跑
    /// 文件极速版 / Whisper,松手即得文字。仅当实时文本为空时才退回到事后
    /// 转写（此时会阻塞在该 API 上）。网络失败时音频仍会保存,transcript 为 nil。
    /// 仅在没有有效可保存的录音时返回 nil。
    func stopAndTranscribe() async -> VoiceRecordingResult? {
        guard let rec = recorder, let fileURL = currentFileURL else {
            state = .failed("没有活跃的录音")
            return nil
        }

        stopTimer()
        stopMeteringTimer()

        // Prefer the text streaming already produced. Flush it (~2s) BEFORE
        // teardown, same as the send path — otherwise this blocks the user's
        // input box on a flash/Whisper round trip that can fail even when
        // streaming works.
        state = streamClient != nil ? .processing : state
        let liveText = await finalizeLiveTranscript()
        teardownLiveTranscription()
        let finalDuration = Double(elapsedSeconds)
        rec.stop()
        recorder = nil

        // Release the AVAudioSession on every exit path, including thrown
        // errors from `transcribeAudio` below. Without the defer, an early
        // return (e.g. a future throw from transcription, or a crash during
        // file path derivation) would leave the session active and silently
        // mute the rest of the app's audio playback until the process
        // restarted.
        defer {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                // Non-fatal: deactivating the session may fail if another active session
                // is still running. Log a warning so we can track frequency in production.
                DayPageLogger.shared.warn("VoiceService: setActive(false) failed: \(error)")
            }
        }

        state = .processing

        // 推导 vault 相对路径
        let filePath = "raw/assets/\(fileURL.lastPathComponent)"

        lastTranscriptFailed = false

        // Live text wins: if streaming already recognized speech, use it and
        // skip the blocking file/Whisper round trip entirely. Only fall back to
        // post-hoc transcription when there's no live text.
        let transcript: String?
        if !liveText.isEmpty {
            transcript = liveText
        } else {
            transcript = await transcribeAudio(at: fileURL)
            if transcript == nil {
                if NetworkMonitor.shared.isOnline {
                    // Online but transcription failed — surface banner so user knows audio is saved.
                    lastTranscriptFailed = true
                } else {
                    // Offline — queue for later retry.
                    VoiceAttachmentQueue.shared.enqueue(audioPath: filePath, memoDate: Date())
                }
            }
        }

        let result = VoiceRecordingResult(
            filePath: filePath,
            fileURL: fileURL,
            duration: finalDuration,
            transcript: transcript
        )

        state = .done
        return result
    }

    // MARK: - Cancel

    /// 中止录制，不保存。
    ///
    /// On removeItem failure we breadcrumb instead of swallowing — the
    /// resulting orphan .m4a will be reconciled by OrphanedVoiceScanner
    /// on the next launch (>24h → deleted; <24h → retained for future
    /// recovery UI), but the breadcrumb tells us when this path is
    /// firing so we can debug if orphans pile up.
    func cancelRecording() {
        // A quick press-and-release can land here while startRecording()
        // is still awaiting the audio-session bring-up — recorder and
        // currentFileURL are nil and the cleanup below is a no-op. Flag
        // the in-flight start so it aborts on arrival instead of spinning
        // up a recorder nobody will ever stop (#826).
        if state == .requesting { cancelRequestedDuringStart = true }
        stopTimer()
        stopMeteringTimer()
        teardownLiveTranscription()
        recorder?.stop()
        if let url = currentFileURL {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                SentryReporter.breadcrumb(
                    category: "voice",
                    level: .warning,
                    message: "cancelRecording: removeItem failed: \(error)"
                )
            }
        }
        recorder = nil
        currentFileURL = nil
        elapsedSeconds = 0
        state = .idle
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 将状态重置回 idle（在结果被消费后调用）。
    func reset() {
        stopTimer()
        stopMeteringTimer()
        teardownLiveTranscription()
        recorder = nil
        currentFileURL = nil
        elapsedSeconds = 0
        waveformLevel = 0.0
        waveformHistory = Array(repeating: 0.04, count: 40)
        wasInterrupted = false
        interruptionMessage = nil
        state = .idle
    }

    // MARK: - Whisper Transcription

    func transcribeAudio(at url: URL) async -> String? {
        // C4 fix: when the master AI toggle is off, do not call any cloud ASR
        // even if the network is up. Fall back to on-device SFSpeechRecognizer
        // so the user still gets a transcript without any third-party upload.
        if !AppSettings.aiFeaturesEnabled {
            return await transcribeAudioOffline(at: url)
        }
        // US-013: If offline, skip cloud ASR and try on-device SFSpeechRecognizer
        if !NetworkMonitor.shared.isOnline {
            return await transcribeAudioOffline(at: url)
        }

        // #821: when the selected provider has no credentials, fall back to
        // on-device recognition instead of silently returning nil and burning
        // the queue's retry budget on calls that can never succeed.
        switch ASRSettings.active {
        case .onDevice:
            return await transcribeAudioOffline(at: url)

        case .doubao:
            guard DoubaoASRConfig.hasCredentials else {
                return await transcribeAudioOffline(at: url)
            }
            return await transcribeAudioDoubao(at: url)

        case .whisper:
            guard !Secrets.resolvedOpenAIWhisperApiKey.isEmpty else {
                return await transcribeAudioOffline(at: url)
            }
            return await transcribeAudioWhisper(at: url)
        }
    }

    // MARK: - Doubao (火山引擎) Transcription

    private func transcribeAudioDoubao(at url: URL) async -> String? {
        let span = Secrets.sentryDSN.isEmpty ? nil
            : SentrySDK.startTransaction(name: "voice.doubao", operation: "http.client")
        defer { span?.finish() }

        do {
            return try await DoubaoFileASRClient.transcribe(at: url)
        } catch DoubaoFileASRClient.ClientError.silentAudio {
            // The service parsed the audio and found no speech. Retrying or
            // falling back to on-device recognition would just spend time
            // rediscovering the same thing.
            DayPageLogger.shared.info("transcribeAudioDoubao: silent audio, no speech detected")
            return nil
        } catch {
            DayPageLogger.shared.error("transcribeAudioDoubao: \(error.localizedDescription)")
            SentryReporter.breadcrumb(
                category: "voice",
                level: .error,
                message: "transcribeAudioDoubao: \(error.localizedDescription)"
            )
            // Cloud ASR failed but the audio is intact on disk — on-device
            // recognition is a better outcome than no transcript at all.
            return await transcribeAudioOffline(at: url)
        }
    }

    // MARK: - On-device fallback (US-013)

    private func transcribeAudioOffline(at url: URL) async -> String? {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized ||
              SFSpeechRecognizer.authorizationStatus() == .notDetermined else { return nil }

        // Request permission if not yet determined
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            let granted = await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { status in
                    cont.resume(returning: status == .authorized)
                }
            }
            guard granted else { return nil }
        }

        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { return nil }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = true

        // Hold the recognition task on a NSLock-protected box so the recognitionTask
        // callback (any thread) and the timeout path can coordinate cancellation
        // without double-resuming the continuation or leaking the task.
        // Without this, audio that produces only partial results (or no terminal
        // callback at all) would hang `stopAndTranscribe()` forever and freeze
        // the UI in `.processing`.
        final class TaskBox {
            let lock = NSLock()
            var task: SFSpeechRecognitionTask?
            var continuation: CheckedContinuation<String?, Never>?
            var didResume: Bool = false
        }
        let box = TaskBox()

        return await Self.withTimeout(seconds: 30) {
            await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
                box.lock.lock()
                box.continuation = cont
                // If the timeout already fired before we stored the continuation
                // (extremely unlikely but possible), resume immediately.
                let raceLost = box.didResume
                box.lock.unlock()

                if raceLost {
                    cont.resume(returning: nil)
                    return
                }

                let task = recognizer.recognitionTask(with: request) { result, error in
                    let resumeValue: String?
                    if let result, result.isFinal {
                        resumeValue = result.bestTranscription.formattedString
                    } else if error != nil {
                        resumeValue = nil
                    } else {
                        // Non-terminal callback (partial result without isFinal). Wait for next.
                        return
                    }

                    box.lock.lock()
                    let alreadyResumed = box.didResume
                    if !alreadyResumed { box.didResume = true }
                    let cont = box.continuation
                    box.lock.unlock()

                    if !alreadyResumed, let cont {
                        cont.resume(returning: resumeValue)
                    }
                }
                box.lock.lock()
                box.task = task
                box.lock.unlock()
            }
        } onTimeout: {
            // Timeout fired: cancel the recognition task and resume the continuation
            // directly so `withCheckedContinuation` doesn't hang forever.
            // Defense-in-depth: skip the resume when the recognition callback
            // already resumed (didResume) — a second resume traps.
            box.lock.lock()
            let alreadyResumed = box.didResume
            box.didResume = true
            let task = box.task
            let cont = alreadyResumed ? nil : box.continuation
            box.lock.unlock()
            task?.cancel()
            cont?.resume(returning: nil)
        }
    }

    private func transcribeAudioWhisper(at url: URL) async -> String? {
        let apiKey = Secrets.resolvedOpenAIWhisperApiKey
        guard !apiKey.isEmpty else { return nil }

        let audioData: Data
        // #821 main-thread hygiene: this class is @MainActor, and a 5-minute
        // take is several MB — reading it synchronously here froze a frame.
        // Hop to a detached task for the disk read.
        do { audioData = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value }
        catch {
            DayPageLogger.shared.error("transcribeAudio: read file: \(error)")
            SentryReporter.breadcrumb(
                category: "voice",
                level: .error,
                message: "transcribeAudioWhisper: readFailed \(url.lastPathComponent): \(error)"
            )
            return nil
        }

        let boundary = UUID().uuidString
        var body = Data()

        // -- model field
        let modelField = "--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n"
        body.append(Data(modelField.utf8))

        // 不提供语言提示 —— 让 Whisper 自动检测以支持多语言

        // -- file field
        let fileHeader = "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(url.lastPathComponent)\"\r\nContent-Type: audio/m4a\r\n\r\n"
        body.append(Data(fileHeader.utf8))
        body.append(audioData)
        body.append(Data("\r\n".utf8))

        // -- closing boundary
        body.append(Data("--\(boundary)--\r\n".utf8))

        guard let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions") else { return nil }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 60

        let span = Secrets.sentryDSN.isEmpty ? nil
            : SentrySDK.startTransaction(name: "voice.whisper", operation: "http.client")
        defer { span?.finish() }

        // 对瞬时服务器/速率限制错误（429、500、503）最多重试 3 次
        let maxAttempts = 3
        var delaySeconds: UInt64 = 2

        for attempt in 1...maxAttempts {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { return nil }

                if http.statusCode == 200 {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let text = json["text"] as? String {
                        return text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    return nil
                }

                // 可重试：速率限制或服务器错误
                let retryable = http.statusCode == 429 || http.statusCode >= 500
                if retryable && attempt < maxAttempts {
                    try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
                    delaySeconds *= 2
                    continue
                }

                // 不可重试的错误或重试次数已耗尽
                return nil
            } catch {
                // Cancellation should not be retried — the caller (user
                // backgrounding the app, view dismounting) explicitly asked
                // for this work to stop. Without this guard we'd burn 2-8s
                // sleeping before another doomed attempt.
                if (error as? URLError)?.code == .cancelled || Task.isCancelled {
                    return nil
                }
                if attempt < maxAttempts {
                    try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
                    delaySeconds *= 2
                    continue
                }
                return nil
            }
        }
        return nil
    }

    // MARK: - File URL Helper

    private func makeAudioFileURL() -> URL {
        let filename = RawStorage.assetFilename(prefix: "voice", ext: "m4a")

        // 确保目录存在
        let assetsURL: URL
        do { assetsURL = try VaultInitializer.assetsDirectory() }
        catch {
            DayPageLogger.shared.error("VoiceService: createDirectory: \(error)")
            assetsURL = VaultInitializer.assetsDirectoryURL
        }

        return assetsURL.appendingPathComponent(filename)
    }

    // MARK: - Timer

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.elapsedSeconds += 1
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Metering Timer (~30fps)

    private func startMeteringTimer() {
        meteringTimer?.invalidate()
        meteringTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let rec = self.recorder, self.state == .recording else { return }
                rec.updateMeters()
                let power = rec.averagePower(forChannel: 0) // -160 到 0 dB
                // 将 -60dB..0dB 映射到 0..1，低于 -60dB 限制在接近零
                let normalized = Float(max(0.04, min(1.0, (Double(power) + 60.0) / 60.0)))
                self.waveformLevel = normalized
                // 平移历史记录并追加
                self.waveformHistory.removeFirst()
                self.waveformHistory.append(normalized)
            }
        }
    }

    private func stopMeteringTimer() {
        meteringTimer?.invalidate()
        meteringTimer = nil
    }
}

// MARK: - Timeout Helper

extension VoiceService {
    /// Race `operation` against a timeout. Returns the operation's result if it
    /// completes within `seconds`, otherwise invokes `onTimeout` (for cleanup
    /// such as cancelling an in-flight task) and returns `nil`.
    ///
    /// The losing branch is cancelled via Swift structured concurrency so the
    /// caller never has to manage task lifetimes manually.
    static func withTimeout<T>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async -> T?,
        onTimeout: @escaping @Sendable () -> Void = {}
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                await operation()
            }
            group.addTask {
                let ns = UInt64(max(0, seconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
                // The winning operation branch triggers group.cancelAll(),
                // which wakes this sleep early with a CancellationError that
                // `try?` swallows. Running onTimeout() in that case fired the
                // timeout cleanup after a SUCCESSFUL completion — for the
                // offline transcriber that meant resuming its continuation a
                // second time (EXC_BREAKPOINT, observed 2026-07-11 20:30/33).
                guard !Task.isCancelled else { return nil }
                onTimeout()
                return nil
            }
            // Take the first finished branch and cancel the rest.
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

// MARK: - AVAudioRecorderDelegate

extension VoiceService: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        // 由 stopAndTranscribe / cancelRecording 流程处理
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let msg = error?.localizedDescription ?? "编码错误"
        Task { @MainActor in
            self.state = .failed("录音编码错误：\(msg)")
        }
    }
}
