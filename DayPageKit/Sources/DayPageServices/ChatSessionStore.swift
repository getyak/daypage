import Foundation
import DayPageStorage

// MARK: - ChatEntryKind

/// 会话的进入方式。三个入口本质上是同一个 agent 带不同初始上下文启动
/// （对标 Claude Code：同一 transcript 机制，不同启动 prompt），因此
/// entry 只是 session header 里的元数据，不是存储的分类轴。
public enum ChatEntryKind: String, Codable, Sendable {
    case ask      // 通用「问过去」（AskPastView）
    case memo     // memo 锚定对话（MemoChatView）
    case coach    // 陪写教练（TodayCoachView，Wave C 接入）
}

// MARK: - ChatSessionRef / Summary

/// 一段活跃会话的句柄：追加事件只需要它。
public struct ChatSessionRef: Equatable, Sendable {
    public let id: UUID
    public let fileURL: URL

    public init(id: UUID, fileURL: URL) {
        self.id = id
        self.fileURL = fileURL
    }
}

/// 历史列表里的一行胶囊。由 header 行 + 轻量行扫描构成，不做全量 JSON decode。
public struct ChatSessionSummary: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let entry: ChatEntryKind
    public let title: String
    public let startedAt: Date
    /// 会话开始日（本地时区 yyyy-MM-dd）——即所在目录名。
    public let dayString: String
    public let turnCount: Int
    public let isClosed: Bool
    public let anchorMemoID: UUID?
    public let anchorMemoDate: String?
    public let fileURL: URL

    public var ref: ChatSessionRef { ChatSessionRef(id: id, fileURL: fileURL) }
}

/// resume / 展开胶囊时的完整载入结果。
public struct LoadedChatSession: Equatable {
    public let summary: ChatSessionSummary
    public let turns: [ChatTurn]
}

// MARK: - ChatEventLine (on-disk envelope)

/// JSONL 单行信封。所有事件（含首行 header）共用一个扁平结构，未知
/// `type` / 缺字段一律跳过——向前兼容即免迁移。字段按事件类型分组：
/// - `session`（首行）：v/id/entry/startedAt/title/anchorMemoID/anchorMemoDate
/// - `turn`：id/role/text/createdAt/memoDraft
/// - `retrieval`：memoDates/entities（实体存显示名，导出可读）
/// - `anchor`：action（attach/detach）
/// - `closed`：at
struct ChatEventLine: Codable {
    var v: Int?
    var type: String
    var id: UUID?
    var entry: String?
    var startedAt: Date?
    var title: String?
    var anchorMemoID: UUID?
    var anchorMemoDate: String?
    var role: String?
    var text: String?
    var createdAt: Date?
    var memoDraft: String?
    var memoDates: [String]?
    var entities: [String]?
    var at: Date?
    var action: String?
}

// MARK: - ChatSessionStore

/// AI 对话的统一落盘层：一段会话 = 一个追加式 JSONL 事件日志，
/// 按日期目录归档（`vault/wiki/chats/YYYY-MM-DD/HHmmss.jsonl`）。
///
/// 设计对标 Claude Code 的 session/transcript 机制：
/// - 「新对话」= append `closed` 事件（/clear）——不改写文件、不引外部状态；
/// - 打开聊天接上今天最近未封口会话（--continue）；
/// - 历史胶囊点开续聊（/resume），新轮次 append 回原文件。
///
/// 全部为 nonisolated 静态函数 + 值类型返回：调用方（@MainActor service）
/// 的 append 是小写入；测试直接打临时 root。写入 best-effort——丢一行
/// 好过阻塞 UI（沿用 MemoryChatService.appendTurn 的既有取舍）。
public enum ChatSessionStore {

    /// 生产根目录。跟随 `VaultInitializer.vaultURL`（含 test override）。
    public static var defaultRootURL: URL {
        VaultInitializer.vaultURL.appendingPathComponent("wiki/chats", isDirectory: true)
    }

    // MARK: - Create / Append / Close

