import Foundation

// MARK: - Memo Model

/// A single user-generated entry stored in vault/raw/YYYY-MM-DD.md.
/// Serialized as YAML frontmatter + Markdown body, separated by \n\n---\n\n.
struct Memo: Identifiable, Equatable {

    // MARK: Attachment types

    struct Location: Equatable {
        var name: String?
        var lat: Double?
        var lng: Double?
    }

    enum MemoType: String, Equatable {
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

    /// Converts the Memo into its Markdown on-disk representation:
    ///   YAML frontmatter (between --- delimiters) followed by a blank line and the body.
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

    /// Parses a single Memo block (frontmatter + body).
    /// Returns nil if the block cannot be parsed.
    static func fromMarkdown(_ block: String) -> Memo? {
        // Split frontmatter from body: expect "---\n...\n---\n\nbody"
        let text = block.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("---") else { return nil }

        // Find opening and closing --- delimiters
        let lines = text.components(separatedBy: "\n")
        guard lines.count >= 2 else { return nil }

        // lines[0] should be "---", find the next "---"
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
        // Skip leading blank line between frontmatter and body
        let bodyStart = bodyLines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? 0
        let body = bodyLines[bodyStart...].joined(separator: "\n").trimmingCharacters(in: .newlines)

        // Parse frontmatter as simple YAML
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

    /// Wraps a string in double quotes, escaping internal quotes and backslashes.
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

/// A lightweight line-by-line YAML parser sufficient for Memo frontmatter.
/// Supports: scalar keys, nested mapping (2-space indent), flat sequence of mappings.
struct YAMLParser {
    private let lines: [String]

    init(lines: [String]) {
        self.lines = lines
    }

    // MARK: Scalar

    /// Returns the unquoted value for a top-level key, or nil.
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

    /// Returns a [String: String] for a top-level mapping key, or nil.
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
                // Two-space indented sub-key
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

    /// Returns an array of [String: String] for a top-level sequence key, or nil.
    /// Each sequence item starts with "  - key: value".
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

    /// Strips surrounding double-quotes and unescapes \" and \\.
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
