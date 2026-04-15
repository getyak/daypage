// Standalone unit tests for Memo serialization and RawStorage round-trip.
// Run with:
//   xcrun swift test_raw_storage.swift
// or via the test runner script.

import Foundation

// ---------------------------------------------------------------------------
// MARK: - Inline copies of Memo + RawStorage (no Xcode target needed)
// ---------------------------------------------------------------------------

// ── Memo ────────────────────────────────────────────────────────────────────

struct Memo: Identifiable, Equatable {
    struct Location: Equatable {
        var name: String?
        var lat: Double?
        var lng: Double?
    }
    enum MemoType: String, Equatable {
        case text, voice, photo, location, mixed
    }
    struct Attachment: Equatable {
        var file: String
        var kind: String
        var duration: Double?
        var transcript: String?
    }

    var id: UUID
    var type: MemoType
    var created: Date
    var location: Location?
    var weather: String?
    var device: String?
    var attachments: [Attachment]
    var body: String

    init(id: UUID = UUID(), type: MemoType = .text, created: Date = Date(),
         location: Location? = nil, weather: String? = nil, device: String? = nil,
         attachments: [Attachment] = [], body: String = "") {
        self.id = id; self.type = type; self.created = created
        self.location = location; self.weather = weather; self.device = device
        self.attachments = attachments; self.body = body
    }

    func toMarkdown() -> String {
        var lines = ["---"]
        lines.append("id: \(id.uuidString)")
        lines.append("type: \(type.rawValue)")
        lines.append("created: \(ISO8601DateFormatter.memo.string(from: created))")
        if let loc = location {
            lines.append("location:")
            if let n = loc.name  { lines.append("  name: \(yamlQuote(n))") }
            if let la = loc.lat  { lines.append("  lat: \(la)") }
            if let ln = loc.lng  { lines.append("  lng: \(ln)") }
        }
        if let w = weather { lines.append("weather: \(yamlQuote(w))") }
        if let d = device  { lines.append("device: \(yamlQuote(d))") }
        if attachments.isEmpty {
            lines.append("attachments: []")
        } else {
            lines.append("attachments:")
            for a in attachments {
                lines.append("  - file: \(yamlQuote(a.file))")
                lines.append("    kind: \(a.kind)")
                if let dur = a.duration   { lines.append("    duration: \(dur)") }
                if let tr  = a.transcript { lines.append("    transcript: \(yamlQuote(tr))") }
            }
        }
        lines.append("---")
        lines.append("")
        lines.append(body)
        return lines.joined(separator: "\n")
    }

    static func fromMarkdown(_ block: String) -> Memo? {
        let text = block.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("---") else { return nil }
        let lines = text.components(separatedBy: "\n")
        guard lines.count >= 2 else { return nil }
        var closingIndex: Int?
        for i in 1 ..< lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" { closingIndex = i; break }
        }
        guard let closing = closingIndex else { return nil }
        let fmLines = Array(lines[1 ..< closing])
        let bodyLines = Array(lines[(closing + 1)...])
        let bodyStart = bodyLines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? 0
        let body = bodyLines[bodyStart...].joined(separator: "\n").trimmingCharacters(in: .newlines)

        var fm = YAMLParser(lines: fmLines)
        guard let idStr = fm.scalar("id"), let uuid = UUID(uuidString: idStr) else { return nil }
        let memoType = MemoType(rawValue: fm.scalar("type") ?? "text") ?? .text
        let created = ISO8601DateFormatter.memo.date(from: fm.scalar("created") ?? "") ?? Date()
        var location: Location?
        if let locMap = fm.mapping("location") {
            var l = Location()
            l.name = locMap["name"]
            if let la = locMap["lat"] { l.lat = Double(la) }
            if let ln = locMap["lng"] { l.lng = Double(ln) }
            location = l
        }
        let weather = fm.scalar("weather")
        let device  = fm.scalar("device")
        var attachments: [Attachment] = []
        if let list = fm.sequenceOfMappings("attachments") {
            for m in list {
                guard let f = m["file"] else { continue }
                attachments.append(Attachment(
                    file: f, kind: m["kind"] ?? "photo",
                    duration: m["duration"].flatMap { Double($0) },
                    transcript: m["transcript"]))
            }
        }
        return Memo(id: uuid, type: memoType, created: created, location: location,
                    weather: weather, device: device, attachments: attachments, body: body)
    }

    private func yamlQuote(_ s: String) -> String {
        let e = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(e)\""
    }
}

extension ISO8601DateFormatter {
    static let memo: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

struct YAMLParser {
    private let lines: [String]
    init(lines: [String]) { self.lines = lines }

