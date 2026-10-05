import Foundation
import zlib

/// Final, allowlist-only boundary for both freshly generated and cached Sentry
/// envelopes. Unknown items, malformed framing, and oversized payloads fail
/// closed. No original payload or parser error is logged.
public enum DiagnosticsEnvelopeSanitizer {
    public static let maximumBytes = 1_048_576
    private static let maximumItems = 16

    public static func sanitize(_ body: Data, contentEncoding: String? = nil) -> Data? {
        guard !body.isEmpty, body.count <= maximumBytes else { return nil }
        let data: Data
        switch contentEncoding?.lowercased() {
        case "gzip":
            guard let expanded = gunzip(body) else { return nil }
            data = expanded
        case nil, "identity": data = body
        default: return nil
        }
        var cursor = 0
        func line() -> Data? {
            guard cursor < data.count, let end = data[cursor...].firstIndex(of: 10),
                  end - cursor <= 16_384 else { return nil }
            defer { cursor = end + 1 }
            return data.subdata(in: cursor..<end)
        }
        guard let header = line(), object(header) != nil else { return nil }
        let eventID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        guard let cleanHeader = json(["event_id": eventID]) else { return nil }
        var output = cleanHeader
        output.append(10)
        var count = 0
        while cursor < data.count {
            count += 1
            guard count <= maximumItems, let itemLine = line(),
                  let item = object(itemLine), let type = item["type"] as? String else { return nil }
            let payload: Data
            if let rawLength = item["length"] {
                guard let length = integer(rawLength, maximum: maximumBytes), length > 0,
                      length <= data.count - cursor else { return nil }
                payload = data.subdata(in: cursor..<(cursor + length))
                cursor += length
                if cursor < data.count {
                    guard data[cursor] == 10 else { return nil }
                    cursor += 1
                }
            } else {
                // Sentry also permits newline-delimited JSON without length.
                let end = data[cursor...].firstIndex(of: 10) ?? data.endIndex
                payload = data.subdata(in: cursor..<end)
                cursor = end == data.endIndex ? end : end + 1
            }
            guard let original = object(payload), let safe = sanitizeItem(original, type: type, eventID: eventID),
                  let encoded = json(safe), let encodedHeader = json(["type": type, "length": encoded.count]) else { return nil }
            output.append(encodedHeader); output.append(10)
            output.append(encoded); output.append(10)
            guard output.count <= maximumBytes else { return nil }
        }
        return count > 0 ? output : nil
    }

    private static func sanitizeItem(_ value: [String: Any], type: String, eventID: String) -> [String: Any]? {
        switch type {
        case "event":
            var safe: [String: Any] = ["event_id": eventID, "platform": "cocoa",
                                      "sdk": ["name": "sentry.cocoa", "version": "8.58.4"]]
            if let level = value["level"] as? String, ["debug", "info", "warning", "error", "fatal"].contains(level) {
                safe["level"] = level
            }
            if let timestamp = timestamp(value["timestamp"]) { safe["timestamp"] = timestamp }
            safe["message"] = ["formatted": "DayPage diagnostics"]
            if let tags = value["tags"] as? [String: Any] {
                let clean = operationalTags(tags)
                if !clean.isEmpty { safe["tags"] = clean }
            }
            if let stack = stacktrace(value["stacktrace"]) { safe["stacktrace"] = stack }
            if let values = (value["threads"] as? [String: Any])?["values"] as? [[String: Any]], values.count <= 128 {
                safe["threads"] = ["values": values.map { thread in
                    var clean: [String: Any] = [:]
                    if let id = integer(thread["id"], maximum: 1_000_000) { clean["id"] = id }
                    for key in ["crashed", "current", "main"] { if let b = boolean(thread[key]) { clean[key] = b } }
                    if let stack = stacktrace(thread["stacktrace"]) { clean["stacktrace"] = stack }
                    return clean
                }]
            }
            if let values = (value["exception"] as? [String: Any])?["values"] as? [[String: Any]], values.count <= 16 {
                safe["exception"] = ["values": values.map { exception in
                    var clean: [String: Any] = ["type": "Crash", "value": "Crash diagnostics"]
                    if let stack = stacktrace(exception["stacktrace"]) { clean["stacktrace"] = stack }
                    if let mechanism = exception["mechanism"] as? [String: Any] {
                        var m: [String: Any] = ["type": "generic"]
                        if let handled = boolean(mechanism["handled"]) { m["handled"] = handled }
                        clean["mechanism"] = m
                    }
                    return clean
                }]
            }
            if let images = (value["debug_meta"] as? [String: Any])?["images"] as? [[String: Any]], images.count <= 512 {
                safe["debug_meta"] = ["images": images.compactMap { image -> [String: Any]? in
                    guard let address = address(image["image_addr"]), let size = integer(image["image_size"], maximum: Int.max),
                          let rawID = image["debug_id"] as? String, let id = UUID(uuidString: rawID) else { return nil }
                    var clean: [String: Any] = ["type": "macho", "image_addr": address, "image_size": size, "debug_id": id.uuidString.lowercased()]
                    if let vmaddr = Self.address(image["image_vmaddr"]) { clean["image_vmaddr"] = vmaddr }
                    return clean
                }]
            }
            return safe
        case "session":
            guard let status = value["status"] as? String, ["ok", "exited", "crashed", "abnormal"].contains(status) else { return nil }
            var safe: [String: Any] = ["sid": UUID().uuidString.lowercased(), "status": status,
                                      "attrs": ["release": "DayPage@diagnostics"]]
            if let initValue = boolean(value["init"]) { safe["init"] = initValue }
            if let errors = integer(value["errors"], maximum: 100_000) { safe["errors"] = errors }
            for key in ["started", "timestamp"] { if let t = timestamp(value[key]) { safe[key] = t } }
            if let duration = number(value["duration"], maximum: 31_536_000) { safe["duration"] = duration }
            return safe
        case "client_report":
            guard let reports = value["discarded_events"] as? [[String: Any]], reports.count <= 64 else { return nil }
            let reasons: Set<String> = ["before_send", "event_processor", "sample_rate", "network_error", "queue_overflow", "cache_overflow", "ratelimit_backoff", "send_error", "insufficient_data", "backpressure"]
            let categories: Set<String> = ["error", "session", "transaction", "attachment", "profile", "default", "span", "metric_bucket"]
            let safe = reports.compactMap { report -> [String: Any]? in
                guard let reason = report["reason"] as? String, reasons.contains(reason),
                      let category = report["category"] as? String, categories.contains(category),
                      let quantity = integer(report["quantity"], maximum: 1_000_000) else { return nil }
                return ["reason": reason, "category": category, "quantity": quantity]
            }
            var result: [String: Any] = ["discarded_events": safe]
            if let t = timestamp(value["timestamp"]) { result["timestamp"] = t }
            return result
        default: return nil // Transactions, profiles, logs, attachments, replay, and binary items.
        }
    }

