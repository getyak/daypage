import Foundation
import AVFoundation
import Sentry

// MARK: - Recording State

enum RecordingState: Equatable {
    case idle
    case requesting        // waiting for mic permission
    case recording         // actively recording
    case paused            // paused mid-recording
    case processing        // stopped, transcribing
    case done              // transcription complete / saved
    case failed(String)    // error with user-facing message

    static func == (lhs: RecordingState, rhs: RecordingState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.requesting, .requesting),
             (.recording, .recording), (.paused, .paused),
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
    /// 录制中每秒更新的实时已过秒数
    @Published var elapsedSeconds: Int = 0
    /// 归一化音频电平 0.0–1.0，录制中约 30fps 更新
    @Published var waveformLevel: Float = 0.0
    /// 波形电平滚动历史记录（最近 40 个采样），用于条形显示
    @Published var waveformHistory: [Float] = Array(repeating: 0.04, count: 40)

    // MARK: Private

    private var recorder: AVAudioRecorder?
    private var currentFileURL: URL?
    private var recordingStartDate: Date?
    private var timer: Timer?
    private var meteringTimer: Timer?

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

    /// 请求权限、设置音频会话并开始录制。
    /// 成功时将 `state` 设为 `.recording`，失败时设为 `.failed`。
    func startRecording() async {
        state = .requesting
        let granted = await requestMicrophonePermission()
        guard granted else {
            state = .failed("麦克风权限被拒绝，请在「设置 -> 隐私 -> 麦克风」中授权")
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            state = .failed("音频会话初始化失败：\(error.localizedDescription)")
            return
        }

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
    }

    // MARK: - Pause / Resume

    func pauseRecording() {
        guard state == .recording else { return }
        recorder?.pause()
        stopTimer()
        stopMeteringTimer()
        state = .paused
    }

    func resumeRecording() {
        guard state == .paused else { return }
        recorder?.record()
        startTimer()
        startMeteringTimer()
        state = .recording
    }

    // MARK: - Stop & Transcribe

    /// 停止录制、保存 .m4a 文件、调用 Whisper API 并返回结果。
    /// 网络失败时音频仍会保存；transcript 将为 nil。
    /// 仅在没有有效可保存的录音时返回 nil。
    func stopAndTranscribe() async -> VoiceRecordingResult? {
        guard let rec = recorder, let fileURL = currentFileURL else {
            state = .failed("没有活跃的录音")
            return nil
        }

        stopTimer()
        stopMeteringTimer()
        let finalDuration = Double(elapsedSeconds)
        rec.stop()
        recorder = nil

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // 非致命错误：记录日志并继续
        }

        state = .processing

        // 推导 vault 相对路径
        let filePath = "raw/assets/\(fileURL.lastPathComponent)"

        let transcript = await transcribeAudio(at: fileURL)

        // 如果转录失败且处于离线状态，加入队列等待稍后处理
        if transcript == nil && !NetworkMonitor.shared.isOnline {
            VoiceAttachmentQueue.shared.enqueue(audioPath: filePath, memoDate: Date())
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
    func cancelRecording() {
        stopTimer()
        stopMeteringTimer()
        recorder?.stop()
        if let url = currentFileURL {
            try? FileManager.default.removeItem(at: url)
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
        recorder = nil
        currentFileURL = nil
        elapsedSeconds = 0
        waveformLevel = 0.0
        waveformHistory = Array(repeating: 0.04, count: 40)
        state = .idle
    }

    // MARK: - Whisper Transcription

    func transcribeAudio(at url: URL) async -> String? {
        let apiKey = Secrets.resolvedOpenAIWhisperApiKey
        guard !apiKey.isEmpty else { return nil }

        let audioData: Data
        do { audioData = try Data(contentsOf: url) }
        catch { DayPageLogger.shared.error("transcribeAudio: read file: \(error)"); return nil }

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

        var request = URLRequest(url: URL(staticString: "https://api.openai.com/v1/audio/transcriptions"))
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
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = formatter.string(from: Date())
        let filename = "voice_\(stamp).m4a"

        let assetsURL = VaultInitializer.vaultURL
            .appendingPathComponent("raw")
            .appendingPathComponent("assets")

        // 确保目录存在
        do { try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true) }
        catch { DayPageLogger.shared.error("VoiceService: createDirectory: \(error)") }

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
