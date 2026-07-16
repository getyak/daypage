import Foundation

// MARK: - DoubaoTestError

enum DoubaoTestError: Error, LocalizedError {
    case sampleMissing
    case timeout

    var errorDescription: String? {
        switch self {
        case .sampleMissing:
            return NSLocalizedString("settings.doubao.test.sample_missing", comment: "Bundled test audio missing")
        case .timeout:
            return NSLocalizedString("settings.doubao.test.timeout", comment: "Probe timed out")
        }
    }
}

// MARK: - DoubaoProbeOutcome

/// Result of probing one Doubao endpoint with the bundled speech sample.
enum DoubaoProbeOutcome: Equatable {
    case passed(transcript: String, seconds: Double)
    case failed(message: String)

    var isPassed: Bool {
        if case .passed = self { return true }
        return false
    }
}

// MARK: - DoubaoVerification

/// Persisted verification state for the Doubao credentials, surfaced as the
/// status badge in Settings. A successful dual-endpoint test records a
/// timestamp; saving new credentials invalidates it.
enum DoubaoVerification {

    enum State: Equatable {
        case notConfigured
        case unverified
        case verified(Date)
        case failed(String)
    }

    private static let verifiedAtKey = "doubaoASRVerifiedAt"
    private static let detailKey = "doubaoASRVerifyDetail"

    static var state: State {
        guard DoubaoASRConfig.hasCredentials else { return .notConfigured }
        let store = UserDefaults.standard
        if let detail = store.string(forKey: detailKey), detail.hasPrefix("failed:") {
            return .failed(String(detail.dropFirst("failed:".count)))
        }
        if let at = store.object(forKey: verifiedAtKey) as? Date {
            return .verified(at)
        }
        return .unverified
    }

    static func recordPassed() {
        UserDefaults.standard.set(Date(), forKey: verifiedAtKey)
        UserDefaults.standard.set("passed", forKey: detailKey)
    }

    static func recordFailed(_ summary: String) {
        UserDefaults.standard.removeObject(forKey: verifiedAtKey)
        UserDefaults.standard.set("failed:\(summary)", forKey: detailKey)
    }

    /// Credentials changed — any previous verdict is stale.
    static func invalidate() {
        UserDefaults.standard.removeObject(forKey: verifiedAtKey)
        UserDefaults.standard.removeObject(forKey: detailKey)
    }
}

// MARK: - DoubaoErrorGuide

/// Translates Doubao / Volcano error codes into "what happened + where to fix
/// it" copy. Codes were established against the live service: resources are
/// provisioned per-item in the console, and each failure mode words its error
/// differently (403 grant vs 400 unknown-ID vs 45000292 quota).
enum DoubaoErrorGuide {

    enum Endpoint {
        case file    // 录音文件极速版 volc.bigasr.auc_turbo
        case stream  // 流式 volc.bigasr.sauc.duration
    }

    static func hint(status: String?, message: String?, endpoint: Endpoint) -> String {
        let raw = "\(status ?? "") \(message ?? "")".lowercased()
        let resourceName = endpoint == .file
            ? NSLocalizedString("settings.doubao.resource.file", comment: "File flash resource display name")
            : NSLocalizedString("settings.doubao.resource.stream", comment: "Streaming resource display name")

        if raw.contains("45000292") || raw.contains("quota") {
            return NSLocalizedString("settings.doubao.hint.quota", comment: "Quota exhausted hint")
        }
        if raw.contains("not granted") || raw.contains("403") {
            return String(format: NSLocalizedString("settings.doubao.hint.not_granted", comment: "Resource not granted hint"), resourceName)
        }
        if raw.contains("not allowed") {
            return String(format: NSLocalizedString("settings.doubao.hint.not_allowed", comment: "Resource ID rejected hint"), resourceName)
        }
        if raw.contains("45000151") {
            return NSLocalizedString("settings.doubao.hint.audio_format", comment: "Audio format hint")
        }
        if raw.contains("401") || raw.contains("invalid") || raw.contains("auth") {
            return NSLocalizedString("settings.doubao.hint.credentials", comment: "Invalid credentials hint")
        }
        let detail = [status, message].compactMap { $0 }.joined(separator: " · ")
        return detail.isEmpty
            ? NSLocalizedString("settings.doubao.hint.unknown", comment: "Unknown failure hint")
            : detail
    }
}

