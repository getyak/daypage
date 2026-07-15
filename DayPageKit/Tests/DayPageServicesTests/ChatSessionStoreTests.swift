import Testing
import Foundation
@testable import DayPageServices

// MARK: - Helpers

/// 每个测试独立的临时 chats root，避免共享 vault 状态。
private func makeTempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("chat-store-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("ChatSessionStore")
struct ChatSessionStoreTests {

    // MARK: - Create / append / load roundtrip

    @Test func createAppendLoadRoundtrip() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let longTitle = String(repeating: "我最近的情绪有什么变化？", count: 5)  // 60 字符
        let ref = try #require(ChatSessionStore.createSession(
            entry: .ask,
            title: longTitle,
            root: root
        ))

        let user = ChatTurn(role: .user, text: "我最近的情绪有什么变化？")
        ChatSessionStore.appendTurn(user, to: ref)
        ChatSessionStore.appendRetrieval(
            memoDates: ["2026-03-14", "2026-05-02"],
            entities: ["清迈"],
            to: ref
        )
        let assistant = ChatTurn(role: .assistant, text: "三月中你写到独处开始变得舒服。")
        ChatSessionStore.appendTurn(assistant, to: ref)

        let sessions = ChatSessionStore.listSessions(root: root)
        let summary = try #require(sessions.first)
        #expect(sessions.count == 1)
        #expect(summary.entry == .ask)
        #expect(summary.title.count == 40)  // 首问截断到 40 字符
        #expect(longTitle.hasPrefix(summary.title))
        #expect(summary.turnCount == 2)
        #expect(!summary.isClosed)

        let loaded = try #require(ChatSessionStore.load(summary: summary))
        #expect(loaded.turns.count == 2)
        #expect(loaded.turns[0].role == .user)
        #expect(loaded.turns[1].role == .assistant)
        // retrieval 事件折进下一条 assistant turn 的合成 context。
        let context = try #require(loaded.turns[1].context)
        #expect(context.memoHits.map { $0.dateString } == ["2026-03-14", "2026-05-02"])
        #expect(context.entityHits.map { $0.displayName } == ["清迈"])
        #expect(loaded.turns[0].context == nil)
    }

    @Test func fileLandsInDayDirectory() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let ref = try #require(ChatSessionStore.createSession(entry: .ask, title: "t", now: now, root: root))
        let dayDir = ref.fileURL.deletingLastPathComponent()
        #expect(dayDir.lastPathComponent == ChatSessionStore.dayString(for: now))
        #expect(dayDir.deletingLastPathComponent().path == root.path)
        #expect(ref.fileURL.pathExtension == "jsonl")
    }

    // MARK: - Same-second collision

    @Test func sameSecondCollisionGetsSuffix() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let a = try #require(ChatSessionStore.createSession(entry: .ask, title: "a", now: now, root: root))
        let b = try #require(ChatSessionStore.createSession(entry: .ask, title: "b", now: now, root: root))
        let c = try #require(ChatSessionStore.createSession(entry: .ask, title: "c", now: now, root: root))
        #expect(a.fileURL != b.fileURL)
        #expect(b.fileURL.lastPathComponent.hasSuffix("-2.jsonl"))
        #expect(c.fileURL.lastPathComponent.hasSuffix("-3.jsonl"))
        #expect(ChatSessionStore.listSessions(root: root).count == 3)
    }

    // MARK: - Resume (--continue)

    @Test func resumesLatestUnclosedMatchingEntry() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let earlier = Date().addingTimeInterval(-60)
        let old = try #require(ChatSessionStore.createSession(entry: .ask, title: "旧", now: earlier, root: root))
        ChatSessionStore.appendTurn(ChatTurn(role: .user, text: "旧问题"), to: old)
        ChatSessionStore.close(old)  // 封口 → 不应被接上

        let fresh = try #require(ChatSessionStore.createSession(entry: .ask, title: "新", now: Date(), root: root))
        ChatSessionStore.appendTurn(ChatTurn(role: .user, text: "新问题"), to: fresh)

        let resumed = try #require(ChatSessionStore.resumeTodaySession(entry: .ask, root: root))
        #expect(resumed.summary.id == fresh.id)
        #expect(resumed.turns.map { $0.text } == ["新问题"])
    }

    @Test func closedSessionIsNotResumed() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let ref = try #require(ChatSessionStore.createSession(entry: .ask, title: "t", root: root))
        ChatSessionStore.appendTurn(ChatTurn(role: .user, text: "q"), to: ref)
        ChatSessionStore.close(ref)

        #expect(ChatSessionStore.resumeTodaySession(entry: .ask, root: root) == nil)
    }

    @Test func memoResumeRequiresMatchingAnchor() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let memoA = UUID()
        let memoB = UUID()
        let ref = try #require(ChatSessionStore.createSession(
            entry: .memo, title: "锚定", anchorMemoID: memoA, anchorMemoDate: "2026-03-14", root: root
        ))
        ChatSessionStore.appendTurn(ChatTurn(role: .user, text: "q"), to: ref)

        // 同 memo → 接上；异 memo / 通用 ask → 不接。
        #expect(ChatSessionStore.resumeTodaySession(entry: .memo, anchorMemoID: memoA, root: root) != nil)
        #expect(ChatSessionStore.resumeTodaySession(entry: .memo, anchorMemoID: memoB, root: root) == nil)
        #expect(ChatSessionStore.resumeTodaySession(entry: .ask, root: root) == nil)

        let summary = try #require(ChatSessionStore.listSessions(root: root).first)
        #expect(summary.anchorMemoID == memoA)
        #expect(summary.anchorMemoDate == "2026-03-14")
    }

    // MARK: - Forward compatibility

    @Test func unknownEventTypesAreSkipped() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let ref = try #require(ChatSessionStore.createSession(entry: .ask, title: "t", root: root))
        ChatSessionStore.appendTurn(ChatTurn(role: .user, text: "q"), to: ref)

        // 手工注入未来事件类型与坏行——load / summarize 均不得炸。
        let handle = try FileHandle(forWritingTo: ref.fileURL)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data("""
        {"type":"future_event","payload":"whatever"}
        not-json-at-all
        {"type":"turn","role":"assistant","text":"a","createdAt":"2026-07-15T06:00:00Z"}

        """.utf8))

        let summary = try #require(ChatSessionStore.listSessions(root: root).first)
        #expect(summary.turnCount == 2)
        let loaded = try #require(ChatSessionStore.load(summary: summary))
        #expect(loaded.turns.map { $0.text } == ["q", "a"])
    }

    // MARK: - Delete

    @Test func deleteRemovesFileAndEmptyDayDir() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let ref = try #require(ChatSessionStore.createSession(entry: .ask, title: "t", root: root))
        let summary = try #require(ChatSessionStore.listSessions(root: root).first)
        ChatSessionStore.delete(summary)

        #expect(!FileManager.default.fileExists(atPath: ref.fileURL.path))
        #expect(!FileManager.default.fileExists(atPath: ref.fileURL.deletingLastPathComponent().path))
        #expect(ChatSessionStore.listSessions(root: root).isEmpty)
    }

    // MARK: - List ordering

    @Test func listSessionsSortsNewestFirstAndHonorsLimitDays() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let yesterday = now.addingTimeInterval(-86_400)
        _ = ChatSessionStore.createSession(entry: .ask, title: "昨", now: yesterday, root: root)
        _ = ChatSessionStore.createSession(entry: .ask, title: "今", now: now, root: root)

        let all = ChatSessionStore.listSessions(root: root)
        #expect(all.map { $0.title } == ["今", "昨"])

        let recent = ChatSessionStore.listSessions(limitDays: 1, root: root)
        #expect(recent.map { $0.title } == ["今"])
    }
}

