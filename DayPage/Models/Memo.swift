import Foundation

// MARK: - Memo Model

/// 存储在 vault/raw/YYYY-MM-DD.md 中的单条用户生成条目。
/// 序列化为 YAML 前置元数据 + Markdown 正文，以 \n\n---\n\n 分隔。
struct Memo: Identifiable, Equatable {

    // MARK: Attachment types

    struct Location: Equatable {
        var name: String?
        var lat: Double?
        var lng: Double?
    }

    enum MemoType: String, Equatable, Hashable {
        case text
        case voice
        case photo
        case location
        case mixed
    }

    struct Attachment: Equatable {
        var file: String
        var kind: String         // "photo" | "audio"
        var duration: Double?    // seconds, audio only
        var transcript: String?  // audio only
    }

    // MARK: Fields

    var id: UUID
    var type: MemoType
    var created: Date
    var location: Location?
    var weather: String?
    var device: String?
    var attachments: [Attachment]
    var body: String

    // MARK: Init

    init(
        id: UUID = UUID(),
        type: MemoType = .text,
        created: Date = Date(),
        location: Location? = nil,
        weather: String? = nil,
        device: String? = nil,
        attachments: [Attachment] = [],
        body: String = ""
    ) {
        self.id = id
        self.type = type
        self.created = created
        self.location = location
        self.weather = weather
        self.device = device
        self.attachments = attachments
        self.body = body
    }
}

// MARK: - Markdown Serialization

extension Memo {

    // MARK: Serialize → String

    /// 将 Memo 转换为其磁盘上的 Markdown 表示：
    ///   YAML 前置元数据（位于 --- 分隔符之间），后跟一个空行和正文。
    func toMarkdown() -> String {
        var lines: [String] = ["---"]

        lines.append("id: \(id.uuidString)")
        lines.append("type: \(type.rawValue)")
        lines.append("created: \(ISO8601DateFormatter.memo.string(from: created))")

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
    static func fromMarkdown(_ block: String) -> Memo? {
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
        let bodyLines = Array(lines[(closing + 1)...])
        // 跳过前置元数据和正文之间的前导空行
        let bodyStart = bodyLines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? 0
        let body = bodyLines[bodyStart...].joined(separator: "\n").trimmingCharacters(in: .newlines)

        // 将前置元数据解析为简单 YAML
        var fm = YAMLParser(lines: frontmatterLines)
        guard let idString = fm.scalar("id"),
              let uuid = UUID(uuidString: idString) else { return nil }

        let typeRaw = fm.scalar("type") ?? "text"
        let memoType = MemoType(rawValue: typeRaw) ?? .text

        let createdString = fm.scalar("created") ?? ""
        let created = ISO8601DateFormatter.memo.date(from: createdString) ?? Date()

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

        var attachments: [Attachment] = []
        if let attList = fm.sequenceOfMappings("attachments") {
            for attMap in attList {
                guard let file = attMap["file"] else { continue }
                let kind = attMap["kind"] ?? "photo"
                let duration = attMap["duration"].flatMap { Double($0) }
                let transcript = attMap["transcript"]
                attachments.append(Attachment(file: file, kind: kind, duration: duration, transcript: transcript))
            }
        }

        return Memo(
            id: uuid,
            type: memoType,
            created: created,
            location: location,
            weather: weather,
            device: device,
            attachments: attachments,
            body: body
        )
    }

    // MARK: Private helpers

    /// 将字符串用双引号包裹，转义内部引号和反斜杠。
    private func yamlQuote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

// MARK: - ISO8601DateFormatter extension

extension ISO8601DateFormatter {
    static let memo: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

// MARK: - Minimal YAML parser

/// 一个轻量级逐行 YAML 解析器，足以处理 Memo 前置元数据。
/// 支持：标量键、嵌套映射（2 空格缩进）、扁平的映射序列。
struct YAMLParser {
    private let lines: [String]

    init(lines: [String]) {
        self.lines = lines
    }

    // MARK: Scalar

    /// 返回顶级键的非引号值，如果不存在则返回 nil。
    mutating func scalar(_ key: String) -> String? {
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
    mutating func mapping(_ key: String) -> [String: String]? {
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
    mutating func sequenceOfMappings(_ key: String) -> [[String: String]]? {
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

    // MARK: Private helpers

    private func extractValue(from line: String, key: String) -> String? {
        let prefix = "\(key): "
        if line.hasPrefix(prefix) {
            let raw = String(line.dropFirst(prefix.count))
            return yamlUnquote(raw)
        }
        return nil
    }

    /// 去除外围双引号并反转义 \" 和 \\。
    private func yamlUnquote(_ s: String) -> String {
        var v = s
        if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 {
            v = String(v.dropFirst().dropLast())
            v = v
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return v
    }
}
