import Foundation

// MARK: - Memo Model

/// 存储在 vault/raw/YYYY-MM-DD.md 中的单条用户生成条目。
/// 序列化为 YAML 前置元数据 + Markdown 正文，以 \n\n---\n\n 分隔。
public struct Memo: Identifiable, Equatable {

    // MARK: Attachment types

    public struct Location: Equatable {
        public var name: String?
        public var lat: Double?
        public var lng: Double?

        public init(name: String? = nil, lat: Double? = nil, lng: Double? = nil) {
            self.name = name
            self.lat = lat
            self.lng = lng
        }
    }

    public enum MemoType: String, Equatable, Hashable {
        case text
        case voice
        case photo
        case location
        case mixed
    }

    // US-016: transcription lifecycle for audio attachments
    public enum TranscriptionStatus: String, Equatable {
        case pending    // in-progress or queued
        case done       // transcript available
        case failed     // all retries exhausted or no network
    }

    public struct Attachment: Equatable {
        public var file: String
        public var kind: String                          // "photo" | "audio"
        public var duration: Double?                     // seconds, audio only
        public var transcript: String?                   // audio only
        public var transcriptionStatus: TranscriptionStatus? // audio only; nil = not applicable

        public init(
            file: String,
            kind: String,
            duration: Double? = nil,
            transcript: String? = nil,
            transcriptionStatus: TranscriptionStatus? = nil
        ) {
            self.file = file
            self.kind = kind
            self.duration = duration
            self.transcript = transcript
            self.transcriptionStatus = transcriptionStatus
        }
    }

    // MARK: Fields

    public var id: UUID
    public var type: MemoType
    public var created: Date
    public var pinnedAt: Date? = nil
    public var location: Location?
    public var weather: String?
    public var device: String?
    public var attachments: [Attachment]
    public var mood: String?
    public var entityMentions: [String]
    public var body: String

    // MARK: Init

    public init(
        id: UUID = UUID(),
        type: MemoType = .text,
        created: Date = Date(),
        pinnedAt: Date? = nil,
        location: Location? = nil,
        weather: String? = nil,
        device: String? = nil,
        attachments: [Attachment] = [],
        mood: String? = nil,
        entityMentions: [String] = [],
        body: String = ""
    ) {
        self.id = id
        self.type = type
        self.created = created
        self.pinnedAt = pinnedAt
        self.location = location
        self.weather = weather
        self.device = device
        self.attachments = attachments
        self.mood = mood
        self.entityMentions = entityMentions
        self.body = body
    }
}

// MARK: - Markdown Serialization

extension Memo {

    // MARK: Serialize → String

    /// 将 Memo 转换为其磁盘上的 Markdown 表示：
    ///   YAML 前置元数据（位于 --- 分隔符之间），后跟一个空行和正文。
    public func toMarkdown() -> String {
        var lines: [String] = ["---"]

        lines.append("id: \(id.uuidString)")
        lines.append("type: \(type.rawValue)")
        lines.append("created: \(ISO8601DateFormatter.memo.string(from: created))")

        if let p = pinnedAt {
            lines.append("pinned_at: \(ISO8601DateFormatter.memo.string(from: p))")
        }

        if let loc = location {
            lines.append("location:")
            if let name = loc.name {
                lines.append("  name: \(yamlQuote(name))")
            }
            if let lat = loc.lat {
                lines.append("  lat: \(lat)")
            }
            if let lng = loc.lng {
                lines.append("  lng: \(lng)")
            }
        }

        if let w = weather {
            lines.append("weather: \(yamlQuote(w))")
        }

        if let d = device {
            lines.append("device: \(yamlQuote(d))")
        }

        if let m = mood {
            lines.append("mood: \(yamlQuote(m))")
        }

        if entityMentions.isEmpty {
            lines.append("entity_mentions: []")
        } else {
            lines.append("entity_mentions:")
            for entity in entityMentions {
                lines.append("  - \(yamlQuote(entity))")
            }
        }

        if attachments.isEmpty {
            lines.append("attachments: []")
        } else {
            lines.append("attachments:")
            for att in attachments {
                lines.append("  - file: \(yamlQuote(att.file))")
                lines.append("    kind: \(att.kind)")
                if let dur = att.duration {
                    lines.append("    duration: \(dur)")
                }
                if let tr = att.transcript {
                    lines.append("    transcript: \(yamlQuote(tr))")
                }
                if let ts = att.transcriptionStatus {
                    lines.append("    transcription_status: \(ts.rawValue)")
                }
            }
        }

        lines.append("---")
        lines.append("")
        lines.append(body)

        return lines.joined(separator: "\n")
    }

