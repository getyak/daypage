import Foundation

// MARK: - ChatMarkdownRenderer

/// 把一段会话事件日志渲染成 Obsidian 兼容的 Markdown 导出件。
///
/// 分工与 memo 侧同构：JSONL 是机器可靠的存储格式（追加安全、流式友好），
/// Markdown 是人类可读的导出格式——存储层永远不用 Markdown 做往返解析。
/// 「依据」行渲染成 `[[yyyy-MM-dd]]` wikilink，在 Obsidian 里可点回当天。
public enum ChatMarkdownRenderer {

    /// 会话进入方式的导出标签。
    public static func entryLabel(_ entry: ChatEntryKind) -> String {
        switch entry {
        case .ask:   return "问过去"
        case .memo:  return "记忆锚定"
        case .coach: return "陪写"
        }
    }

    /// 渲染完整导出件（YAML front-matter + 逐轮正文）。
    public static func render(_ session: LoadedChatSession) -> String {
        let summary = session.summary
        let timeFmt = Self.timeFormatter
        let startTime = timeFmt.string(from: summary.startedAt)

        var lines: [String] = ["---"]
        lines.append("type: chat_session")
        lines.append("date: \(summary.dayString)")
        lines.append("time: \"\(startTime)\"")
        lines.append("entry: \(entryLabel(summary.entry))")
        if let anchorDate = summary.anchorMemoDate {
            lines.append("anchor_memo_date: \(anchorDate)")
        }
        lines.append("turns: \(session.turns.count)")
        lines.append("export_source: DayPage")
        lines.append("---")
        lines.append("")
        lines.append("# 和过去对话 — \(summary.dayString) \(startTime)")
        lines.append("")

        for turn in session.turns {
            let speaker = turn.role == .user ? "我" : "DayPage"
            lines.append("**\(speaker)**（\(timeFmt.string(from: turn.createdAt))）")
            lines.append("")
            lines.append(turn.text)
            lines.append("")

            // assistant 轮的检索依据（来自 retrieval 事件的合成 context）。
            if turn.role == .assistant, let context = turn.context, !context.isEmpty {
                var parts: [String] = context.memoHits.map { "[[\($0.dateString)]]" }
                parts.append(contentsOf: context.entityHits.map { $0.displayName })
                if !parts.isEmpty {
                    lines.append("> 依据：\(parts.joined(separator: " · "))")
                    lines.append("")
                }
            }
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// 导出文件名，与 memo 导出命名同族：`DayPage Chat 2026-07-15 1432.md`。
    /// 同日多段会话靠 HHmm 区分；同分钟撞名由写入方追加序号。
    public static func exportFileName(for summary: ChatSessionSummary) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HHmm"
        f.timeZone = TimeZone.current
        return "DayPage Chat \(summary.dayString) \(f.string(from: summary.startedAt)).md"
    }

    private static var timeFormatter: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        f.timeZone = TimeZone.current
        return f
    }
}
