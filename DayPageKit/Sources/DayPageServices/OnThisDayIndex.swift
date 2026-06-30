import Foundation
import DayPageStorage

// MARK: - OnThisDayEntry

public struct OnThisDayEntry: Codable {
    public let originalDate: Date
    public let yearsAgo: Int?
    public let daysAgo: Int?
    public let preview: String
    public let filePath: String
}

// MARK: - Index storage types

private struct DayRecord: Codable {
    public let year: Int
    public let filePath: String
    public let memoCount: Int
    public let longestMemoPreview: String
}

// MARK: - OnThisDayIndex

@MainActor
public final class OnThisDayIndex: ObservableObject {

    public static let shared = OnThisDayIndex()

    /// R8 — signal that the on-disk / built index is loaded and `candidate(for:)`
    /// is safe to call against real data. TodayView observes this so the top
    /// OnThisDayCard can light up as soon as the first-launch vault scan
    /// finishes, instead of waiting for the next .onAppear / scenePhase pass.
    /// Flips true at the end of `loadIndex()` and `rebuildIndex()`; reset to
    /// false only in `resetForTesting()` (DEBUG).
    @Published private(set) var isReady: Bool = false

    private var index: [String: [DayRecord]] = [:]  // 键："MMDD"
    private let indexURL: URL = {
        VaultInitializer.vaultURL
            .appendingPathComponent("wiki")
            .appendingPathComponent("index.json")
    }()

    private init() {}

    // MARK: - Public API

    public func candidate(for date: Date) -> OnThisDayEntry? {
        let cal = Calendar.current
        let mmdd = mmddKey(from: date)
        guard let records = index[mmdd] else { return nil }

        let currentYear = cal.component(.year, from: date)

        // 优先选择恰好 1 年前的
        if let r = records.first(where: { $0.year == currentYear - 1 }) {
            return makeEntry(record: r, currentYear: currentYear)
        }
        // 其次约 180 天（6 个月，同年或前一年）
        let sixMonthsAgo = cal.date(byAdding: .day, value: -180, to: date)!
        let sixMonthYear = cal.component(.year, from: sixMonthsAgo)
        let sixMonthMMDD = mmddKey(from: sixMonthsAgo)
        if sixMonthMMDD == mmdd, let r = records.first(where: { $0.year == sixMonthYear }) {
            return makeEntry(record: r, currentYear: currentYear)
        }
        // 其次 2 年前的
        if let r = records.first(where: { $0.year == currentYear - 2 }) {
            return makeEntry(record: r, currentYear: currentYear)
        }
        return nil
    }

    // MARK: - Index Building

    public func rebuildIndex() async {
        let built = await Task.detached(priority: .utility) {
            OnThisDayIndex.buildIndexOff()
        }.value
        index = built
        await persistIndex(built)
        // R8 — flip isReady AFTER index assign + persist so any observer
        // (TodayView.onReceive) that reacts by calling candidate(for:) sees
        // the fresh index, not the empty initial dictionary.
        isReady = true
    }

    public func loadIndex() async {
        // 尝试先从磁盘加载，若缺失则重建
        if let loaded = loadIndexFromDisk() {
            index = loaded
            // R8 — disk-hit fast path also sets isReady so the top
            // OnThisDayCard wakes immediately on warm launches (no rebuild
            // needed). rebuildIndex() handles the cold-launch case.
            isReady = true
        } else {
            await rebuildIndex()
        }
    }

    #if DEBUG
    /// Test-only hook to clear the in-memory index. Used by tests to avoid
    /// process-wide state pollution between cases (OnThisDayIndex.shared is
    /// a singleton; without this, a vault seeded by one test can leak into
    /// the next test's candidate(for:) lookup).
    public func resetForTesting() {
        index = [:]
        isReady = false
    }
    #endif

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
        // filePath 的基础名是 YYYY-MM-DD.md
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