    // MARK: Deserialize ← String

    /// 解析单个 Memo 块（前置元数据 + 正文）。
    /// 如果无法解析，则返回 nil。
    public static func fromMarkdown(_ block: String) -> Memo? {
        // 从前置元数据中分离正文：期望格式为 "---\n...\n---\n\nbody"
        let text = block.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("---") else { return nil }

        // 查找开始和结束的 --- 分隔符
        let lines = text.components(separatedBy: "\n")
        guard lines.count >= 2 else { return nil }

        // lines[0] 应为 "---"，查找下一个 "---"
        var closingIndex: Int?
        for i in 1 ..< lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                closingIndex = i
                break
            }
        }
        guard let closing = closingIndex else { return nil }

        let frontmatterLines = Array(lines[1 ..< closing])
        let rawBodyLines = Array(lines[(closing + 1)...])
        // Skip only the single blank separator line between front-matter and body.
        // Using firstIndex preserves a body whose first content line is "---" or
        // any other value — we never skip non-blank lines here.
        let bodyStart = rawBodyLines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? rawBodyLines.endIndex
        let body: String
        if bodyStart < rawBodyLines.endIndex {
            // Re-join without trailing newline trimming so "---" lines at the
            // start or end of the body survive the round-trip intact.
            body = rawBodyLines[bodyStart...].joined(separator: "\n")
        } else {
            body = ""
        }

        // 将前置元数据解析为简单 YAML
        var fm = YAMLParser(lines: frontmatterLines)
        guard let idString = fm.scalar("id"),
              let uuid = UUID(uuidString: idString) else { return nil }

        let typeRaw = fm.scalar("type") ?? "text"
        let memoType = MemoType(rawValue: typeRaw) ?? .text

        let createdString = fm.scalar("created") ?? ""
        let created = ISO8601DateFormatter.memo.date(from: createdString) ?? Date()

        let pinnedAt: Date? = {
            guard let s = fm.scalar("pinned_at") else { return nil }
            return ISO8601DateFormatter.memo.date(from: s)
        }()

        var location: Location?
        if let locationMap = fm.mapping("location") {
            var loc = Location()
            loc.name = locationMap["name"]
            if let latStr = locationMap["lat"] { loc.lat = Double(latStr) }
            if let lngStr = locationMap["lng"] { loc.lng = Double(lngStr) }
            location = loc
        }

        let weather = fm.scalar("weather")
        let device = fm.scalar("device")
        let mood = fm.scalar("mood")
        // YAMLParser.sequence(_:) returns Optional<[String]>; the Memo init
        // takes a non-optional [String], so default to an empty array when the
        // key is missing or explicitly `entity_mentions: []`.
        let entityMentions = fm.sequence("entity_mentions") ?? []

        var attachments: [Attachment] = []
        if let attList = fm.sequenceOfMappings("attachments") {
            for attMap in attList {
                guard let file = attMap["file"] else { continue }
                let kind = attMap["kind"] ?? "photo"
                let duration = attMap["duration"].flatMap { Double($0) }
                let transcript = attMap["transcript"]
                let transcriptionStatus = attMap["transcription_status"]
                    .flatMap { TranscriptionStatus(rawValue: $0) }
                attachments.append(Attachment(
                    file: file,
                    kind: kind,
                    duration: duration,
                    transcript: transcript,
                    transcriptionStatus: transcriptionStatus
                ))
            }
        }

        return Memo(
            id: uuid,
            type: memoType,
            created: created,
            pinnedAt: pinnedAt,
            location: location,
            weather: weather,
            device: device,
            attachments: attachments,
            mood: mood,
            entityMentions: entityMentions,
            body: body
        )
    }

    // MARK: Private helpers

    /// 将字符串用双引号包裹，转义内部引号、反斜杠及换行符，确保标量值始终占一行。
    /// 字符级扫描避免链式 `replacingOccurrences` 的级联与顺序陷阱（例如
    /// 用户输入字面 `\n` 时被先转义成 `\\n` 后再被换行规则误碰）。
    public static func yamlQuote(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 2)
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
        }
        return "\"" + out + "\""
    }

    /// Instance shim so existing call sites in `toMarkdown()` keep working
    /// without `Memo.yamlQuote(...)`. New code should prefer the static form.
    private func yamlQuote(_ s: String) -> String { Memo.yamlQuote(s) }

    /// Inverse of `yamlQuote`: takes a fully-quoted YAML scalar like `"foo\\nbar"`
    /// and returns the original string. Exposed for round-trip testing.
    public static func yamlUnquote(_ s: String) -> String {
        YAMLParser.unquote(s)
    }
}

