import Foundation

// MARK: - ASRProvider

/// Speech-to-text backend selection.
///
/// The default is resolved at runtime from `Secrets.voiceASRProvider` (fed by
/// `VOICE_ASR_PROVIDER` in `.env`), falling back to `.doubao`. Users can
/// override this in Settings → 语音转写.
///
/// Both providers degrade to on-device `SFSpeechRecognizer` when their
/// credentials are absent — see `VoiceService.transcribeAudio(at:)`.
enum ASRProvider: String, CaseIterable, Identifiable {
    /// 火山引擎 / Volcano Engine. Streaming + recorded-file transcription.
    case doubao
    /// OpenAI Whisper. Recorded-file transcription only.
    case whisper
    /// Never touch the network; always use on-device recognition.
    case onDevice

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .doubao:   return "豆包 · 火山引擎"
        case .whisper:  return "OpenAI Whisper"
        case .onDevice: return "仅设备端"
        }
    }

    /// Whether this provider can transcribe incrementally while the user is
    /// still speaking. Drives whether the recording UI shows live text.
    var supportsStreaming: Bool {
        switch self {
        case .doubao:             return true
        case .whisper, .onDevice: return false
        }
    }

    /// True when the provider needs credentials before it can be used at all.
    var requiresCredentials: Bool { self != .onDevice }
}

// MARK: - ASRSettings

/// Single source of truth for which ASR backend is active.
///
/// Resolution order: user override (UserDefaults) → `.env` default
/// (`Secrets.voiceASRProvider`) → `.doubao`.
enum ASRSettings {

    static let providerDefaultsKey = "voiceASRProvider"

    /// The provider the user explicitly picked, or `nil` to follow the
    /// `.env`-configured default.
    static var override: ASRProvider? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: providerDefaultsKey) else { return nil }
            return ASRProvider(rawValue: raw)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.rawValue, forKey: providerDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: providerDefaultsKey)
            }
        }
    }

    /// The provider that should actually be used right now.
    static var active: ASRProvider {
        if let override { return override }
        if let fromEnv = ASRProvider(rawValue: Secrets.voiceASRProvider.trimmingCharacters(in: .whitespaces)) {
            return fromEnv
        }
        return .doubao
    }
}

// MARK: - Doubao endpoint configuration

/// Endpoint routing for the Doubao ASR services.
///
/// These carry hard-coded defaults rather than requiring `.env` entries: they
/// are public, stable ByteDance hostnames, and an empty `.env` value would
/// otherwise produce an unhelpful "invalid URL" failure at call time.
enum DoubaoASRConfig {

    static let defaultStreamURL = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel"
    /// 极速版 (flash): single-shot recognize, result returned inline. The
    /// standard `/auc/bigmodel/submit` endpoint is deliberately NOT used — it
    /// only accepts a publicly-reachable audio `url`, which would mean
    /// uploading users' voice memos to public storage first.
    static let defaultFileSubmitURL = "https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash"

    static var streamURL: String {
        let configured = Secrets.doubaoASRStreamURL.trimmingCharacters(in: .whitespaces)
        return configured.isEmpty ? defaultStreamURL : configured
    }

    static var fileSubmitURL: String {
        let configured = Secrets.doubaoASRFileURL.trimmingCharacters(in: .whitespaces)
        return configured.isEmpty ? defaultFileSubmitURL : configured
    }

    /// `model_name` in the request body. Distinct from `X-Api-Resource-Id`
    /// below — conflating the two yields an auth failure, not a model error.
    static let fileModelName = "bigmodel"

    // MARK: Resource IDs (X-Api-Resource-Id header)

    /// 极速版 file transcription — single-shot, no polling.
    static let fileResourceID = "volc.bigasr.auc_turbo"

    /// 流式语音识别大模型 1.0, 小时版 (`volc.bigasr.sauc.duration`).
    ///
    /// The 并发版 sibling (`…sauc.concurrent`) is provisioned separately and
    /// rejects connections with `45000292 quota exceeded` until concurrency
    /// is purchased, so 小时版 is the default. Note this is the 1.0 family:
    /// the 2.0 IDs (`volc.seedasr.sauc.*`) are rejected outright by the
    /// `/sauc/bigmodel` endpoint with `400 … is not allowed`.
    static let streamResourceID = "volc.bigasr.sauc.duration"

    // MARK: Credentials

    static var appID: String { Secrets.resolvedDoubaoASRAppID }
    static var accessToken: String { Secrets.resolvedDoubaoASRAccessToken }
    static var secretKey: String { Secrets.resolvedDoubaoASRSecretKey }

    /// Doubao authenticates with an App ID + Access Token pair; both must be
    /// present. The Secret Key is only required for signed request flows.
    static var hasCredentials: Bool {
        !appID.isEmpty && !accessToken.isEmpty
    }
}
