import Foundation
import Testing
import zlib
@testable import DayPageServices

func diagnosticEnvelope(_ payload: [String: Any], type: String = "event") throws -> Data {
    let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    let header = try JSONSerialization.data(withJSONObject: ["type": type, "length": body.count])
    var envelope = Data("{}\n".utf8)
    envelope.append(header); envelope.append(10); envelope.append(body); envelope.append(10)
    return envelope
}

func diagnosticGzip(_ input: Data) throws -> Data {
    var stream = z_stream()
    guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY,
                        ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw URLError(.cannotDecodeContentData) }
    defer { deflateEnd(&stream) }
    return try input.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
        stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
        stream.avail_in = uInt(input.count)
        var output = Data(count: Int(compressBound(uLong(input.count))) + 64)
        let capacity = output.count
        let result = output.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) -> Int32 in
            stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
            stream.avail_out = uInt(capacity)
            return deflate(&stream, Z_FINISH)
        }
        guard result == Z_STREAM_END else { throw URLError(.cannotDecodeContentData) }
        output.count = Int(stream.total_out)
        return output
    }
}

@Suite("Diagnostics envelope privacy")
struct DiagnosticsEnvelopeSanitizerTests {
    @Test("Cached event arbitrary text, notes, transcript, IDs and request context never leave")
    func maliciousCachedEnvelope() throws {
        let samples = ["这是私人笔记", "meeting transcript alice salary 9000", "strangesecretUNMATCHEDvalue", "account-personal-782", "https://private.invalid/?token=query-private", "Bearer HEADER_PRIVATE"]
        let text = samples.joined(separator: " | ")
        let payload: [String: Any] = [
            "message": ["formatted": text, "message": text, "params": samples],
            "user": ["id": samples[3], "email": text], "request": ["url": samples[4], "headers": ["Authorization": samples[5]]],
            "contexts": ["note": text], "extra": ["anything": text], "modules": [text: text], "fingerprint": samples,
            "breadcrumbs": [["message": text, "data": [text: text]]], "logger": text, "release": text, "environment": text,
            "tags": [text: text, "operational.area": "sync", "operational.code": "server_error", "correlation_id": samples[3]],
            "exception": ["values": [["value": text, "type": text, "mechanism": ["data": [text: text], "handled": false],
                                        "stacktrace": ["frames": [["function": text, "filename": text, "instruction_addr": "0x1234", "in_app": true]]]]]],
            "threads": ["values": [["name": text, "id": 7, "crashed": true, "stacktrace": ["frames": [["function": "abort", "instruction_addr": "0x4321"]]]]]],
            "debug_meta": ["images": [["code_file": text, "image_addr": "0x1000", "image_size": 4096, "debug_id": "3C90D978-40B4-4A5B-8A08-C4CD4E57A8E1"]]],
            "sdk": ["name": text, "version": text], "level": "fatal"
        ]
        let envelope = try diagnosticEnvelope(payload)
        for original in [envelope, try diagnosticGzip(envelope)] {
            let result = try #require(DiagnosticsEnvelopeSanitizer.sanitize(original, contentEncoding: original == envelope ? nil : "gzip"))
            let serialized = try #require(String(data: result, encoding: .utf8))
            for sample in samples { #expect(!serialized.contains(sample)) }
            #expect(serialized.contains("0x1234"))
            #expect(serialized.contains("0x4321"))
            #expect(serialized.contains("abort"))
            #expect(serialized.contains("server_error"))
            #expect(serialized.contains("8.58.4"))
            #expect(!serialized.contains("correlation_id"))
            #expect(!serialized.contains("breadcrumbs"))
        }
    }

    @Test("Real safe item shapes and lengths survive canonical framing")
    func safeItemShapes() throws {
        for (type, payload) in [
            ("event", ["level": "error", "timestamp": "2026-10-02T06:40:00.123Z"] as [String: Any]),
            ("session", ["status": "crashed", "errors": 1, "init": true, "started": "2026-10-02T06:40:00Z", "attrs": ["release": "secret", "ip_address": "127.0.0.1"]]),
            ("client_report", ["timestamp": "2026-10-02T06:40:00Z", "discarded_events": [["reason": "network_error", "category": "error", "quantity": 2]]])
        ] {
            let safe = try #require(DiagnosticsEnvelopeSanitizer.sanitize(try diagnosticEnvelope(payload, type: type)))
            #expect(!String(decoding: safe, as: UTF8.self).contains("secret"))
            // Sanitized output is itself well framed and admissible.
            #expect(DiagnosticsEnvelopeSanitizer.sanitize(safe) != nil)
        }
    }

    @Test("Unknown items, broken framing, gzip tails and size bombs fail closed")
    func boundedMalformedInput() throws {
        for type in ["attachment", "transaction", "profile", "replay_recording", "log", "unknown"] {
            #expect(DiagnosticsEnvelopeSanitizer.sanitize(try diagnosticEnvelope(["text": "private"], type: type)) == nil)
        }
        for input in [Data(), Data("{}\n{\"type\":\"event\",\"length\":999}\n{}".utf8), Data("{}\n{\"type\":\"event\",\"length\":true}\n{}".utf8), Data("not-json\n{}\n{}".utf8), Data("{}\n{\"type\":\"event\",\"length\":2}\n{}garbage".utf8)] {
            #expect(DiagnosticsEnvelopeSanitizer.sanitize(input) == nil)
        }
        let large = try diagnosticEnvelope(["message": String(repeating: "x", count: DiagnosticsEnvelopeSanitizer.maximumBytes)])
        #expect(DiagnosticsEnvelopeSanitizer.sanitize(large) == nil)
        #expect(DiagnosticsEnvelopeSanitizer.sanitize(try diagnosticGzip(large), contentEncoding: "gzip") == nil)
        var trailing = try diagnosticGzip(try diagnosticEnvelope(["level": "error"]))
        trailing.append(0)
        #expect(DiagnosticsEnvelopeSanitizer.sanitize(trailing, contentEncoding: "gzip") == nil)
        #expect(DiagnosticsEnvelopeSanitizer.sanitize(Data("bad gzip".utf8), contentEncoding: "gzip") == nil)
        #expect(DiagnosticsEnvelopeSanitizer.sanitize(try diagnosticEnvelope([:]), contentEncoding: "br") == nil)
    }
}
