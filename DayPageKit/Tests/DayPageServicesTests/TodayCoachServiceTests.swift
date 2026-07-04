import XCTest
@testable import DayPageServices

/// Issue #804 — Coach 系统 prompt / 上下文注入 / JSON 解析 / draft 缺失兜底。
final class TodayCoachServiceTests: XCTestCase {

    // MARK: - Prompt assembly

    @MainActor
    func test_buildMessages_puts_context_in_system_role() async {
        let ctx = TodayCoachContext(
            localDate: "2026-07-04",
            timeOfDay: "evening",
            todayMemoSnippets: ["#工作 又开了一个 issue，被 review 挑刺"],
            todayTags: ["#工作"]
        )
        let svc = TodayCoachService(context: ctx, send: { _ in "{\"reply\":\"ok\",\"memoDraft\":\"ok\"}" })
        let msgs = svc.buildMessages(userText: "有点烦")

        let systems = msgs.filter { $0.role == .system }
        XCTAssertGreaterThanOrEqual(systems.count, 2)

        let ctxBlock = systems[1].content
        XCTAssertTrue(ctxBlock.contains("evening"))
        XCTAssertTrue(ctxBlock.contains("2026-07-04"))
        XCTAssertTrue(ctxBlock.contains("又开了一个 issue"))
        XCTAssertTrue(ctxBlock.contains("#工作"))
    }

    @MainActor
    func test_buildMessages_empty_today_marks_no_memo_yet() {
        let ctx = TodayCoachContext(
            localDate: "2026-07-04",
            timeOfDay: "morning",
            todayMemoSnippets: [],
            todayTags: []
        )
        let svc = TodayCoachService(context: ctx, send: { _ in "" })
        let ctxBlock = svc.buildMessages(userText: "我不知道想做什么").filter { $0.role == .system }[1].content
        XCTAssertTrue(ctxBlock.contains("还没有 memo"))
    }

    // MARK: - System prompt behavioral guarantees

    func test_systemPrompt_forbids_RAG_language() {
        let p = TodayCoachService.systemPrompt
        XCTAssertTrue(p.contains("不检索历史"))
        XCTAssertTrue(p.contains("只问一个问题"))
        XCTAssertTrue(p.contains("必须给 memoDraft"))
        XCTAssertTrue(p.contains("JSON"))
    }

    // MARK: - Response parsing

    func test_parseResponse_strict_json() {
        let raw = "{\"reply\":\"更像是脑子乱吗？\",\"memoDraft\":\"此刻脑子有点乱，不确定从哪开始。\"}"
        let out = TodayCoachService.parseResponse(raw, userFallback: "脑子乱")
        XCTAssertEqual(out.reply, "更像是脑子乱吗？")
        XCTAssertEqual(out.memoDraft, "此刻脑子有点乱，不确定从哪开始。")
    }

    func test_parseResponse_tolerates_code_fence() {
        let raw = "```json\n{\"reply\":\"要不要说说白天最累的是什么？\",\"memoDraft\":\"晚上有点累，说不清是身体还是脑子。\"}\n```"
        let out = TodayCoachService.parseResponse(raw, userFallback: "有点累")
        XCTAssertEqual(out.reply, "要不要说说白天最累的是什么？")
        XCTAssertEqual(out.memoDraft, "晚上有点累，说不清是身体还是脑子。")
    }

    func test_parseResponse_missing_memoDraft_returns_nil_draft() {
        let raw = "{\"reply\":\"嗯，我在。\",\"memoDraft\":\"\"}"
        let out = TodayCoachService.parseResponse(raw, userFallback: "随便写点")
        XCTAssertEqual(out.reply, "嗯，我在。")
        XCTAssertNil(out.memoDraft)
    }

    func test_parseResponse_invalid_json_falls_back_to_raw_and_userFallback() {
        let raw = "更像是身体累、脑子乱，还是事情太多？"
        let out = TodayCoachService.parseResponse(raw, userFallback: "累")
        XCTAssertEqual(out.reply, raw)
        XCTAssertEqual(out.memoDraft, "累")
    }

    // MARK: - Hashtag extraction

    func test_extractHashtags_zh_and_en_mixed() {
        let tags = TodayCoachContext.extractHashtags("#工作 又忙到十点，还得 review PR #frontend fix")
        XCTAssertEqual(tags, ["#工作", "#frontend"])
    }

    // MARK: - Snapshot band mapping

    @MainActor
    func test_snapshot_band_mapping() {
        let cal = Calendar.current
        func band(hour: Int) -> String {
            let d = cal.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
            return TodayCoachContext.snapshotForToday(now: d).timeOfDay
        }
        XCTAssertEqual(band(hour: 8), "morning")
        XCTAssertEqual(band(hour: 14), "afternoon")
        XCTAssertEqual(band(hour: 20), "evening")
        XCTAssertEqual(band(hour: 2), "late_night")
    }
}