    /// 建立新会话文件并写入 header 行。只在第一轮真正发出时调用——
    /// 空会话永不落盘。`title` 取首问截断（≤40 字符）。
    public static func createSession(
        entry: ChatEntryKind,
        title: String,
        anchorMemoID: UUID? = nil,
        anchorMemoDate: String? = nil,
        now: Date = Date(),
        root: URL = defaultRootURL
    ) -> ChatSessionRef? {
        let fm = FileManager.default
        let dayDir = root.appendingPathComponent(Self.dayString(for: now), isDirectory: true)
        do {
            try fm.createDirectory(at: dayDir, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        // HHmmss 命名；同秒撞名追加 -2 / -3 …（同秒覆盖丢数据的教训来自 memo 附件侧）
        let base = Self.timeString(for: now)
        var fileURL = dayDir.appendingPathComponent("\(base).jsonl")
        var attempt = 2
        while fm.fileExists(atPath: fileURL.path) {
            fileURL = dayDir.appendingPathComponent("\(base)-\(attempt).jsonl")
            attempt += 1
        }

        let id = UUID()
        var header = ChatEventLine(type: "session")
        header.v = 1
        header.id = id
        header.entry = entry.rawValue
        header.startedAt = now
        header.title = String(title.prefix(40))
        header.anchorMemoID = anchorMemoID
        header.anchorMemoDate = anchorMemoDate

        guard var data = try? Self.encoder.encode(header) else { return nil }
        data.append(0x0A)
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            return nil
        }
        return ChatSessionRef(id: id, fileURL: fileURL)
    }

    /// 追加一轮对话。`memoDraft` 仅 coach 会话使用。
    public static func appendTurn(_ turn: ChatTurn, memoDraft: String? = nil, to ref: ChatSessionRef) {
        var line = ChatEventLine(type: "turn")
        line.id = turn.id
        line.role = turn.role.rawValue
        line.text = turn.text
        line.createdAt = turn.createdAt
        line.memoDraft = memoDraft
        appendLine(line, to: ref.fileURL)
    }

    /// 追加一次检索事件（agent 的工具调用留痕）。回放时合成来源 chips，
    /// 导出时渲染成「依据」行。`entities` 存显示名而非 slug——导出件可读。
    public static func appendRetrieval(memoDates: [String], entities: [String], to ref: ChatSessionRef) {
        guard !memoDates.isEmpty || !entities.isEmpty else { return }
        var line = ChatEventLine(type: "retrieval")
        line.memoDates = memoDates
        line.entities = entities
        appendLine(line, to: ref.fileURL)
    }

    /// 封口（/clear 语义）。之后该会话不再被 --continue 接上；
    /// 从历史胶囊续聊时仍可 append（closed 只影响 resume 选择）。
    public static func close(_ ref: ChatSessionRef) {
        var line = ChatEventLine(type: "closed")
        line.at = Date()
        appendLine(line, to: ref.fileURL)
    }

    // MARK: - Resume (--continue)

    /// 接上「今天」最近一段未封口、entry 匹配的会话；memo 锚定对话还要求
    /// anchorMemoID 一致（反复进出同一条 memo 不碎片化）。没有则返回 nil。
    public static func resumeTodaySession(
        entry: ChatEntryKind,
        anchorMemoID: UUID? = nil,
        now: Date = Date(),
        root: URL = defaultRootURL
    ) -> LoadedChatSession? {
        migrateLegacyDayFilesIfNeeded(root: root)
        let dayDir = root.appendingPathComponent(Self.dayString(for: now), isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dayDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return nil }

        // 文件名即开始时间 → 逆序 = 最近优先。
        let candidates = files
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }

        for fileURL in candidates {
            guard let summary = summarize(fileURL: fileURL) else { continue }
            guard summary.entry == entry, !summary.isClosed else { continue }
            if entry == .memo, summary.anchorMemoID != anchorMemoID { continue }
            return load(summary: summary)
        }
        return nil
    }

    // MARK: - List / Load / Delete

    /// 扫描历史会话，按开始时间降序。`limitDays` 限制只看最近 N 个自然日
    /// 目录（长河懒加载用）；nil = 全量。每个文件只做 header decode +
    /// 轻量行扫描（turn 计数 / closed 检测），不整段 decode。
    public static func listSessions(limitDays: Int? = nil, root: URL = defaultRootURL) -> [ChatSessionSummary] {
        migrateLegacyDayFilesIfNeeded(root: root)
        let fm = FileManager.default
        guard let dayDirs = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
        ) else { return [] }

        var days = dayDirs
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        if let limitDays { days = Array(days.prefix(limitDays)) }

