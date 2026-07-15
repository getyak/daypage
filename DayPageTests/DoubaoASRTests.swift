import Testing
import Foundation
@testable import DayPage

/// Unit tests for the Doubao ASR plumbing: the gzip codec every streaming
/// frame depends on, and provider selection/fallback.
///
/// The binary frame layout itself was verified against the live
/// `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel` endpoint (transcript
/// streamed back correctly) and byte-diffed against the official Python demo.
/// These tests cover the parts that can regress silently offline.
@Suite("Doubao ASR")
struct DoubaoASRTests {

    // MARK: - GzipCodec

    /// The streaming protocol gzips every payload in both directions, so a
    /// broken round-trip means every frame is rejected — with an opaque error.
    @Test("gzip round-trips arbitrary bytes")
    func gzipRoundTrip() throws {
        let original = Data((0..<6_400).map { UInt8($0 % 251) })
        let compressed = try GzipCodec.compress(original)
        #expect(compressed != original)
        #expect(try GzipCodec.decompress(compressed) == original)
    }

    /// A 200ms PCM chunk is the real payload shape; verify the codec emits a
    /// genuine gzip container (magic 0x1f 0x8b) rather than a raw deflate
    /// stream. Foundation's `Compression` zlib algorithm produces the latter,
    /// which the service silently rejects — this is exactly why GzipCodec
    /// drives zlib directly.
    @Test("gzip output carries the gzip magic header")
    func gzipMagicHeader() throws {
        let compressed = try GzipCodec.compress(Data(repeating: 0x41, count: 1_024))
        #expect(compressed.count >= 2)
        #expect(compressed[compressed.startIndex] == 0x1f)
        #expect(compressed[compressed.startIndex + 1] == 0x8b)
    }

    @Test("gzip handles empty input without throwing")
    func gzipEmpty() throws {
        #expect(try GzipCodec.compress(Data()).isEmpty)
        #expect(try GzipCodec.decompress(Data()).isEmpty)
    }

    @Test("gzip round-trips UTF-8 JSON payloads")
    func gzipJSONRoundTrip() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "user": ["uid": "daypage"],
            "audio": ["format": "pcm", "rate": 16_000],
        ])
        #expect(try GzipCodec.decompress(try GzipCodec.compress(payload)) == payload)
    }

    // MARK: - Provider selection

    /// `.onDevice` must never advertise streaming — the UI reserves live-text
    /// space based on this, and Whisper is file-only.
    @Test("only Doubao advertises streaming support")
    func streamingSupport() {
        #expect(ASRProvider.doubao.supportsStreaming)
        #expect(!ASRProvider.whisper.supportsStreaming)
        #expect(!ASRProvider.onDevice.supportsStreaming)
    }

    @Test("on-device provider needs no credentials")
    func credentialRequirements() {
        #expect(ASRProvider.doubao.requiresCredentials)
        #expect(ASRProvider.whisper.requiresCredentials)
        #expect(!ASRProvider.onDevice.requiresCredentials)
    }

    /// Round-tripping through rawValue is what `ASRSettings` persistence and
    /// the `.env` default both rely on.
    @Test("provider raw values round-trip")
    func rawValueRoundTrip() {
        for provider in ASRProvider.allCases {
            #expect(ASRProvider(rawValue: provider.rawValue) == provider)
        }
    }

    /// Endpoints must never resolve empty: `.env` may omit them entirely (the
    /// defaults are compiled in), and an empty string would surface as an
    /// unhelpful "invalid URL" at call time instead of working.
    @Test("Doubao endpoints fall back to compiled-in defaults")
    func endpointDefaults() {
        #expect(!DoubaoASRConfig.streamURL.isEmpty)
        #expect(!DoubaoASRConfig.fileSubmitURL.isEmpty)
        #expect(URL(string: DoubaoASRConfig.streamURL) != nil)
        #expect(URL(string: DoubaoASRConfig.fileSubmitURL) != nil)
        #expect(DoubaoASRConfig.streamURL.hasPrefix("wss://"))
    }

    /// `model_name` (body) and `X-Api-Resource-Id` (header) are different
    /// values that are easy to conflate — doing so yields an auth failure that
    /// looks like a model error. This pins them apart.
    @Test("resource IDs are distinct from the body model name")
    func resourceIDsNotConflated() {
        #expect(DoubaoASRConfig.fileResourceID == "volc.bigasr.auc_turbo")
        #expect(DoubaoASRConfig.streamResourceID == "volc.bigasr.sauc.duration")
        #expect(DoubaoASRConfig.fileModelName == "bigmodel")
        #expect(DoubaoASRConfig.fileResourceID != DoubaoASRConfig.fileModelName)
        #expect(DoubaoASRConfig.streamResourceID != DoubaoASRConfig.fileModelName)
    }

    /// Streaming audio contract: the service only accepts 16kHz/16-bit/mono,
    /// and the chunk size must match 200ms at that rate (16000 × 2 × 0.2).
    @Test("streaming audio constants match the service contract")
    func streamingAudioContract() {
        #expect(DoubaoStreamASRClient.sampleRate == 16_000)
        #expect(DoubaoStreamASRClient.bitsPerSample == 16)
        #expect(DoubaoStreamASRClient.channels == 1)
        let bytesPerSecond = DoubaoStreamASRClient.sampleRate * (DoubaoStreamASRClient.bitsPerSample / 8)
        #expect(DoubaoStreamASRClient.chunkBytes == bytesPerSecond / 5)
    }
}
