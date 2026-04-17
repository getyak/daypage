import Foundation
import AVFoundation
import UIKit
import Speech

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
    /// Vault-relative path, e.g. "raw/assets/voice_20260415_143000.m4a"
    let filePath: String
    /// Absolute URL on device
    let fileURL: URL
    /// Duration in seconds
    let duration: TimeInterval
    /// Whisper transcript (nil if transcription failed or not yet done)
    let transcript: String?
}

// MARK: - VoiceService

/// Handles microphone permission, audio recording (AVAudioRecorder) and
/// Whisper API transcription.  Always runs on the MainActor so SwiftUI
/// can bind directly to @Published properties.
@MainActor
final class VoiceService: NSObject, ObservableObject {

    static let shared = VoiceService()

    // MARK: Published

    @Published var state: RecordingState = .idle
    /// Live elapsed seconds (updated every second during recording)
    @Published var elapsedSeconds: Int = 0
    /// Normalised audio level 0.0–1.0, updated at ~30fps during recording
    @Published var waveformLevel: Float = 0.0
    /// Rolling history of waveform levels (last 40 samples) for bar display
    @Published var waveformHistory: [Float] = Array(repeating: 0.04, count: 40)
    /// Live transcription text from SFSpeechRecognizer (updated in real-time while recording)
    @Published var liveTranscript: String = ""

    // MARK: Private

    private var recorder: AVAudioRecorder?
    private var currentFileURL: URL?
    private var recordingStartDate: Date?
    private var timer: Timer?
    private var meteringTimer: Timer?

    // MARK: - Speech Recognition
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?

    // MARK: - Permission

    /// Requests microphone permission if not yet granted.
    /// Returns true when permission is granted.
    /// Uses AVAudioSession API for iOS 16 compatibility.
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

    /// Requests permission, sets up the audio session, and starts recording.
    /// Sets `state` to `.recording` on success, `.failed` on error.
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
            liveTranscript = ""
            waveformHistory = Array(repeating: 0.04, count: 40)
            startTimer()
            startMeteringTimer()
            state = .recording
        } catch {
            state = .failed("录音启动失败：\(error.localizedDescription)")
            return
        }

        // Start live transcription with SFSpeechRecognizer (best-effort, non-blocking)
        await startLiveTranscription()
    }

    // MARK: - Live Transcription

    private func startLiveTranscription() async {
        // Request speech recognition authorization
        let authStatus = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        guard authStatus == .authorized else { return }

        let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        guard let recognizer, recognizer.isAvailable else { return }
        self.speechRecognizer = recognizer

        let engine = AVAudioEngine()
        self.audioEngine = engine

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false
        self.recognitionRequest = request

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            stopLiveTranscription()
            return
        }

        self.recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                Task { @MainActor in
                    self.liveTranscript = result.bestTranscription.formattedString
                }
            }
            if error != nil || (result?.isFinal == true) {
                Task { @MainActor in
                    self.stopLiveTranscription()
                }
            }
        }
    }

    private func stopLiveTranscription() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        speechRecognizer = nil
    }

    // MARK: - Pause / Resume

    func pauseRecording() {
        guard state == .recording else { return }
        recorder?.pause()
        stopTimer()
        stopMeteringTimer()
        stopLiveTranscription()
        state = .paused
    }

    func resumeRecording() {
        guard state == .paused else { return }
        recorder?.record()
        startTimer()
        startMeteringTimer()
        state = .recording
        Task { await startLiveTranscription() }
    }

    // MARK: - Stop & Transcribe

    /// Stops recording, saves the .m4a file, calls Whisper API, and returns a result.
    /// On network failure the audio is still saved; transcript will be nil.
    /// Returns nil only when there was never a valid recording to save.
    func stopAndTranscribe() async -> VoiceRecordingResult? {
        guard let rec = recorder, let fileURL = currentFileURL else {
            state = .failed("没有活跃的录音")
            return nil
        }

        stopTimer()
        stopMeteringTimer()
        stopLiveTranscription()
        let finalDuration = Double(elapsedSeconds)
        rec.stop()
        recorder = nil

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // Non-fatal: log and continue
        }

        // Capture live transcript before it's cleared
        let capturedLiveTranscript = liveTranscript.isEmpty ? nil : liveTranscript
        state = .processing

        // Derive vault-relative path
        let filePath = "raw/assets/\(fileURL.lastPathComponent)"

        // Use live transcript if available, otherwise fall back to Whisper API
        let transcript: String?
        if let live = capturedLiveTranscript, !live.isEmpty {
            transcript = live
        } else {
            transcript = await transcribeAudio(at: fileURL)
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

    /// Aborts recording without saving.
    func cancelRecording() {
        stopTimer()
        stopMeteringTimer()
        stopLiveTranscription()
        recorder?.stop()
        if let url = currentFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        recorder = nil
        currentFileURL = nil
        elapsedSeconds = 0
        liveTranscript = ""
        state = .idle
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Resets state back to idle (call after the result has been consumed).
    func reset() {
        stopTimer()
        stopMeteringTimer()
        stopLiveTranscription()
        recorder = nil
        currentFileURL = nil
        elapsedSeconds = 0
        liveTranscript = ""
        waveformLevel = 0.0
        waveformHistory = Array(repeating: 0.04, count: 40)
        state = .idle
    }

    // MARK: - Whisper Transcription

    private func transcribeAudio(at url: URL) async -> String? {
        let apiKey = Secrets.openAIWhisperApiKey
        guard !apiKey.isEmpty else { return nil }

        guard let audioData = try? Data(contentsOf: url) else { return nil }

        let boundary = UUID().uuidString
        var body = Data()

        // -- model field
        let modelField = "--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n"
        body.append(Data(modelField.utf8))

        // No language hint — let Whisper auto-detect for multilingual support

        // -- file field
        let fileHeader = "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(url.lastPathComponent)\"\r\nContent-Type: audio/m4a\r\n\r\n"
        body.append(Data(fileHeader.utf8))
        body.append(audioData)
        body.append(Data("\r\n".utf8))

        // -- closing boundary
        body.append(Data("--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 60

        // Retry up to 3 times for transient server/rate-limit errors (429, 500, 503)
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

                // Retryable: rate-limit or server error
                let retryable = http.statusCode == 429 || http.statusCode >= 500
                if retryable && attempt < maxAttempts {
                    try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
                    delaySeconds *= 2
                    continue
                }

                // Non-retryable error or exhausted retries
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

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)

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
                let power = rec.averagePower(forChannel: 0) // -160 to 0 dB
                // Map -60dB..0dB → 0..1, clamp below -60dB to near-zero
                let normalized = Float(max(0.04, min(1.0, (Double(power) + 60.0) / 60.0)))
                self.waveformLevel = normalized
                // Shift history and append
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
        // Handled by stopAndTranscribe / cancelRecording flows
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let msg = error?.localizedDescription ?? "编码错误"
        Task { @MainActor in
            self.state = .failed("录音编码错误：\(msg)")
        }
    }
}