    mutating func scalar(_ key: String) -> String? {
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix(" "), !t.hasPrefix("-") else { continue }
            let prefix = "\(key): "
            if t.hasPrefix(prefix) { return yamlUnquote(String(t.dropFirst(prefix.count))) }
        }
        return nil
    }

    mutating func mapping(_ key: String) -> [String: String]? {
        var inBlock = false; var result: [String: String] = [:]
        for line in lines {
            if !inBlock {
                if line.trimmingCharacters(in: .whitespaces) == "\(key):" { inBlock = true }
            } else {
                if line.hasPrefix("  ") && !line.hasPrefix("   ") {
                    let sub = line.trimmingCharacters(in: .whitespaces)
                    let parts = sub.split(separator: ":", maxSplits: 1)
                    if parts.count == 2 { result[String(parts[0])] = yamlUnquote(String(parts[1]).trimmingCharacters(in: .whitespaces)) }
                } else { break }
            }
        }
        return inBlock && !result.isEmpty ? result : nil
    }

    mutating func sequenceOfMappings(_ key: String) -> [[String: String]]? {
        var inBlock = false; var items: [[String: String]] = []; var current: [String: String] = [:]
        for line in lines {
            if !inBlock {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t == "\(key):" || t == "\(key): []" { if !t.hasSuffix("[]") { inBlock = true }; continue }
            } else {
                if line.hasPrefix("  - ") {
                    if !current.isEmpty { items.append(current); current = [:] }
                    let sub = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                    let parts = sub.split(separator: ":", maxSplits: 1)
                    if parts.count == 2 { current[String(parts[0])] = yamlUnquote(String(parts[1]).trimmingCharacters(in: .whitespaces)) }
                } else if line.hasPrefix("    ") {
                    let sub = line.trimmingCharacters(in: .whitespaces)
                    let parts = sub.split(separator: ":", maxSplits: 1)
                    if parts.count == 2 { current[String(parts[0])] = yamlUnquote(String(parts[1]).trimmingCharacters(in: .whitespaces)) }
                } else { break }
            }
        }
        if !current.isEmpty { items.append(current) }
        return inBlock ? items : nil
    }

    private func yamlUnquote(_ s: String) -> String {
        var v = s
        if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 {
            v = String(v.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return v
    }
}

// ── RawStorage (file ops) ───────────────────────────────────────────────────

enum RawStorage {
    static let memoSeparator = "\n\n---\n\n"

    static func fileURL(for date: Date, in dir: URL) -> URL {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = TimeZone.current
        return dir.appendingPathComponent("\(df.string(from: date)).md")
    }

    static func append(_ memo: Memo, to url: URL) throws {
        let newBlock = memo.toMarkdown()
        let existing: String
        if FileManager.default.fileExists(atPath: url.path) {
            existing = try String(contentsOf: url, encoding: .utf8)
        } else { existing = "" }
        let combined = existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? newBlock : existing + memoSeparator + newBlock
        try atomicWrite(string: combined, to: url)
    }

    static func read(from url: URL) throws -> [Memo] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return parse(fileContent: try String(contentsOf: url, encoding: .utf8))
    }

    static func parse(fileContent: String) -> [Memo] {
        fileContent.components(separatedBy: memoSeparator).compactMap {
            let t = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : Memo.fromMarkdown(t)
        }
    }

    private static func atomicWrite(string: String, to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp.\(UUID().uuidString)")
        try Data(string.utf8).write(to: tmp, options: .atomic)
        if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: tmp) }
        else { try fm.moveItem(at: tmp, to: url) }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Test harness
// ---------------------------------------------------------------------------

var passed = 0, failed = 0

func assert(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition {
        print("  ✅ \(message)")
        passed += 1
    } else {
        print("  ❌ FAIL: \(message) (\(file):\(line))")
        failed += 1
    }
}

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String, file: String = #file, line: Int = #line) {
    if a == b {
        print("  ✅ \(message)")
        passed += 1
    } else {
        print("  ❌ FAIL: \(message)\n       got: \(a)\n  expected: \(b) (\(file):\(line))")
        failed += 1
    }
}