// MARK: - DoubaoConnectivityTester

/// Runs the real-transcription connectivity test: a bundled ~3s speech sample
/// (「你好豆包，今天天气不错」) is sent to BOTH endpoints the app uses in
/// production — the file flash endpoint (recorded memos) and the streaming
/// WebSocket (live dictation) — and each transcript is checked against the
/// expected phrase. This replaces the old silent-WAV probe, which proved auth
/// but never a single real transcription, and never touched streaming at all.
@MainActor
final class DoubaoConnectivityTester: ObservableObject {

    enum StepState: Equatable {
        case idle
        case running
        case passed(detail: String)
        case failed(message: String)
    }

    @Published private(set) var credentialStep: StepState = .idle
    @Published private(set) var fileStep: StepState = .idle
    @Published private(set) var streamStep: StepState = .idle
    @Published private(set) var isRunning = false

    /// What the bundled sample says. The match is fuzzy (see `matchScore`):
    /// streaming can drop words when audio is fed faster than real time, and
    /// punctuation differs between endpoints.
    static let expectedPhrase = "你好豆包，今天天气不错"

    static let sampleResource = "DoubaoTestSample"

    // MARK: Run

    func run() async {
        guard !isRunning else { return }
        isRunning = true
        credentialStep = .running
        fileStep = .idle
        streamStep = .idle
        defer { isRunning = false }

        // Step 0 — credential presence (pairs, not per-row).
        guard DoubaoASRConfig.hasCredentials else {
            credentialStep = .failed(message: NSLocalizedString("settings.doubao.test.need_credentials", comment: "Fill both fields first"))
            return
        }
        credentialStep = .passed(detail: NSLocalizedString("settings.doubao.test.credentials_ok", comment: "Credentials present"))

        // Step 1 — file flash endpoint (production path for recorded memos).
        fileStep = .running
        let fileOutcome = await probeFile()
        switch fileOutcome {
        case .passed(let transcript, let seconds):
            fileStep = .passed(detail: transcriptDetail(transcript, seconds: seconds))
        case .failed(let message):
            fileStep = .failed(message: message)
        }

        // Step 2 — streaming endpoint (production path for live dictation).
        streamStep = .running
        let streamOutcome = await probeStream()
        switch streamOutcome {
        case .passed(let transcript, let seconds):
            streamStep = .passed(detail: transcriptDetail(transcript, seconds: seconds))
        case .failed(let message):
            streamStep = .failed(message: message)
        }

        // Verdict — both endpoints must transcribe for "verified".
        if fileOutcome.isPassed && streamOutcome.isPassed {
            DoubaoVerification.recordPassed()
        } else {
            let failing = [
                fileOutcome.isPassed ? nil : NSLocalizedString("settings.doubao.step.file", comment: ""),
                streamOutcome.isPassed ? nil : NSLocalizedString("settings.doubao.step.stream", comment: ""),
            ].compactMap { $0 }.joined(separator: " + ")
            DoubaoVerification.recordFailed(failing)
        }
        objectWillChange.send()  // badge state (computed off UserDefaults) changed
    }

    private func transcriptDetail(_ transcript: String, seconds: Double) -> String {
        String(format: NSLocalizedString("settings.doubao.test.result_format", comment: "Recognized text + elapsed"), transcript, seconds)
    }

    // MARK: Sample

    nonisolated static func sampleURL() -> URL? {
        Bundle.main.url(forResource: sampleResource, withExtension: "wav")
    }

    /// Raw 16kHz mono PCM payload of the bundled WAV (the streaming endpoint
    /// takes headerless PCM). Our own asset, so a simple `data`-chunk scan
    /// is sufficient.
    nonisolated static func samplePCM() throws -> Data {
        guard let url = sampleURL() else { throw DoubaoTestError.sampleMissing }
        let wav = try Data(contentsOf: url)
        guard let range = wav.range(of: Data("data".utf8)) else { throw DoubaoTestError.sampleMissing }
        return wav.subdata(in: (range.upperBound + 4)..<wav.count)
    }

