import Foundation
import DayPageStorage

// MARK: - DoubaoFileASRClient

/// Recorded-file transcription via 豆包 录音文件极速版 (flash).
///
/// Why the flash endpoint and not the standard `/auc/bigmodel/submit`:
/// the standard API's `audio` object accepts only a publicly-reachable `url`
/// — it has no inline-data field. Using it would mean uploading users' voice
/// memos to public object storage before transcription. Flash accepts inline
/// base64 (`audio.data`) and returns the result in a single round trip with
/// no submit/query polling, so recordings never leave the device except as
/// the request body itself.
///
/// Requires the `volc.bigasr.auc_turbo` entitlement to be enabled in the
/// 火山引擎 console — it is provisioned separately from the streaming and
/// standard recorded-file services.
struct DoubaoFileASRClient {

    /// Outcome codes from the `X-Api-Status-Code` response header. The HTTP
    /// status is 200 even for failures — the real verdict lives here.
    private enum StatusCode {
        static let success = "20000000"
        static let silentAudio = "20000003"
    }

    enum ClientError: Error, LocalizedError {
        case missingCredentials
        case invalidEndpoint
        case readFailed(Error)
        case audioTooLarge(bytes: Int)
        case silentAudio
        case requestFailed(status: String?, message: String?, http: Int)
        case emptyTranscript

        var errorDescription: String? {
            switch self {
            case .missingCredentials:
                return "豆包语音未配置 App ID / Access Token"
            case .invalidEndpoint:
                return "豆包语音端点配置无效"
            case .readFailed(let error):
                return "读取音频失败：\(error.localizedDescription)"
            case .audioTooLarge(let bytes):
                return "音频过大（\(bytes / 1_048_576)MB），超出内联上传上限"
            case .silentAudio:
                return "音频中未检测到语音"
            case .requestFailed(let status, let message, let http):
                return "豆包识别失败（HTTP \(http) / \(status ?? "?")）：\(message ?? "未知错误")"
            case .emptyTranscript:
                return "豆包返回了空转写结果"
            }
        }
    }

    /// Docs cap inline binary uploads at "大小尽量20M以内". Whether that
    /// measures the raw bytes or the ~33%-inflated base64 is unspecified, so
    /// we budget against the raw file and stay well under.
    static let maxInlineBytes = 18 * 1_024 * 1_024

    /// Transcribes the audio file at `url`, returning plain text.
    static func transcribe(at url: URL) async throws -> String {
        guard DoubaoASRConfig.hasCredentials else { throw ClientError.missingCredentials }
        guard let endpoint = URL(string: DoubaoASRConfig.fileSubmitURL) else {
            throw ClientError.invalidEndpoint
        }

        let audioData: Data
        do {
            // VoiceService is @MainActor and a long take is several MB —
            // reading it synchronously here would drop frames.
            audioData = try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: url)
            }.value
        } catch {
            throw ClientError.readFailed(error)
        }

        guard audioData.count <= maxInlineBytes else {
            throw ClientError.audioTooLarge(bytes: audioData.count)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(DoubaoASRConfig.appID, forHTTPHeaderField: "X-Api-App-Key")
        request.setValue(DoubaoASRConfig.accessToken, forHTTPHeaderField: "X-Api-Access-Key")
        request.setValue(DoubaoASRConfig.fileResourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")

        let body: [String: Any] = [
            "user": ["uid": "daypage"],
            "audio": [
                "format": audioFormat(for: url.lastPathComponent),
                "data": audioData.base64EncodedString(),
            ],
            "request": [
                "model_name": DoubaoASRConfig.fileModelName,
                // Punctuation + inverse text normalization ("三点半" → "3点半")
                // make the transcript directly usable as memo body text.
                "enable_punc": true,
                "enable_itn": true,
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.value(forHTTPHeaderField: "X-Api-Status-Code")

        switch status {
        case StatusCode.success:
            guard let text = parseTranscript(from: data), !text.isEmpty else {
                throw ClientError.emptyTranscript
            }
            return text

        case StatusCode.silentAudio:
            // Distinct from a failure: the service parsed the audio fine and
            // found no speech. Callers surface this rather than retrying.
            throw ClientError.silentAudio

        default:
            throw ClientError.requestFailed(
                status: status,
                message: http?.value(forHTTPHeaderField: "X-Api-Message"),
                http: http?.statusCode ?? 0
            )
        }
    }

    // MARK: - Helpers

    /// Container hint for the `audio.format` field.
    ///
    /// The docs list only WAV / MP3 / OGG-OPUS, but m4a/AAC — what
    /// `AVAudioRecorder` produces here — was verified to transcribe correctly
    /// against the live flash endpoint (declared as either `mp4` or `m4a`).
    /// This is observed behaviour, not a documented guarantee: if the service
    /// ever tightens container sniffing, m4a will start returning
    /// `45000151 音频格式不正确`, and this mapping is where an on-device
    /// transcode (AVAssetReader → WAV) would be introduced.
    private static func audioFormat(for fileName: String) -> String {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "m4a", "mp4", "aac": return "mp4"
        case "wav":               return "wav"
        case "mp3":               return "mp3"
        case "ogg", "opus":       return "ogg"
        default:                  return "mp4"
        }
    }

    /// Response shape: `{ "result": { "text": "...", "utterances": [...] } }`.
    private static func parseTranscript(from data: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let result = json["result"] as? [String: Any]
        else { return nil }

        if let text = result["text"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let utterances = result["utterances"] as? [[String: Any]] {
            return utterances
                .compactMap { $0["text"] as? String }
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
}
