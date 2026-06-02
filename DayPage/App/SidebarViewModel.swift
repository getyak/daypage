import SwiftUI

// MARK: - RecentDay

/// One row in the sidebar "Recent" section: a date string (`YYYY-MM-DD`) and
/// the count of memos recorded that day. Memo count drives the trailing badge
/// so the user can spot heavy-input days at a glance.
struct RecentDay: Identifiable, Equatable {
    let dateString: String  // YYYY-MM-DD
    let memoCount: Int

    var id: String { dateString }
}

// MARK: - SidebarViewModel

/// Derives display-ready account info from the current auth session and
/// surfaces the last few days that contain memos, so the sidebar can act as a
/// fast jump list ("commit history") into Archive.
@MainActor
final class SidebarViewModel: ObservableObject {

    @Published var isLoggedIn: Bool = false
    @Published var accountEmail: String = ""
    @Published var accountInitial: String = "?"

    /// Four-digit year the signed-in user's account was created, derived from
    /// the Supabase session's `user.createdAt`. `nil` when signed out — the view
    /// falls back to hiding the year rather than showing a hardcoded one.
    @Published var joinYear: Int?

    /// Most recent days (descending) with at least one memo, capped to 7.
    @Published var recentDays: [RecentDay] = []

    /// All active days used for streak calculation (larger scan than recentDays).
    @Published private var streakDays: [RecentDay] = []

    // MARK: - Heatmap + stats (museum-aesthetic sidebar, M2)

    /// Memo count per active day across the last ~16 weeks, keyed by
    /// `YYYY-MM-DD`. Drives the 16×7 sidebar heatmap. Days with no memos are
    /// simply absent (lookup returns 0).
    @Published var heatmapCounts: [String: Int] = [:]

    /// Total memos captured across the heatmap window (the "N ENTRIES" figure).
    @Published var totalEntries16Weeks: Int = 0

    /// Number of compiled daily pages on disk (`vault/wiki/daily/*.md`).
    @Published var totalPages: Int = 0

    /// Approximate total words across all raw memo bodies (CJK chars + Latin
    /// words), shown as the "WORDS" stat. Formatted lazily by the view.
    @Published var totalWordCount: Int = 0

    /// Consecutive calendar days ending today (or yesterday) with at least one memo.
    /// Starts counting from the most recent active day and stops at the first gap.
    /// Longest consecutive-day writing run ever recorded within the 365-day
    /// scan window. Returns 0 for an empty vault.
    var longestStreak: Int {
        let cal = Calendar.current
        let activeDates = Set(streakDays.map(\.dateString))
        guard !activeDates.isEmpty else { return 0 }

        // Parse and sort dates ascending.
        let sorted = activeDates
            .compactMap { Self.isoFormatter.date(from: $0) }
            .map { cal.startOfDay(for: $0) }
            .sorted()

        var maxRun = 1
        var currentRun = 1
        for i in 1 ..< sorted.count {
            let gap = cal.dateComponents([.day], from: sorted[i - 1], to: sorted[i]).day ?? 0
            if gap == 1 {
                currentRun += 1
                if currentRun > maxRun { maxRun = currentRun }
            } else {
                currentRun = 1
            }
        }
        return maxRun
    }

    var currentStreak: Int {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        // Build a Set of active date strings for O(1) lookup.
        let activeDates = Set(streakDays.map(\.dateString))

        // Anchor: use today if it has memos, else yesterday (so streak
        // doesn't reset before the user logs their first entry of the day).
        let todayStr = Self.isoFormatter.string(from: today)
        guard let yesterday = cal.date(byAdding: .day, value: -1, to: today) else { return 0 }
        let yesterdayStr = Self.isoFormatter.string(from: yesterday)

        let anchorDate: Date
        if activeDates.contains(todayStr) {
            anchorDate = today
        } else if activeDates.contains(yesterdayStr) {
            anchorDate = yesterday
        } else {
            return 0
        }

        var streak = 0
        var cursor = anchorDate
        while true {
            let dateStr = Self.isoFormatter.string(from: cursor)
            guard activeDates.contains(dateStr) else { break }
            streak += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return streak
    }

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f
    }()

