import Foundation
import DayPageModels
import DayPageStorage

// MARK: - InsightActionService (Issue #8, 2026-07-03)
//
// Turns a compiled insight (a Daily or Weekly bullet) into an actionable
// memo that lands in tomorrow's `vault/raw/YYYY-MM-DD.md` so the user
// wakes up with the insight already queued as a next step.
//
// Backlog framing:
//   "研究工具的最终价值不是生成摘要，而是帮助团队做决策." — Issue #8
//
// Design decisions:
//   - We do NOT introduce a new Memo.MemoType. Adding cases to the model
//     ripples through the parser, serializer, and every consumer view. A
//     `[待办]` body prefix costs one string check and stays inside the
//     existing text-memo lane, which every surface already renders.
//   - The action target is *tomorrow*, not today. Today's page is closed
//     mentally — adding a todo there feels like homework for a day the
//     user is trying to wrap. Tomorrow reads as a promise.
//   - We stamp `origin: insight` in the memo body so a future dashboard
//     can distinguish user-typed memos from insight-derived ones. It is
//     a machine-readable trailer, not shown to humans.

@MainActor
public enum InsightActionService {

    /// Converts an insight bullet into a todo memo written to tomorrow's
    /// raw file. Returns the created Memo so callers can commit UI
    /// affordances (haptic, banner "已加入明日", undo).
    ///
    /// - Parameters:
    ///   - insight: the raw text the user tapped to convert.
    ///   - source: short-form origin tag (e.g. `"daily-2026-07-02"` or
    ///     `"weekly-2026-W27"`) preserved as a trailer so future features
    ///     can rebuild the causal graph.
    /// - Throws: whatever RawStorage.append surfaces (disk full, iCloud
    ///     conflict, etc). Callers should hand this to `AppError` for
    ///     user-facing presentation.
    @discardableResult
    public static func convertToTomorrowTodo(
        insight: String,
        source: String
    ) throws -> Memo {
        guard let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) else {
            throw NSError(domain: "InsightActionService", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法计算明天的日期"])
        }
        let trimmed = insight.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = """
        [待办] \(trimmed)

        <!-- origin: insight | source: \(source) -->
        """
        let memo = Memo(
            id: UUID(),
            type: .text,
            created: startOfDayLocal(tomorrow),
            location: nil,
            weather: nil,
            device: "InsightAction",
            attachments: [],
            body: body
        )
        try RawStorage.append(memo)
        return memo
    }

    private static func startOfDayLocal(_ date: Date) -> Date {
        var cal = Calendar.current
        cal.timeZone = TimeZone.current
        return cal.startOfDay(for: date)
    }
}
