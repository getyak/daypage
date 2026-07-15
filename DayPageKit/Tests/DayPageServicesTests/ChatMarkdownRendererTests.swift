import Testing
import Foundation
@testable import DayPageServices

@Suite("ChatMarkdownRenderer")
struct ChatMarkdownRendererTests {

    private func makeSession() -> LoadedChatSession {
        let iso = ISO8601DateFormatter()
        let startedAt = iso.date(from: "2026-07-15T06:32:00Z")!
        let summary = ChatSessionSummary(
            id: UUID(),
            entry: .memo,
            title: "这段时间我对独居的看法变了吗",
            startedAt: startedAt,
            dayString: "2026-07-15",
            turnCount: 2,
            isClosed: true,
            anchorMemoID: UUID(),
            anchorMemoDate: "2026-03-14",
            fileURL: URL(fileURLWithPath: "/tmp/x.jsonl")
        )
        var assistant = ChatTurn(role: .assistant, text: "三月中你写到独处开始变得舒服。", createdAt: startedAt)
        assistant.context = ChatSessionStore.syntheticContext(
            dates: ["2026-03-14", "2026-05-02"],
            entities: ["清迈"]
        )
        return LoadedChatSession(summary: summary, turns: [
            ChatTurn(role: .user, text: "这段时间我对独居的看法变了吗", createdAt: startedAt),
            assistant,
        ])
    }

    @Test func rendersFrontmatterBodyAndSources() {
        let md = ChatMarkdownRenderer.render(makeSession())

        // YAML front-matter
        #expect(md.hasPrefix("---\n"))
        #expect(md.contains("type: chat_session"))
        #expect(md.contains("date: 2026-07-15"))
        #expect(md.contains("entry: 记忆锚定"))
        #expect(md.contains("anchor_memo_date: 2026-03-14"))
        #expect(md.contains("turns: 2"))
        #expect(md.contains("export_source: DayPage"))

        // 正文：角色 + 文本
        #expect(md.contains("**我**"))
        #expect(md.contains("**DayPage**"))
        #expect(md.contains("这段时间我对独居的看法变了吗"))
        #expect(md.contains("三月中你写到独处开始变得舒服。"))

        // 依据行：日期渲染成 wikilink、实体显示名直出
        #expect(md.contains("> 依据：[[2026-03-14]] · [[2026-05-02]] · 清迈"))
    }

    @Test func exportFileNameMatchesMemoNamingFamily() {
        let name = ChatMarkdownRenderer.exportFileName(for: makeSession().summary)
        #expect(name.hasPrefix("DayPage Chat 2026-07-15 "))
        #expect(name.hasSuffix(".md"))
    }

    @Test func entryLabels() {
        #expect(ChatMarkdownRenderer.entryLabel(.ask) == "问过去")
        #expect(ChatMarkdownRenderer.entryLabel(.memo) == "记忆锚定")
        #expect(ChatMarkdownRenderer.entryLabel(.coach) == "陪写")
    }
}