// MARK: - Legacy migration

@Suite("ChatSessionStore legacy migration")
struct ChatSessionStoreMigrationTests {

    /// 旧格式：顶层天文件，逐行 ChatTurn（无 header / type 字段）。
    private func writeLegacyDayFile(day: String, root: URL) throws -> URL {
        let legacy = root.appendingPathComponent("\(day).jsonl")
        try Data("""
        {"id":"\(UUID().uuidString)","role":"user","text":"去年这个时候我在做什么","createdAt":"\(day)T02:00:00Z"}
        {"id":"\(UUID().uuidString)","role":"assistant","text":"你在清迈。","createdAt":"\(day)T02:00:05Z"}

        """.utf8).write(to: legacy, options: .atomic)
        return legacy
    }

    @Test func migratesLegacyDayFileIntoClosedSession() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let legacy = try writeLegacyDayFile(day: "2026-06-01", root: root)
        ChatSessionStore.migrateLegacyDayFiles(root: root)

        // 源文件删除，目标落在日目录下。
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        let target = root.appendingPathComponent("2026-06-01/000000.jsonl")
        #expect(FileManager.default.fileExists(atPath: target.path))

        let summary = try #require(ChatSessionStore.listSessions(root: root).first)
        #expect(summary.entry == .ask)
        #expect(summary.title == "去年这个时候我在做什么")  // 首条 user 轮
        #expect(summary.turnCount == 2)
        #expect(summary.isClosed)  // 旧数据如实算作已封口的无边界会话

        let loaded = try #require(ChatSessionStore.load(summary: summary))
        #expect(loaded.turns.map { $0.text } == ["去年这个时候我在做什么", "你在清迈。"])
    }

    @Test func migrationIsIdempotent() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try writeLegacyDayFile(day: "2026-06-01", root: root)
        ChatSessionStore.migrateLegacyDayFiles(root: root)
        // 第二次：目标已在、源已删——不得重复/损坏。
        ChatSessionStore.migrateLegacyDayFiles(root: root)
        #expect(ChatSessionStore.listSessions(root: root).count == 1)

        // 中断恢复：目标已在但源文件残留 → 只清理源，不覆盖目标。
        let legacyAgain = try writeLegacyDayFile(day: "2026-06-01", root: root)
        ChatSessionStore.migrateLegacyDayFiles(root: root)
        #expect(!FileManager.default.fileExists(atPath: legacyAgain.path))
        let summary = try #require(ChatSessionStore.listSessions(root: root).first)
        #expect(summary.turnCount == 2)
    }

    @Test func listTriggersLegacyMigrationForNonDefaultRoot() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try writeLegacyDayFile(day: "2026-05-20", root: root)
        // 不显式调迁移——listSessions 惰性触发。
        let sessions = ChatSessionStore.listSessions(root: root)
        #expect(sessions.count == 1)
        #expect(sessions.first?.isClosed == true)
    }

    @Test func nonDayNamedJSONLFilesAreLeftAlone() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let stray = root.appendingPathComponent("notes.jsonl")
        try Data("{}".utf8).write(to: stray, options: .atomic)
        ChatSessionStore.migrateLegacyDayFiles(root: root)
        #expect(FileManager.default.fileExists(atPath: stray.path))
    }
}
