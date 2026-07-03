import Foundation

// MARK: - TodayFocusStore (Issue #13, 2026-07-03)
//
// Backlog framing:
//   "分析前让用户选择目标 (可用性测试 / 访谈总结 / 问卷分析 / 流失分析 /
//   竞品研究)，或输入自定义问题." — Issue #13
//
// DayPage's user-facing analog is a small set of "今日焦点" chips: the
// user can tag today with one or more themes (工作 / 情绪 / 健康 / 关系
// / 学习), and CompilationService.buildPrompt appends those tags to the
// system prompt so the compiled daily leans toward that lens.
//
// Design decisions:
//   - Persisted in UserDefaults (a `{"YYYY-MM-DD": ["work", "mood"]}`
//     dictionary), NOT in vault YAML. The tag is a *steering hint*, not
//     a document — writing to raw would collide with Obsidian sync and
//     inflate the vault with a value the user should be able to change
//     without triggering iCloud fanout.
//   - Fixed vocabulary. Free-form tags dilute the prompt too much for
//     the LLM to act on; five well-known lenses give the compiler a
//     clear signal.
//   - Retention: 7 rolling days. The UI only writes today, and
//     CompilationService reads a specific date on demand.

public enum TodayFocus: String, CaseIterable, Codable {
    case work      = "work"
    case mood      = "mood"
    case health    = "health"
    case relations = "relations"
    case learning  = "learning"

    public var displayName: String {
        switch self {
        case .work:      return "工作"
        case .mood:      return "情绪"
        case .health:    return "健康"
        case .relations: return "关系"
        case .learning:  return "学习"
        }
    }

    public var promptHint: String {
        switch self {
        case .work:
            return "着重梳理任务、决策、被卡住的地方与推进方式."
        case .mood:
            return "着重刻画情绪起伏、触发情境与身体感觉，避免评价性语言."
        case .health:
            return "着重记录身体状态、睡眠饮食运动信号，以及影响它们的行为."
        case .relations:
            return "着重梳理与他人的互动模式、边界、期待与实际发生的落差."
        case .learning:
            return "着重提炼你学到什么、想验证什么、下一次会如何尝试."
        }
    }
}

@MainActor
public final class TodayFocusStore: ObservableObject {

    public static let shared = TodayFocusStore()

    private let defaultsKey = "settings.todayFocus.v1"
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Published so Today's chip row rebinds when the user toggles.
    @Published public private(set) var focuses: [TodayFocus] = []

    private init() {
        focuses = loadForKey(currentDateKey())
    }

    // MARK: - Public API

    public func toggle(_ focus: TodayFocus) {
        var next = focuses
        if let idx = next.firstIndex(of: focus) {
            next.remove(at: idx)
        } else {
            next.append(focus)
        }
        focuses = next
        persist(next, forKey: currentDateKey())
    }

    public func focuses(on date: Date) -> [TodayFocus] {
        loadForKey(dateFormatter.string(from: date))
    }

    // MARK: - Persistence

    private func currentDateKey() -> String {
        dateFormatter.string(from: Date())
    }

    private func persist(_ focuses: [TodayFocus], forKey key: String) {
        let defaults = UserDefaults.standard
        var dict = (defaults.dictionary(forKey: defaultsKey) as? [String: [String]]) ?? [:]
        if focuses.isEmpty {
            dict.removeValue(forKey: key)
        } else {
            dict[key] = focuses.map { $0.rawValue }
        }
        // Prune anything older than 7 days so the dict stays small.
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let cutoffKey = dateFormatter.string(from: cutoff)
        dict = dict.filter { $0.key >= cutoffKey }
        defaults.set(dict, forKey: defaultsKey)
    }

    private func loadForKey(_ key: String) -> [TodayFocus] {
        let defaults = UserDefaults.standard
        guard let dict = defaults.dictionary(forKey: defaultsKey) as? [String: [String]],
              let raws = dict[key]
        else { return [] }
        return raws.compactMap(TodayFocus.init(rawValue:))
    }
}
