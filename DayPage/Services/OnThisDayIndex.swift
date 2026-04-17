import Foundation

// MARK: - OnThisDayEntry

struct OnThisDayEntry: Codable {
    let originalDate: Date
    let yearsAgo: Int?
    let daysAgo: Int?
    let preview: String
    let filePath: String
}

// MARK: - Index storage types

private struct DayRecord: Codable {
    let year: Int
    let filePath: String
    let memoCount: Int
    let longestMemoPreview: String
}

// MARK: - OnThisDayIndex

@MainActor
final class OnThisDayIndex: ObservableObject {

    static let shared = OnThisDayIndex()

    private var index: [String: [DayRecord]] = [:]  // key: "MMDD"
    private let indexURL: URL = {
        VaultInitializer.vaultURL
            .appendingPathComponent("wiki")
            .appendingPathComponent("index.json")
    }()

    private init() {}

    // MARK: - Public API

    func candidate(for date: Date) -> OnThisDayEntry? {
        let cal = Calendar.current
        let mmdd = mmddKey(from: date)
        guard let records = index[mmdd] else { return nil }

        let currentYear = cal.component(.year, from: date)

        // Prefer exactly 1 year ago
        if let r = records.first(where: { $0.year == currentYear - 1 }) {
            return makeEntry(record: r, currentYear: currentYear)
        }
        // Then ~180 days (6 months, same year or prior)
        let sixMonthsAgo = cal.date(byAdding: .day, value: -180, to: date)!
        let sixMonthYear = cal.component(.year, from: sixMonthsAgo)
        let sixMonthMMDD = mmddKey(from: sixMonthsAgo)
        if sixMonthMMDD == mmdd, let r = records.first(where: { $0.year == sixMonthYear }) {
            return makeEntry(record: r, currentYear: currentYear)
        }
        // Then 2 years ago
        if let r = records.first(where: { $0.year == currentYear - 2 }) {
            return makeEntry(record: r, currentYear: currentYear)
        }
        return nil
    }

    // MARK: - Index Building

    func rebuildIndex() async {
        let built = await Task.detached(priority: .utility) {
            OnThisDayIndex.buildIndexOff()
        }.value
        index = built
        await persistIndex(built)
    }

    func loadIndex() async {
        // Try to load from disk first, then rebuild if missing
        if let loaded = loadIndexFromDisk() {
            index = loaded
        } else {
            await rebuildIndex()
        }
    }

    // MARK: - Private helpers

    private func makeEntry(record: DayRecord, currentYear: Int) -> OnThisDayEntry {
        let diff = currentYear - record.year
        let yearsAgo: Int? = (diff >= 1) ? diff : nil
        let daysAgo: Int? = (diff == 0) ? 180 : nil
        return OnThisDayEntry(
            originalDate: dateFromRecord(record),
            yearsAgo: yearsAgo,
            daysAgo: daysAgo,
            preview: record.longestMemoPreview,
            filePath: record.filePath
        )
    }

    private func dateFromRecord(_ record: DayRecord) -> Date {
        // filePath basename is YYYY-MM-DD.md
        let name = URL(fileURLWithPath: record.filePath).deletingPathExtension().lastPathComponent
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone.current
        return fmt.date(from: name) ?? Date()
    }

    private func mmddKey(from date: Date) -> String {
        let cal = Calendar.current
        let month = cal.component(.month, from: date)
        let day = cal.component(.day, from: date)
        return String(format: "%02d%02d", month, day)
    }

    // MARK: - Static scanning (nonisolated — runs off main actor)

    private static nonisolated func buildIndexOff() -> [String: [DayRecord]] {
        let rawDir = VaultInitializer.vaultURL.appendingPathComponent("raw")
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: rawDir, includingPropertiesForKeys: nil) else {
            return [:]
        }

        var result: [String: [DayRecord]] = [:]
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone.current

        for case let url as URL in enumerator {
            guard url.pathExtension == "md",
                  let date = fmt.date(from: url.deletingPathExtension().lastPathComponent)
            else { continue }

            let cal = Calendar.current
            let month = cal.component(.month, from: date)
            let day = cal.component(.day, from: date)
            let year = cal.component(.year, from: date)
            let key = String(format: "%02d%02d", month, day)

            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let memos = RawStorage.parse(fileContent: content)
            guard !memos.isEmpty else { continue }

            let longestPreview = memos
                .compactMap { $0.body }
                .max(by: { $0.count < $1.count })
                .map { String($0.prefix(120)) } ?? ""

            let record = DayRecord(
                year: year,
                filePath: url.path,
                memoCount: memos.count,
                longestMemoPreview: longestPreview
            )

            if result[key] != nil {
                result[key]!.append(record)
            } else {
                result[key] = [record]
            }
        }
        return result
    }

    // MARK: - Persistence

    private func persistIndex(_ built: [String: [DayRecord]]) async {
        do {
            let data = try JSONEncoder().encode(built)
            let dir = indexURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            DayPageLogger.shared.error("OnThisDayIndex: persist failed: \(error)")
        }
    }

    private func loadIndexFromDisk() -> [String: [DayRecord]]? {
        guard FileManager.default.fileExists(atPath: indexURL.path),
              let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([String: [DayRecord]].self, from: data)
        else { return nil }
        return decoded
    }
}