// Use a temp directory for file I/O tests
let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("RawStorageTests-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmpDir) }

// ──────────────────────────────────────────────
// Test 1: Serialize a minimal Memo and check round-trip
// ──────────────────────────────────────────────
print("\n── Test 1: Minimal memo round-trip ──")
let now = Date()
let memo1 = Memo(
    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
    type: .text,
    created: now,
    body: "Hello, world!"
)
let md1 = memo1.toMarkdown()
let parsed1 = Memo.fromMarkdown(md1)
assertEqual(parsed1?.id, memo1.id, "id survives round-trip")
assertEqual(parsed1?.type, .text, "type survives round-trip")
assertEqual(parsed1?.body, "Hello, world!", "body survives round-trip")
assert(parsed1?.attachments.isEmpty == true, "empty attachments parsed correctly")

// ──────────────────────────────────────────────
// Test 2: Memo with all fields
// ──────────────────────────────────────────────
print("\n── Test 2: Full memo round-trip ──")
let memo2 = Memo(
    id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
    type: .mixed,
    created: now,
    location: Memo.Location(name: "Joma Coffee, Setthathirath Rd", lat: 17.9757, lng: 102.6331),
    weather: "32°C, 多云",
    device: "iPhone 15 Pro",
    attachments: [
        Memo.Attachment(file: "IMG_20260415_120000.jpg", kind: "photo", duration: nil, transcript: nil),
        Memo.Attachment(file: "voice_20260415_120500.m4a", kind: "audio", duration: 45.3, transcript: "Test transcript.")
    ],
    body: "Had coffee and worked on **DayPage**.\n\nGreat vibe today."
)
let md2 = memo2.toMarkdown()
let parsed2 = Memo.fromMarkdown(md2)
assertEqual(parsed2?.id, memo2.id, "full memo id")
assertEqual(parsed2?.type, .mixed, "full memo type")
assertEqual(parsed2?.location?.name, "Joma Coffee, Setthathirath Rd", "location name")
assertEqual(parsed2?.location?.lat, 17.9757, "location lat")
assertEqual(parsed2?.location?.lng, 102.6331, "location lng")
assertEqual(parsed2?.weather, "32°C, 多云", "weather (Unicode)")
assertEqual(parsed2?.device, "iPhone 15 Pro", "device")
assertEqual(parsed2?.attachments.count, 2, "attachments count")
assertEqual(parsed2?.attachments[1].duration, 45.3, "audio duration")
assertEqual(parsed2?.attachments[1].transcript, "Test transcript.", "audio transcript")
assertEqual(parsed2?.body, "Had coffee and worked on **DayPage**.\n\nGreat vibe today.", "multi-line body")

// ──────────────────────────────────────────────
// Test 3: Multiple memos written/read from file
// ──────────────────────────────────────────────
print("\n── Test 3: Multiple memos file round-trip ──")
let fileURL = tmpDir.appendingPathComponent("2026-04-15.md")

let memoA = Memo(id: UUID(), type: .text, created: now, body: "First memo")
let memoB = Memo(id: UUID(), type: .voice, created: now, body: "Second memo")
let memoC = Memo(id: UUID(), type: .photo, created: now, body: "Third memo")

try RawStorage.append(memoA, to: fileURL)
try RawStorage.append(memoB, to: fileURL)
try RawStorage.append(memoC, to: fileURL)

let readBack = try RawStorage.read(from: fileURL)
assertEqual(readBack.count, 3, "three memos read back")
assertEqual(readBack[0].id, memoA.id, "first memo id matches")
assertEqual(readBack[1].id, memoB.id, "second memo id matches")
assertEqual(readBack[2].id, memoC.id, "third memo id matches")
assertEqual(readBack[0].body, "First memo", "first memo body")
assertEqual(readBack[1].type, .voice, "second memo type")
assertEqual(readBack[2].type, .photo, "third memo type")

// ──────────────────────────────────────────────
// Test 4: Atomic write — temp file does not persist
// ──────────────────────────────────────────────
print("\n── Test 4: Atomic write cleanup ──")
let tmpFiles = try FileManager.default.contentsOfDirectory(atPath: tmpDir.path)
    .filter { $0.hasPrefix(".") && $0.contains(".tmp.") }
assert(tmpFiles.isEmpty, "no leftover temp files after atomic writes")

// ──────────────────────────────────────────────
// Test 5: Separator integrity — body containing "---" on own line
// ──────────────────────────────────────────────
print("\n── Test 5: Body with embedded dashes ──")
let memoD = Memo(id: UUID(), type: .text, created: now,
                 body: "Line one\n\nSome divider:\n\nLine after divider")
let mdD = memoD.toMarkdown()
let parsedD = Memo.fromMarkdown(mdD)
assertEqual(parsedD?.body, memoD.body, "body with blank lines preserved")

// ──────────────────────────────────────────────
// Summary
// ──────────────────────────────────────────────
print("\n────────────────────────────────────────")
print("Results: \(passed) passed, \(failed) failed")
if failed > 0 { exit(1) }
