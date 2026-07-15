import Foundation
import DayPageStorage

// MARK: - DoubaoStreamASRClient

/// Real-time streaming transcription via 豆包 双向流式语音识别 (WebSocket).
///
/// Wire format (big-endian throughout), per the official `sauc_python` demo:
///
///     client → [4B header][4B sequence (int32)][4B payload size (uint32)][gzipped payload]
///     server → [4B header][4B sequence?][4B event?][4B payload size][gzipped payload]
///
/// Two places where the demo contradicts the prose docs — the demo wins here,
/// since it is what the service is actually tested against:
///   1. Audio frames keep the JSON serialization nibble (byte 2 = 0x11), even
///      though their payload is raw audio and the doc says 0x01.
///   2. Every client frame carries a sequence number; the doc's example claims
///      the first audio frame omits it.
///
/// Results are cumulative (`result_type` defaults to "full"): each response
/// carries the complete transcript so far, so consumers replace rather than
/// append.
actor DoubaoStreamASRClient {

    // MARK: Protocol constants

    private enum MessageType: UInt8 {
        case fullClientRequest  = 0b0001
        case audioOnlyRequest   = 0b0010
        case fullServerResponse = 0b1001
        case serverErrorResponse = 0b1111
    }

    private enum Flags: UInt8 {
        case positiveSequence = 0b0001
        case negativeWithSequence = 0b0011
    }

    /// Audio contract: the service only supports 16kHz / 16-bit / mono.
    static let sampleRate = 16_000
    static let bitsPerSample = 16
    static let channels = 1

    /// Docs recommend 100–200ms per packet; the demo uses 200ms.
    /// 16000 × 2 bytes × 0.2s = 6400 bytes.
    static let chunkBytes = 6_400

    enum StreamError: Error, LocalizedError {
        case missingCredentials
        case invalidEndpoint
        case server(code: Int32, message: String)
        case connectionClosed
        case malformedFrame

        var errorDescription: String? {
            switch self {
            case .missingCredentials: return "豆包语音未配置 App ID / Access Token"
            case .invalidEndpoint:    return "豆包流式端点配置无效"
            case .server(let code, let message): return "豆包流式识别失败（\(code)）：\(message)"
            case .connectionClosed:   return "豆包流式连接已断开"
            case .malformedFrame:     return "豆包返回了无法解析的数据帧"
            }
        }
    }

    /// A transcript update from the server.
    struct Update {
        /// Complete transcript so far (cumulative — replaces prior text).
        let text: String
        /// True once the server marks this the final packet.
        let isFinal: Bool
    }

    // MARK: State

    private var task: URLSessionWebSocketTask?
    private var sequence: Int32 = 1
    private var didFinish = false

    // MARK: - Lifecycle

    /// Opens the WebSocket and sends the initial configuration frame.
    func start() throws {
        guard DoubaoASRConfig.hasCredentials else { throw StreamError.missingCredentials }
        guard let url = URL(string: DoubaoASRConfig.streamURL) else { throw StreamError.invalidEndpoint }

        var request = URLRequest(url: url)
        // Exactly the four headers the official demo sends. X-Api-Sequence is
        // deliberately absent: it belongs to the HTTP APIs, and the sequence
        // travels inside the binary frames here.
        request.setValue(DoubaoASRConfig.streamResourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue(DoubaoASRConfig.accessToken, forHTTPHeaderField: "X-Api-Access-Key")
        request.setValue(DoubaoASRConfig.appID, forHTTPHeaderField: "X-Api-App-Key")

        let session = URLSession(configuration: .default)
        let socket = session.webSocketTask(with: request)
        socket.resume()
        task = socket
        sequence = 1
        didFinish = false

        try sendConfigFrame()
    }

    /// Sends one chunk of raw 16kHz mono PCM.
    func send(audio chunk: Data, isLast: Bool = false) throws {
        guard let task else { throw StreamError.connectionClosed }

        let flags: Flags = isLast ? .negativeWithSequence : .positiveSequence
        let seq: Int32 = isLast ? -sequence : sequence

        var frame = Data([
            0x11,                                                   // version 1 | header size 4B
            (MessageType.audioOnlyRequest.rawValue << 4) | flags.rawValue,
            0x11,                                                   // JSON | GZIP — matches the demo
            0x00,
        ])
        frame.append(bigEndian: seq)
        let payload = try GzipCodec.compress(chunk)
        frame.append(bigEndian: UInt32(payload.count))
        frame.append(payload)

        task.send(.data(frame)) { _ in }
        if !isLast { sequence += 1 }
    }

    /// Awaits the next transcript update. Returns `nil` once the stream ends.
    func receive() async throws -> Update? {
        guard let task, !didFinish else { return nil }

        let message = try await task.receive()
        guard case let .data(frame) = message else { throw StreamError.malformedFrame }
        return try parse(frame)
    }

    func close() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        didFinish = true
    }

    // MARK: - Frames

    private func sendConfigFrame() throws {
        guard let task else { throw StreamError.connectionClosed }

        let payload: [String: Any] = [
            "user": ["uid": "daypage"],
            "audio": [
                // Raw PCM, no container. The demo streams a WAV (header and
                // all) and declares "wav"; we feed AVAudioEngine buffers
                // directly, which have no RIFF header — hence "pcm"/"raw".
                "format": "pcm",
                "codec": "raw",
                "rate": Self.sampleRate,
                "bits": Self.bitsPerSample,
                "channel": Self.channels,
            ],
            "request": [
                "model_name": DoubaoASRConfig.fileModelName,
                "enable_itn": true,
                "enable_punc": true,
                "enable_ddc": true,
                "show_utterances": true,
                "enable_nonstream": false,
            ],
        ]

        var frame = Data([
            0x11,
            (MessageType.fullClientRequest.rawValue << 4) | Flags.positiveSequence.rawValue,
            0x11,
            0x00,
        ])
        frame.append(bigEndian: sequence)
        let body = try GzipCodec.compress(try JSONSerialization.data(withJSONObject: payload))
        frame.append(bigEndian: UInt32(body.count))
        frame.append(body)

        task.send(.data(frame)) { _ in }
        sequence += 1
    }

    private func parse(_ frame: Data) throws -> Update? {
        guard frame.count >= 4 else { throw StreamError.malformedFrame }

        // Header size is declared in the frame — never hardcode 4.
        let headerSize = Int(frame[0] & 0x0F) * 4
        let messageType = frame[1] >> 4
        let flags = frame[1] & 0x0F
        let compression = frame[2] & 0x0F

        guard frame.count > headerSize else { throw StreamError.malformedFrame }
        var cursor = headerSize

        func readInt32() throws -> Int32 {
            guard frame.count >= cursor + 4 else { throw StreamError.malformedFrame }
            let value = frame.subdata(in: cursor..<cursor + 4).withUnsafeBytes {
                $0.load(as: Int32.self).bigEndian
            }
            cursor += 4
            return value
        }

        // Error frames carry the code before the payload.
        if messageType == MessageType.serverErrorResponse.rawValue {
            let code = try readInt32()
            let size = Int(try readInt32())
            let raw = frame.subdata(in: cursor..<min(cursor + size, frame.count))
            let body = (compression == 1) ? ((try? GzipCodec.decompress(raw)) ?? raw) : raw
            throw StreamError.server(code: code, message: String(decoding: body, as: UTF8.self))
        }

        // Optional fields, in wire order. These are bit tests, not equality
        // checks — a frame can carry several at once, and misreading one
        // misaligns every subsequent field.
        if flags & 0x01 != 0 { _ = try readInt32() }        // sequence
        let isLast = (flags & 0x02) != 0                    // last package
        if flags & 0x04 != 0 { _ = try readInt32() }        // event (undocumented)

        let size = Int(try readInt32())
        guard size > 0, frame.count >= cursor else {
            return isLast ? Update(text: "", isFinal: true) : nil
        }
        let raw = frame.subdata(in: cursor..<min(cursor + size, frame.count))
        let body = (compression == 1) ? try GzipCodec.decompress(raw) : raw

        if isLast { didFinish = true }

        guard
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let result = json["result"] as? [String: Any],
            let text = result["text"] as? String
        else {
            return isLast ? Update(text: "", isFinal: true) : nil
        }
        return Update(text: text.trimmingCharacters(in: .whitespacesAndNewlines), isFinal: isLast)
    }
}

// MARK: - Big-endian append helpers

private extension Data {
    mutating func append<T: FixedWidthInteger>(bigEndian value: T) {
        // Qualified: inside a Data extension, the bare name resolves to
        // Data.withUnsafeBytes rather than the Swift global.
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