// MARK: - CJK-aware word count

public enum TextCount {
    public static func words(_ text: String) -> Int {
        var cjkCount = 0
        var latinWords = 0
        var inLatinRun = false
        for scalar in text.unicodeScalars {
            if (0x4E00...0x9FFF).contains(scalar.value) ||
               (0x3400...0x4DBF).contains(scalar.value) ||
               (0x3040...0x30FF).contains(scalar.value) {
                cjkCount += 1
                inLatinRun = false
            } else if scalar.properties.isWhitespace {
                inLatinRun = false
            } else {
                if !inLatinRun { latinWords += 1 }
                inLatinRun = true
            }
        }
        return cjkCount + latinWords
    }
}

// MARK: - ISO8601DateFormatter extension

extension ISO8601DateFormatter {
    public static let memo: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Parses a plain date string (yyyy-MM-dd) by treating it as midnight UTC.
    public static let dayOnly: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withDashSeparatorInDate]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()
}

// MARK: - Minimal YAML parser

/// 一个轻量级逐行 YAML 解析器，足以处理 Memo 前置元数据。
/// 支持：标量键、嵌套映射（2 空格缩进）、扁平的映射序列。
public struct YAMLParser {
    private let lines: [String]

    public init(lines: [String]) {
        self.lines = lines
    }

    // MARK: Scalar

