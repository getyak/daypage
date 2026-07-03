import Foundation

// MARK: - LLMUsageTracker (Issue #20, 2026-07-03)
//
// Local, privacy-first LLM usage bookkeeping.
//
// Backlog framing:
//   "接近额度上限时提前提醒 (Issue #20)."
//
// DayPage's LLM calls (compile, weekly recap, ask-past) hit third-party
// APIs the user pays for. Today the app can't answer "how much did the
// last week of AI features cost?" or "how close am I to the monthly
// cap?". This tracker keeps a rolling per-day + per-month tally and
// exposes it to a Settings surface + banner.
//
// Design decisions:
//   - Estimates. We do NOT parse the LLM response usage block — schema
//     drift across DeepSeek / OpenAI / DashScope isn't worth the
//     brittleness for a bookkeeping feature. Instead we approximate
//     `tokens ≈ chars / 4` on both prompt and response strings. That is
//     roughly the OpenAI GPT-3.5 rule and close enough for user-facing
//     "80% of your monthly budget" alarms.
//   - Bucketed by ISO calendar day; month totals are derived at read
//     time so we don't have to migrate the on-disk schema when month
//     starts move around a user's time zone.
//   - Cap. The user configures a monthly ceiling in
//     `settings.llm.monthlyTokenBudget`. Reaching 80% raises a warning
//     the SettingsView surfaces.

@MainActor
public final class LLMUsageTracker: ObservableObject {

    public static let shared = LLMUsageTracker()

    private let defaultsKey = "settings.llm.usageBuckets.v1"
    private let budgetKey = "settings.llm.monthlyTokenBudget"

    @Published public private(set) var lastRecordedAt: Date?

    private init() {}

    // MARK: - Recording

    /// Approximates tokens as `chars / 4` and updates today's bucket.
    /// Callers pass the *full* prompt + response strings — the estimation
    /// runs on the total.
    public func record(prompt: String, response: String, purpose: String) {
        let approx = max(1, (prompt.count + response.count) / 4)
        recordTokens(approx, purpose: purpose)
    }

    /// Direct token-count recorder for callers who already have a real
    /// usage number from the vendor response.
    public func recordTokens(_ tokens: Int, purpose: String) {
        let key = todayKey()
        let defaults = UserDefaults.standard
        var dict = (defaults.dictionary(forKey: defaultsKey) as? [String: [String: Int]]) ?? [:]
        var today = dict[key] ?? [:]
        today[purpose, default: 0] += tokens
        today["total", default: 0] += tokens
        dict[key] = today
        // Prune buckets older than 60 days to keep the plist tight.
        let cutoff = Calendar.current.date(byAdding: .day, value: -60, to: Date()) ?? Date()
        let cutoffKey = Self.dateFormatter.string(from: cutoff)
        dict = dict.filter { $0.key >= cutoffKey }
        defaults.set(dict, forKey: defaultsKey)
        lastRecordedAt = Date()
    }

    // MARK: - Reads

    public struct MonthUsage {
        public let totalTokens: Int
        public let byPurpose: [String: Int]
        public let daysWithActivity: Int
    }

    /// Aggregates all buckets whose key falls inside the current month
    /// (device time zone).
    public func currentMonthUsage() -> MonthUsage {
        let defaults = UserDefaults.standard
        let dict = (defaults.dictionary(forKey: defaultsKey) as? [String: [String: Int]]) ?? [:]
        let month = Self.monthKeyPrefix()
        var total = 0
        var byPurpose: [String: Int] = [:]
        var days = 0
        for (key, bucket) in dict where key.hasPrefix(month) {
            days += 1
            for (purpose, n) in bucket where purpose != "total" {
                byPurpose[purpose, default: 0] += n
            }
            total += bucket["total"] ?? 0
        }
        return MonthUsage(totalTokens: total, byPurpose: byPurpose, daysWithActivity: days)
    }

    // MARK: - Budget

    public var monthlyBudget: Int {
        get { UserDefaults.standard.integer(forKey: budgetKey) }
        set { UserDefaults.standard.set(newValue, forKey: budgetKey) }
    }

    /// True when the current month has crossed 80% of the configured
    /// monthly budget. 0 means "no budget set" and never triggers.
    public var hasCrossedBudgetWarning: Bool {
        let budget = monthlyBudget
        guard budget > 0 else { return false }
        return Double(currentMonthUsage().totalTokens) >= Double(budget) * 0.8
    }

    // MARK: - Helpers

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func todayKey() -> String {
        Self.dateFormatter.string(from: Date())
    }

    private static func monthKeyPrefix() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }
}
