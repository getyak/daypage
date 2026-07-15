import Foundation
import AVFoundation

// MARK: - LivePCMCapture

/// Taps the microphone and emits 16kHz / 16-bit / mono PCM chunks — the only
/// format the Doubao streaming ASR service accepts.
///
/// `AVAudioRecorder` (used for memo capture) writes a file and hands nothing
/// back mid-recording, so streaming needs `AVAudioEngine`'s input tap instead.
/// The hardware format is whatever the device decides (typically 44.1/48kHz
/// float32), so every buffer is converted before it leaves here.
///
/// This does NOT configure or activate the AVAudioSession: `VoiceService`
/// already owns session lifecycle for the recording it runs in parallel, and
/// two owners racing on `setActive` is how you get silent recordings.
final class LivePCMCapture {

    enum CaptureError: Error, LocalizedError {
        case engineStartFailed(Error)
        case converterUnavailable

        var errorDescription: String? {
            switch self {
            case .engineStartFailed(let error): return "麦克风采集启动失败：\(error.localizedDescription)"
            case .converterUnavailable:         return "音频格式转换不可用"
            }
        }
    }

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var isRunning = false

    /// Target format: 16kHz mono s16le, interleaved — matches the ASR contract.
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Double(DoubaoStreamASRClient.sampleRate),
        channels: AVAudioChannelCount(DoubaoStreamASRClient.channels),
        interleaved: true
    )

    /// Starts tapping the mic. `onChunk` fires on a background audio thread —
    /// hop to your own actor before touching shared state.
    func start(onChunk: @escaping @Sendable (Data) -> Void) throws {
        guard !isRunning else { return }
        guard let targetFormat else { throw CaptureError.converterUnavailable }

        let input = engine.inputNode
        let hardwareFormat = input.outputFormat(forBus: 0)

        guard let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            throw CaptureError.converterUnavailable
        }
        self.converter = converter

        // Buffer size is a hint; the tap delivers whatever the hardware gives.
        // We convert per-callback rather than batching to a fixed 200ms packet:
        // live capture already paces the stream, and buffering would only add
        // latency to the very thing the user is watching appear on screen.
        input.installTap(onBus: 0, bufferSize: 4_096, format: hardwareFormat) { buffer, _ in
            guard let data = Self.convert(buffer, using: converter, to: targetFormat) else { return }
            if !data.isEmpty { onChunk(data) }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.converter = nil
            throw CaptureError.engineStartFailed(error)
        }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        isRunning = false
    }

    deinit {
        // Not calling stop() — an engine torn down mid-tap can crash in
        // CoreAudio. Callers own the lifecycle; this is a safety net for the
        // tap only.
        if isRunning { engine.inputNode.removeTap(onBus: 0); engine.stop() }
    }

    // MARK: - Conversion

    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> Data? {
        // Output capacity must cover the sample-rate ratio (e.g. 48k → 16k
        // shrinks by 3, but a rounding shortfall truncates audio).
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1_024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            // Feed each input buffer exactly once; reporting .haveData twice
            // makes the converter re-read a spent buffer and emit garbage.
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0,
              let channel = out.int16ChannelData else { return nil }

        return Data(bytes: channel[0], count: Int(out.frameLength) * MemoryLayout<Int16>.size)
    }
}