    private static func operationalTags(_ tags: [String: Any]) -> [String: String] {
        let fields: [String: Set<String>] = [
            "operational.area": ["auth", "sync", "config", "unknown"],
            "operational.stage": ["preflight", "authorize", "exchange", "send", "verify", "sign_out", "outbox_read", "push", "pull", "launch", "unknown"],
            "operational.code": ["missing_credential", "service_unavailable", "invalid_email", "rate_limited", "otp_expired", "otp_mismatch", "otp_locked", "network_unavailable", "network_timeout", "network_error", "not_configured", "insecure_scheme", "memo_not_found", "invalid_response", "unauthorized", "forbidden", "server_error", "conflict", "rejected", "unexpected", "unknown"],
            "operational.provider": ["apple", "email_otp", "session", "supabase", "legacy_api", "unknown"],
            "network.state": ["online", "offline", "unknown"]
        ]
        var result: [String: String] = [:]
        for (key, allowed) in fields {
            if let value = tags[key] as? String, allowed.contains(value) { result[key] = value }
        }
        // Deliberately omit correlation/user-defined IDs and numeric strings:
        // these are not needed for crash diagnosis and can be account IDs.
        return result
    }

    private static func stacktrace(_ value: Any?) -> [String: Any]? {
        guard let value = value as? [String: Any], let frames = value["frames"] as? [[String: Any]], frames.count <= 512 else { return nil }
        let symbols: Set<String> = ["main", "abort", "objc_exception_throw", "__pthread_kill", "swift_willThrow", "swift_unexpectedError", "fatalError"]
        let safe = frames.compactMap { frame -> [String: Any]? in
            var result: [String: Any] = [:]
            for key in ["instruction_addr", "image_addr", "symbol_addr"] { if let a = address(frame[key]) { result[key] = a } }
            if let function = frame["function"] as? String, symbols.contains(function) { result["function"] = function }
            if let inApp = boolean(frame["in_app"]) { result["in_app"] = inApp }
            return result.isEmpty ? nil : result
        }
        return ["frames": safe]
    }

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
    }
    private static func json(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }
    private static func number(_ value: Any?, maximum: Double) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let number = value.doubleValue
        return number.isFinite && number >= 0 && number <= maximum ? number : nil
    }
    private static func integer(_ value: Any?, maximum: Int) -> Int? {
        guard let n = number(value, maximum: Double(maximum)), n.rounded(.down) == n,
              n < Double(Int.max) else { return nil }
        return Int(n)
    }
    private static func address(_ value: Any?) -> String? {
        guard let value = value as? String, value.hasPrefix("0x"), value.count <= 18,
              let n = UInt64(value.dropFirst(2), radix: 16) else { return nil }
        return "0x" + String(n, radix: 16)
    }
    private static func timestamp(_ value: Any?) -> Any? {
        if let number = number(value, maximum: 4_102_444_800) { return number }
        guard let text = value as? String, text.count <= 32 else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = parser.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        guard let date, date.timeIntervalSince1970 >= 0, date.timeIntervalSince1970 <= 4_102_444_800 else { return nil }
        return parser.string(from: date)
    }

    /// Sentry 8.58.4 always gzips envelope requests. Bound compressed bytes,
    /// expanded bytes, and require exactly one complete stream (no tail data).
    private static func gunzip(_ data: Data) -> Data? {
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        return data.withUnsafeBytes { input -> Data? in
            guard let base = input.bindMemory(to: Bytef.self).baseAddress else { return nil }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(data.count)
            var result = Data()
            var chunk = [UInt8](repeating: 0, count: 16_384)
            while true {
                let status = chunk.withUnsafeMutableBytes { output -> Int32 in
                    stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(output.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunk.count - Int(stream.avail_out)
                guard produced <= maximumBytes - result.count else { return nil }
                result.append(contentsOf: chunk.prefix(produced))
                if status == Z_STREAM_END { return stream.avail_in == 0 ? result : nil }
                guard status == Z_OK, produced > 0 else { return nil }
            }
        }
    }
}