    /// 返回顶级键的非引号值，如果不存在则返回 nil。
    public func scalar(_ key: String) -> String? {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix(" "), !trimmed.hasPrefix("-") else { continue }
            if let value = extractValue(from: trimmed, key: key) {
                return value
            }
        }
        return nil
    }

    // MARK: Nested mapping (2-space indented block)

    /// 返回顶级映射键的 [String: String] 字典，如果不存在则返回 nil。
    public func mapping(_ key: String) -> [String: String]? {
        var inBlock = false
        var result: [String: String] = [:]

        for line in lines {
            if !inBlock {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "\(key):" {
                    inBlock = true
                }
            } else {
                // 两个空格缩进的子键
                if line.hasPrefix("  ") && !line.hasPrefix("   ") {
                    let sub = line.trimmingCharacters(in: .whitespaces)
                    let parts = sub.split(separator: ":", maxSplits: 1)
                    if parts.count == 2 {
                        let subKey = String(parts[0])
                        let subVal = String(parts[1]).trimmingCharacters(in: .whitespaces)
                        result[subKey] = yamlUnquote(subVal)
                    }
                } else {
                    break
                }
            }
        }
        return inBlock && !result.isEmpty ? result : nil
    }

    // MARK: Sequence of mappings

    /// 返回顶级序列键的 [[String: String]] 数组，如果不存在则返回 nil。
    /// 每个序列项以 "  - key: value" 开头。
    public func sequenceOfMappings(_ key: String) -> [[String: String]]? {
        var inBlock = false
        var items: [[String: String]] = []
        var current: [String: String] = [:]

        for line in lines {
            if !inBlock {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "\(key):" || trimmed == "\(key): []" {
                    if !trimmed.hasSuffix("[]") { inBlock = true }
                    continue
                }
            } else {
                if line.hasPrefix("  - ") {
                    if !current.isEmpty { items.append(current); current = [:] }
                    let sub = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                    let parts = sub.split(separator: ":", maxSplits: 1)
                    if parts.count == 2 {
                        current[String(parts[0])] = yamlUnquote(String(parts[1]).trimmingCharacters(in: .whitespaces))
                    }
                } else if line.hasPrefix("    ") {
                    let sub = line.trimmingCharacters(in: .whitespaces)
                    let parts = sub.split(separator: ":", maxSplits: 1)
                    if parts.count == 2 {
                        current[String(parts[0])] = yamlUnquote(String(parts[1]).trimmingCharacters(in: .whitespaces))
                    }
                } else {
                    break
                }
            }
        }
        if !current.isEmpty { items.append(current) }
        return inBlock ? items : nil
    }

    // MARK: Sequence of scalars

    /// 返回顶级序列键的 [String]（标量值）数组，如果不存在则返回 nil。
    /// 解析如下格式：
    ///   key:
    ///     - value1
    ///     - value2
    public func sequence(_ key: String) -> [String]? {
        var inBlock = false
        var items: [String] = []

        for line in lines {
            if !inBlock {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "\(key):" || trimmed == "\(key): []" {
                    if trimmed.hasSuffix("[]") { return [] }
                    inBlock = true
                    continue
                }
            } else {
                if line.hasPrefix("  - ") {
                    let value = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                    items.append(yamlUnquote(value))
                } else {
                    break
                }
            }
        }
        return inBlock ? items : nil
    }

    // MARK: Private helpers

    private func extractValue(from line: String, key: String) -> String? {
        let prefix = "\(key): "
        if line.hasPrefix(prefix) {
            let raw = String(line.dropFirst(prefix.count))
            return yamlUnquote(raw)
        }
        return nil
    }

    /// 去除外围双引号并反转义所有转义序列（\ \" \n \r \t）。
    /// 使用逐字符扫描确保 \n 被解码为字面反斜杠+n，而非换行符。
    private func yamlUnquote(_ s: String) -> String { YAMLParser.unquote(s) }

    /// Static, test-visible variant of `yamlUnquote`. Pure function — safe to
    /// call without instantiating a parser.
    public static func unquote(_ s: String) -> String {
        guard s.hasPrefix("\"") && s.hasSuffix("\"") && s.count >= 2 else { return s }
        let inner = s.dropFirst().dropLast()
        var result = ""
        result.reserveCapacity(inner.count)
        var idx = inner.startIndex
        while idx < inner.endIndex {
            let ch = inner[idx]
            if ch == "\\" {
                let next = inner.index(after: idx)
                if next < inner.endIndex {
                    switch inner[next] {
                    case "n":  result.append("\n")
                    case "r":  result.append("\r")
                    case "t":  result.append("\t")
                    case "\"": result.append("\"")
                    case "\\": result.append("\\")
                    default:   result.append(ch); result.append(inner[next])
                    }
                    idx = inner.index(after: next)
                } else {
                    result.append(ch)
                    idx = next
                }
            } else {
                result.append(ch)
                idx = inner.index(after: idx)
            }
        }
        return result
    }
}