    /// Formats a `Date` to a 4-digit calendar year (e.g. "2026") for the
    /// "MEMBER · SINCE <year>" line, in the user's current time zone.
    private static let yearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy"
        f.timeZone = TimeZone.current
        return f
    }()

    private var authStateTask: Task<Void, Never>?

    func bind(authService: AuthService) {
        // Reflect current state immediately.
        updateFrom(authService: authService)

        // Stream subsequent changes via authStateChanges so the sidebar
        // stays in sync without polling or Combine.
        authStateTask?.cancel()
        authStateTask = Task { [weak self, weak authService] in
            guard let authService else { return }
            for await (_, session) in authService.supabase.auth.authStateChanges {
                if Task.isCancelled { break }
                let email = session?.user.email ?? ""
                let year = session.map { Self.yearFormatter.string(from: $0.user.createdAt) }
                    .flatMap { Int($0) }
                await MainActor.run {
                    self?.isLoggedIn = session != nil
                    self?.accountEmail = email
                    self?.accountInitial = email.first.map { String($0).uppercased() } ?? "?"
                    self?.joinYear = year
                }
            }
        }
    }

    /// Re-scan `vault/raw/*.md` and publish the most recent 7 days and streak
    /// off the main actor. Safe to call repeatedly (e.g. whenever the sidebar opens).
    func refreshRecentDays() {
        Task { [weak self] in
            await self?.refreshRecentDaysAsync()
        }
    }

    /// Awaitable variant of `refreshRecentDays`. Callers that need to act on
    /// fresh streak data immediately after the scan (e.g. milestone celebration)
    /// should `await` this instead of calling `refreshRecentDays()` + sleeping.
    func refreshRecentDaysAsync() async {
        async let recent = Self.scanRecentDays(limit: 7)
        async let streak = Self.scanRecentDays(limit: 365)
        // 16 weeks = 112 days; scan a touch more to cover the partial
        // leading week the grid renders.
        async let heatmap = Self.scanRecentDays(limit: 119)
        async let stats = Self.scanStats()
        let (recentResult, streakResult, heatmapResult, statsResult) =
            await (recent, streak, heatmap, stats)
        await MainActor.run {
            self.recentDays = recentResult
            self.streakDays = streakResult
            let counts = Dictionary(
                heatmapResult.map { ($0.dateString, $0.memoCount) },
                uniquingKeysWith: { a, _ in a }
            )
            self.heatmapCounts = counts
            // Count only memos within the 112-day (16-week) heatmap window.
            // scanRecentDays limits by *file count*, so an intermittent
            // journaler's 119 files can reach back well beyond 16 weeks;
            // filter by calendar date so the "N ENTRIES" figure matches the
            // grid the user actually sees.
            let cal = Calendar.current
            let windowStart = cal.date(
                byAdding: .day, value: -111, to: cal.startOfDay(for: Date())
            )
            self.totalEntries16Weeks = heatmapResult.reduce(0) { acc, day in
                guard let windowStart,
                      let date = Self.isoFormatter.date(from: day.dateString),
                      date >= windowStart else { return acc }
                return acc + day.memoCount
            }
            self.totalPages = statsResult.pages
            self.totalWordCount = statsResult.words
        }
    }

    private func updateFrom(authService: AuthService) {
        let session = authService.session
        let email = session?.user.email ?? ""
        isLoggedIn = session != nil
        accountEmail = email
        accountInitial = email.first.map { String($0).uppercased() } ?? "?"
        joinYear = session.map { Self.yearFormatter.string(from: $0.user.createdAt) }
            .flatMap { Int($0) }
    }

    deinit {
        authStateTask?.cancel()
    }

    // MARK: - Vault Scan

    /// Reads `vault/raw/YYYY-MM-DD.md`, counts memos per day (memos are
    /// separated by `\n\n---\n\n`), and returns the most recent `limit` days
    /// in descending order. Missing/unreadable files are skipped silently.
    nonisolated private static func scanRecentDays(limit: Int) async -> [RecentDay] {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let rawDir = VaultInitializer.vaultURL.appendingPathComponent("raw")
            guard let entries = try? fm.contentsOfDirectory(atPath: rawDir.path) else {
                return []
            }

            // Keep only YYYY-MM-DD.md filenames; sort descending.
            let dateStrings: [String] = entries.compactMap { name in
                guard name.hasSuffix(".md") else { return nil }
                let base = String(name.dropLast(3))
                guard base.count == 10,
                      base[base.index(base.startIndex, offsetBy: 4)] == "-",
                      base[base.index(base.startIndex, offsetBy: 7)] == "-" else { return nil }
                let digits = base.replacingOccurrences(of: "-", with: "")
                guard digits.count == 8, digits.allSatisfy({ $0.isNumber }) else { return nil }
                return base
            }
            .sorted(by: >)

            var out: [RecentDay] = []
            for dateStr in dateStrings.prefix(limit) {
                let url = rawDir.appendingPathComponent("\(dateStr).md")
                let count = countMemos(at: url, fileManager: fm)
                if count > 0 {
                    out.append(RecentDay(dateString: dateStr, memoCount: count))
                }
            }
            return out
        }.value
    }

    /// Scan vault for aggregate stats:
    ///   • pages — number of compiled daily pages (`vault/wiki/daily/*.md`)
    ///   • words — approximate total words across all raw memo bodies
    ///     (front-matter stripped; non-whitespace characters counted, which
    ///     reads naturally for CJK and is a fair proxy for Latin too).
    nonisolated private static func scanStats() async -> (pages: Int, words: Int) {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let vault = VaultInitializer.vaultURL

            // Pages: count YYYY-MM-DD.md files under wiki/daily.
            let dailyDir = vault.appendingPathComponent("wiki/daily")
            var pages = 0
            if let names = try? fm.contentsOfDirectory(atPath: dailyDir.path) {
                pages = names.filter { $0.hasSuffix(".md") }.count
            }

            // Words: walk raw/*.md, strip YAML front-matter blocks, count
            // non-whitespace characters in the remaining body text.
            let rawDir = vault.appendingPathComponent("raw")
            var words = 0
            if let names = try? fm.contentsOfDirectory(atPath: rawDir.path) {
                for name in names where name.hasSuffix(".md") {
                    let url = rawDir.appendingPathComponent(name)
                    guard let data = try? Data(contentsOf: url),
                          let text = String(data: data, encoding: .utf8) else { continue }
                    words += approxBodyWordCount(text)
                }
            }
            return (pages, words)
        }.value
    }

    /// Counts non-whitespace body characters across all memos in a raw daily
    /// file. Delegates splitting + front-matter stripping to `RawStorage.parse`
    /// (the single source of truth) so a literal `---` horizontal rule in user
    /// text, or the legacy `\n\n---\n\n` inter-memo separator, can't desync a
    /// hand-rolled front-matter toggle and silently drop body text.
    nonisolated private static func approxBodyWordCount(_ text: String) -> Int {
        RawStorage.parse(fileContent: text).reduce(0) { acc, memo in
            acc + memo.body.filter { !$0.isWhitespace }.count
        }
    }

    /// Count memos in a single raw daily file. Memos are separated by the
    /// canonical `<!-- daypage-memo-separator -->` delimiter (see
    /// RawStorage.swift). Empty file or read failure → 0.
    nonisolated private static func countMemos(at url: URL, fileManager: FileManager) -> Int {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return 0 }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        // Try the canonical separator first, fall back to the legacy `---` form.
        let modern = trimmed.components(separatedBy: RawStorage.memoSeparator)
        if modern.count > 1 { return modern.count }
        return trimmed.components(separatedBy: RawStorage.legacyMemoSeparator).count
    }
}
