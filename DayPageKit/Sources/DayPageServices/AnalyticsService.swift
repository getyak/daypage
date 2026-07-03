import Foundation
import DayPageStorage

// MARK: - AnalyticsService (Issue #18, 2026-07-02)
//
// Local, privacy-first product analytics for DayPage.
//
// Why:
//   The product-experience backlog Issue #18 calls out that we cannot judge
//   which user flows deserve more polish because nothing is instrumented. A
//   remote analytics vendor is off the table — DayPage is local-first, the
//   vault contains PII, and the user has already been told in onboarding
//   that no behavioural data leaves the device.
//
// What this is:
//   - Append-only JSONL at `vault/.analytics/events.jsonl`. One JSON object
//     per line, no schema versioning needed at this stage — the reader
//     tolerates unknown keys.
//   - Fixed set of event names (see `Event.Name`) so autocomplete keeps
//     drift low and typos surface at compile time.
//   - Bounded on disk: newest 10 000 events are kept; older ones are dropped
//     when the file is rotated during `record(…)` (single-writer via
//     `@MainActor`, so no concurrent-writer races).
//   - Debug read API used by the Settings "调试看板" surface: today's counts
//     + the most recent 100 events.
//
// What this is NOT:
//   - Not a queue. Callers do not await network I/O — this is disk-only.
//   - Not a trace/log. Freeform Sentry breadcrumbs remain the mechanism for
//     ad-hoc debugging.
//   - Not a public API contract for extensions or Watch. This service lives
//     in the app-container process; Watch extension writes to its own store.

@MainActor
public final class AnalyticsService {

    public static let shared = AnalyticsService()

    // MARK: Event

    public struct Event: Codable {
        public let name: String   // one of `Event.Name.*`
        public let at: String     // ISO-8601 UTC
        public let props: [String: String]

        public init(name: String, at: Date = Date(), props: [String: String] = [:]) {
            self.name = name
            self.at = Self.iso.string(from: at)
            self.props = props
        }

        static let iso: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
    }

    // Fixed vocabulary. Adding a new event = add a case here, so a grep
    // audit will always turn up every emission site.
    public enum Name {
        public static let memoCreated       = "memo_created"
        public static let compileStarted    = "compile_started"
        public static let compileCompleted  = "compile_completed"
        public static let compileFailed     = "compile_failed"
        public static let detailOpened      = "detail_opened"
        public static let shareCreated      = "share_created"
        public static let searchUsed        = "search_used"
        public static let sampleSeeded      = "sample_seeded"      // Issue #2 CTA
        public static let welcomeCtaSample  = "welcome_cta_sample" // Issue #1 secondary CTA
    }

    // MARK: Config

    /// Bound the on-disk history so a long-running install cannot balloon
    /// the vault. 10 000 events ≈ several months of active use at a typical
    /// 10-event/day. Set at the top of the file so a dogfooder can eyeball.
    private static let maxRetainedEvents = 10_000

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()

    // MARK: Filesystem

    private var eventsURL: URL {
        // Issue #18 (2026-07-03): drop the leading dot on the folder
        // name. iOS's file coordination and RawStorage's scanners have
        // both surprised us before with `.`-prefixed paths (invisible in
        // Files.app, sometimes swallowed by iCloud sync). Showing a
        // visible `_analytics/` folder inside the vault has negligible
        // user impact — the debug board is opt-in — but makes the events
        // actually reach disk on a fresh install.
        VaultInitializer.vaultURL
            .appendingPathComponent("_analytics", isDirectory: true)
            .appendingPathComponent("events.jsonl")
    }

    private func ensureContainer() throws {
        let dir = eventsURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: Public API

    /// Records a single event. Safe to call from anywhere on the main
    /// actor; disk failures are logged and swallowed — we never want a
    /// visible feature to fail because of instrumentation.
    public func record(_ name: String, props: [String: String] = [:]) {
        let event = Event(name: name, props: props)
        do {
            try ensureContainer()
            var line = try encoder.encode(event)
            line.append(0x0A) // LF

            if fileManager.fileExists(atPath: eventsURL.path) {
                let handle = try FileHandle(forWritingTo: eventsURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: eventsURL, options: .atomic)
            }

            rotateIfNeeded()
        } catch {
            DayPageLogger.shared.error("AnalyticsService: record failed for \(name): \(error)")
        }
    }

    /// Reads the newest N events, oldest → newest. Used by the Settings
    /// debug board. Missing file is treated as "no events yet".
    public func recentEvents(limit: Int = 100) -> [Event] {
        guard let all = readAllLines() else { return [] }
        let events = all.compactMap { line -> Event? in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(Event.self, from: data)
        }
        if events.count <= limit { return events }
        return Array(events.suffix(limit))
    }

    /// Today's event count grouped by name (UTC calendar day). Cheap enough
    /// to compute on demand for the debug board — no need to precompute.
    public func todaysCounts() -> [String: Int] {
        guard let all = readAllLines() else { return [:] }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .current
        let today = utc.startOfDay(for: Date())

        var out: [String: Int] = [:]
        for line in all {
            guard let data = line.data(using: .utf8),
                  let event = try? decoder.decode(Event.self, from: data),
                  let ts = Event.iso.date(from: event.at),
                  utc.isDate(ts, inSameDayAs: today)
            else { continue }
            out[event.name, default: 0] += 1
        }
        return out
    }

    /// Wipes the analytics file. Called from Settings "重置调试数据" — never
    /// automatically, so the user always makes the call.
    public func reset() {
        try? fileManager.removeItem(at: eventsURL)
    }

    // MARK: Private

    private func readAllLines() -> [String]? {
        guard fileManager.fileExists(atPath: eventsURL.path),
              let data = try? Data(contentsOf: eventsURL),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private func rotateIfNeeded() {
        guard let lines = readAllLines(), lines.count > Self.maxRetainedEvents else { return }
        let kept = Array(lines.suffix(Self.maxRetainedEvents))
        let joined = kept.joined(separator: "\n") + "\n"
        try? joined.data(using: .utf8)?.write(to: eventsURL, options: .atomic)
    }
}