        var summaries: [ChatSessionSummary] = []
        for dayDir in days {
            guard let files = try? fm.contentsOfDirectory(
                at: dayDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
            ) else { continue }
            for fileURL in files where fileURL.pathExtension == "jsonl" {
                if let summary = summarize(fileURL: fileURL) {
                    summaries.append(summary)
                }
            }
        }
        return summaries.sorted { $0.startedAt > $1.startedAt }
    }

    /// 会话日目录总数（长河「更早的对话」按钮的 hasMore 判据——比全量
    /// header 扫描更廉价）。
    public static func dayDirectoryCount(root: URL = defaultRootURL) -> Int {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
        ) else { return 0 }
        return entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }.count
    }

    /// 由活跃会话句柄取回 summary（当前会话的「导出本次对话」入口用）。
    public static func summary(for ref: ChatSessionRef) -> ChatSessionSummary? {
        summarize(fileURL: ref.fileURL)
    }

    /// 整段载入一段会话（展开胶囊 / 续聊）。retrieval 事件被折进下一条
    /// assistant turn 的合成 context——chips 需要的只有日期与实体显示名。
    public static func load(summary: ChatSessionSummary) -> LoadedChatSession? {
        guard let text = try? String(contentsOf: summary.fileURL, encoding: .utf8) else { return nil }

        var turns: [ChatTurn] = []
        var pendingRetrieval: (dates: [String], entities: [String])?

        for line in text.split(whereSeparator: \.isNewline) {
            guard let event = try? Self.decoder.decode(ChatEventLine.self, from: Data(line.utf8)) else { continue }
            switch event.type {
            case "turn":
                guard let roleRaw = event.role,
                      let role = ChatTurn.Role(rawValue: roleRaw),
                      let turnText = event.text else { continue }
                var turn = ChatTurn(
                    id: event.id ?? UUID(),
                    role: role,
                    text: turnText,
                    createdAt: event.createdAt ?? summary.startedAt
                )
                if role == .assistant, let retrieval = pendingRetrieval {
                    turn.context = Self.syntheticContext(dates: retrieval.dates, entities: retrieval.entities)
                    pendingRetrieval = nil
                }
                turns.append(turn)
            case "retrieval":
                pendingRetrieval = (event.memoDates ?? [], event.entities ?? [])
            default:
                continue // session header / anchor / closed / 未来事件类型
            }
        }
        return LoadedChatSession(summary: summary, turns: turns)
    }

    /// 删除一段会话；所在日目录空了顺手删掉。
    public static func delete(_ summary: ChatSessionSummary) {
        let fm = FileManager.default
        try? fm.removeItem(at: summary.fileURL)
        let dayDir = summary.fileURL.deletingLastPathComponent()
        if let remaining = try? fm.contentsOfDirectory(atPath: dayDir.path), remaining.isEmpty {
            try? fm.removeItem(at: dayDir)
        }
    }

    // MARK: - Legacy migration

    /// 把 session 化之前的顶层天文件（`wiki/chats/YYYY-MM-DD.jsonl`，一天
    /// 一文件、无边界）升级为该日目录下的单段已封口会话
    /// （`YYYY-MM-DD/000000.jsonl`）。幂等：目标存在则只清理源文件；
    /// 每进程只全量检查一次（之后顶层不会再出现天文件）。
    public static func migrateLegacyDayFiles(root: URL = defaultRootURL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
        ) else { return }

        for fileURL in entries {
            let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard !isDir, fileURL.pathExtension == "jsonl" else { continue }
            let day = fileURL.deletingPathExtension().lastPathComponent
            guard Self.isDayString(day) else { continue }

            let dayDir = root.appendingPathComponent(day, isDirectory: true)
            let target = dayDir.appendingPathComponent("000000.jsonl")

            if fm.fileExists(atPath: target.path) {
                // 上次迁移在删除源文件前中断——目标已完整（atomic 写入），直接清理。
                try? fm.removeItem(at: fileURL)
                continue
            }

            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            var turnLines: [ChatEventLine] = []
            for line in text.split(whereSeparator: \.isNewline) {
                guard let turn = try? Self.decoder.decode(ChatTurn.self, from: Data(line.utf8)) else { continue }
                var event = ChatEventLine(type: "turn")
                event.id = turn.id
                event.role = turn.role.rawValue
                event.text = turn.text
                event.createdAt = turn.createdAt
                turnLines.append(event)
            }

            let firstUser = turnLines.first { $0.role == ChatTurn.Role.user.rawValue }
            let startedAt = turnLines.first?.createdAt ?? Self.dayFormatter.date(from: day) ?? Date()

            var header = ChatEventLine(type: "session")
            header.v = 1
            header.id = UUID()
            header.entry = ChatEntryKind.ask.rawValue
            header.startedAt = startedAt
            header.title = String((firstUser?.text ?? "对话").prefix(40))

            var closed = ChatEventLine(type: "closed")
            closed.at = startedAt

            var lines: [Data] = []
            for event in [header] + turnLines + [closed] {
                guard let data = try? Self.encoder.encode(event) else { continue }
                lines.append(data)
            }
            var blob = Data()
            for data in lines {
                blob.append(data)
                blob.append(0x0A)
            }

            do {
                try fm.createDirectory(at: dayDir, withIntermediateDirectories: true)
                try blob.write(to: target, options: .atomic)
                try fm.removeItem(at: fileURL)
            } catch {
                continue // 下次启动重试；atomic 写入保证不留半成品
            }
        }
    }

    /// 每进程一次的惰性触发。list / resume 是仅有的两个读入口，都会先过这里。
    private static let migrationOnce = OnceFlag()
    static func migrateLegacyDayFilesIfNeeded(root: URL) {
        // 测试用非默认 root 时不走进程级去重，保证迁移单测可重复执行。
        if root != defaultRootURL {
            migrateLegacyDayFiles(root: root)
            return
        }
        guard migrationOnce.tryClaim() else { return }
        migrateLegacyDayFiles(root: root)
    }

    // MARK: - Private helpers

    private static func summarize(fileURL: URL) -> ChatSessionSummary? {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        var headerLine: Substring?
        var turnCount = 0
        var isClosed = false
        for line in text.split(whereSeparator: \.isNewline) {
            if headerLine == nil {
                headerLine = line
                continue
            }
            // 轻量扫描：不整行 decode，子串判断足够（key 由本文件自己序列化）。
            if line.contains("\"type\":\"turn\"") { turnCount += 1 }
            else if line.contains("\"type\":\"closed\"") { isClosed = true }
        }
        guard let headerLine,
              let header = try? Self.decoder.decode(ChatEventLine.self, from: Data(headerLine.utf8)),
              header.type == "session",
              let id = header.id,
              let entryRaw = header.entry,
              let entry = ChatEntryKind(rawValue: entryRaw),
              let startedAt = header.startedAt else { return nil }

        return ChatSessionSummary(
            id: id,
            entry: entry,
            title: header.title ?? "对话",
            startedAt: startedAt,
            dayString: fileURL.deletingLastPathComponent().lastPathComponent,
            turnCount: turnCount,
            isClosed: isClosed,
            anchorMemoID: header.anchorMemoID,
            anchorMemoDate: header.anchorMemoDate,
            fileURL: fileURL
        )
    }

    private static func appendLine(_ event: ChatEventLine, to fileURL: URL) {
        guard var data = try? Self.encoder.encode(event) else { return }
        data.append(0x0A)
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            // 会话文件被外部删除（如用户在 Files.app 里清理）——重建为孤行文件
            // 好过静默丢失本轮。
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// 回放/导出只需要日期与实体显示名——合成一个轻量 context 喂给
    /// 既有 chips UI（`chipLabels` 只读 dateString / displayName）。
    static func syntheticContext(dates: [String], entities: [String]) -> RetrievedContext {
        RetrievedContext(
            query: "",
            memoHits: dates.map {
                .init(dateString: $0, snippet: "", mood: nil, entityMentions: [])
            },
            entityHits: entities.map {
                .init(slug: $0, displayName: $0, type: "themes", occurrenceCount: 0, summary: "")
            }
        )
    }

    // MARK: - Formatting

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func dayString(for date: Date) -> String {
        Self.dayFormatter.string(from: date)
    }

    private static func timeString(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HHmmss"
        f.timeZone = TimeZone.current
        return f.string(from: date)
    }

    private static var dayFormatter: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f
    }

    private static func isDayString(_ s: String) -> Bool {
        s.count == 10 && Self.dayFormatter.date(from: s) != nil
    }
}

// MARK: - OnceFlag

/// 线程安全的一次性闸门（进程级迁移去重用）。
private final class OnceFlag: @unchecked Sendable {
    private var claimed = false
    private let lock = NSLock()
    func tryClaim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