    // MARK: Fuzzy transcript match

    /// Fraction of recognized characters that appear in the expected phrase,
    /// after stripping punctuation/whitespace. Guards against "any non-empty
    /// garbage passes" while tolerating dropped words and punctuation drift.
    nonisolated static func matchScore(_ transcript: String) -> Double {
        let t = normalize(transcript)
        let e = Set(normalize(expectedPhrase))
        guard !t.isEmpty else { return 0 }
        let hits = t.filter { e.contains($0) }.count
        return Double(hits) / Double(t.count)
    }

    nonisolated static func normalize(_ s: String) -> String {
        String(s.unicodeScalars.filter {
            !CharacterSet.punctuationCharacters.contains($0)
                && !CharacterSet.whitespacesAndNewlines.contains($0)
                && !CharacterSet.symbols.contains($0)
        })
    }

    nonisolated private static func isAcceptable(_ transcript: String) -> Bool {
        normalize(transcript).count >= 2 && matchScore(transcript) >= 0.6
    }

    private func mismatchMessage(_ transcript: String) -> String {
        String(format: NSLocalizedString("settings.doubao.test.mismatch", comment: "Transcript did not match expected"), transcript)
    }

    // MARK: File probe

    private func probeFile() async -> DoubaoProbeOutcome {
        guard let url = Self.sampleURL() else {
            return .failed(message: DoubaoTestError.sampleMissing.localizedDescription)
        }
        let start = Date()
        do {
            let transcript = try await Self.withDeadline(seconds: 45) {
                try await DoubaoFileASRClient.transcribe(at: url)
            }
            guard Self.isAcceptable(transcript) else {
                return .failed(message: mismatchMessage(transcript))
            }
            return .passed(transcript: transcript, seconds: Date().timeIntervalSince(start))
        } catch let error as DoubaoFileASRClient.ClientError {
            if case .requestFailed(let status, let message, _) = error {
                return .failed(message: DoubaoErrorGuide.hint(status: status, message: message, endpoint: .file))
            }
            return .failed(message: error.localizedDescription)
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    // MARK: Stream probe

    private func probeStream() async -> DoubaoProbeOutcome {
        let pcm: Data
        do {
            pcm = try Self.samplePCM()
        } catch {
            return .failed(message: error.localizedDescription)
        }

        let start = Date()
        let client = DoubaoStreamASRClient()
        defer { Task { await client.close() } }

        do {
            let transcript = try await Self.withDeadline(seconds: 30) {
                try await client.start()

                // Feed 200ms chunks with a short pause: blasting audio faster
                // than real time makes the service drop mid-sentence words.
                let chunkBytes = DoubaoStreamASRClient.chunkBytes
                var offset = 0
                while offset < pcm.count {
                    let end = min(offset + chunkBytes, pcm.count)
                    let isLast = end == pcm.count
                    try await client.send(audio: pcm.subdata(in: offset..<end), isLast: isLast)
                    offset = end
                    if !isLast {
                        try await Task.sleep(nanoseconds: 20_000_000)
                    }
                }

                // Results are cumulative — keep the latest non-empty text.
                var latest = ""
                while let update = try await client.receive() {
                    if !update.text.isEmpty { latest = update.text }
                    if update.isFinal { break }
                }
                return latest
            }
            guard Self.isAcceptable(transcript) else {
                return .failed(message: mismatchMessage(transcript))
            }
            return .passed(transcript: transcript, seconds: Date().timeIntervalSince(start))
        } catch let error as DoubaoStreamASRClient.StreamError {
            if case .server(let code, let message) = error {
                return .failed(message: DoubaoErrorGuide.hint(status: String(code), message: message, endpoint: .stream))
            }
            return .failed(message: error.localizedDescription)
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    // MARK: Deadline helper

    /// Task-group race — no continuations, so no double-resume hazard.
    nonisolated private static func withDeadline<T: Sendable>(
        seconds: Double,
        _ op: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw DoubaoTestError.timeout
            }
            guard let first = try await group.next() else { throw DoubaoTestError.timeout }
            group.cancelAll()
            return first
        }
    }
}
