// ReminderIntentParserTests.swift — 自然语言 → 提醒调度解析
//
// 覆盖(全部纯函数,注入固定 now/calendar):
//   * 提醒动词门:无「提醒/remind」不触发
//   * 重复:每天 / 工作日 / 周末 / 周一三五组合(缺时分 → nil 追问)
//   * 一次:N 分钟/小时后 / 半小时后 / 今晚 / 明早 / 明晚 / 明天+时分 / 裸时分顺延
//   * 时分:HH:mm / N点半 / 晚上 10 点(12h 换算)/ 中文数字(十点/八点)
//   * 过去时刻拒绝(今晚 8 点但已 21 点 → nil)
//   * 标签萃取:「今晚提醒我复盘」→「复盘」;纯时间无标签 → 空串
//   * 英文基础:remind me in an hour / tonight / every day at 22:00

import Testing
import Foundation
@testable import DayPage

struct ReminderIntentParserTests {

    /// 固定基准:2026-07-15(周三)14:00 本地时区。
    private var now: Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 7; comps.day = 15
        comps.hour = 14; comps.minute = 0
        return Calendar.current.date(from: comps)!
    }

    private func parse(_ text: String) -> ParsedReminder? {
        ReminderIntentParser.parse(text, now: now, calendar: .current)
    }

    private func hourMinute(_ date: Date) -> (Int, Int) {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? -1, c.minute ?? -1)
    }

    // MARK: - 动词门

    @Test func noReminderVerb_returnsNil() {
        #expect(parse("每天 22:00 写日记") == nil)
        #expect(parse("今晚复盘一下") == nil)
    }

    @Test func verbWithoutTime_returnsNil() {
        #expect(parse("提醒我复盘") == nil)
        #expect(parse("记得叫我") == nil)
    }

    // MARK: - 重复

    @Test func daily_withClockTime() throws {
        let r = try #require(parse("每天 22:00 提醒我写日记"))
        #expect(r.trigger == .daily(hour: 22, minute: 0))
        #expect(r.label == "写日记")
    }

    @Test func daily_chineseEveningNumeral() throws {
        let r = try #require(parse("每天晚上十点提醒我"))
        #expect(r.trigger == .daily(hour: 22, minute: 0))
    }

    @Test func weekdaysPreset() throws {
        let r = try #require(parse("工作日 9 点提醒我晨记"))
        #expect(r.trigger == .weekdays(days: [2, 3, 4, 5, 6], hour: 9, minute: 0))
        #expect(r.label == "晨记")
    }

    @Test func weekendPreset() throws {
        let r = try #require(parse("周末早上 8 点提醒我"))
        #expect(r.trigger == .weekdays(days: [1, 7], hour: 8, minute: 0))
    }

    @Test func weekdayCombo_monWedFri() throws {
        let r = try #require(parse("周一三五 9 点提醒我晨记"))
        #expect(r.trigger == .weekdays(days: [2, 4, 6], hour: 9, minute: 0))
    }

    @Test func repeat_withoutClock_asksBack() {
        #expect(parse("每天提醒我写日记") == nil)
    }

    @Test func daily_english() throws {
        let r = try #require(parse("remind me every day at 22:00"))
        #expect(r.trigger == .daily(hour: 22, minute: 0))
    }

    // MARK: - 相对间隔

    @Test func afterOneHour() throws {
        let r = try #require(parse("一小时后提醒我"))
        guard case .once(let date) = r.trigger else {
            Issue.record("expected .once"); return
        }
        #expect(abs(date.timeIntervalSince(now) - 3600) < 1)
    }

    @Test func afterThirtyMinutes() throws {
        let r = try #require(parse("30 分钟后提醒我取快递"))
        guard case .once(let date) = r.trigger else {
            Issue.record("expected .once"); return
        }
        #expect(abs(date.timeIntervalSince(now) - 1800) < 1)
        #expect(r.label == "取快递")
    }

    @Test func afterHalfHour() throws {
        let r = try #require(parse("半小时后提醒我"))
        guard case .once(let date) = r.trigger else {
            Issue.record("expected .once"); return
        }
        #expect(abs(date.timeIntervalSince(now) - 1800) < 1)
    }

    @Test func english_inAnHour() throws {
        let r = try #require(parse("remind me in an hour"))
        guard case .once(let date) = r.trigger else {
            Issue.record("expected .once"); return
        }
        #expect(abs(date.timeIntervalSince(now) - 3600) < 1)
    }

    // MARK: - 相对日词

    @Test func tonight_defaultsToEight() throws {
        let r = try #require(parse("今晚提醒我复盘"))
        guard case .once(let date) = r.trigger else {
            Issue.record("expected .once"); return
        }
        #expect(hourMinute(date) == (20, 0))
        #expect(Calendar.current.isDate(date, inSameDayAs: now))
        #expect(r.label == "复盘")
    }

    @Test func tomorrowMorning_defaultsToEight() throws {
        let r = try #require(parse("明早提醒我"))
        guard case .once(let date) = r.trigger else {
            Issue.record("expected .once"); return
        }
        #expect(hourMinute(date) == (8, 0))
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        #expect(Calendar.current.isDate(date, inSameDayAs: tomorrow))
    }

    @Test func tomorrowWithExplicitClock() throws {
        let r = try #require(parse("明天下午 3 点提醒我取快递"))
        guard case .once(let date) = r.trigger else {
            Issue.record("expected .once"); return
        }
        #expect(hourMinute(date) == (15, 0))
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        #expect(Calendar.current.isDate(date, inSameDayAs: tomorrow))
        #expect(r.label == "取快递")
    }

    @Test func bareTomorrow_withoutClock_asksBack() {
        #expect(parse("明天提醒我") == nil)
    }

    @Test func pastMomentToday_rejected() {
        // now = 14:00,「今天上午 10 点」已过 → nil(追问,不猜)。
        #expect(parse("今天上午 10 点提醒我") == nil)
    }

    // MARK: - 裸时分

    @Test func bareClock_futureToday() throws {
        let r = try #require(parse("18 点提醒我下班买菜"))
        guard case .once(let date) = r.trigger else {
            Issue.record("expected .once"); return
        }
        #expect(hourMinute(date) == (18, 0))
        #expect(Calendar.current.isDate(date, inSameDayAs: now))
    }

    @Test func bareClock_pastRollsToTomorrow() throws {
        // now = 14:00,「10 点」已过 → 顺延到明天(RelativeTimeResolver .at 语义)。
        let r = try #require(parse("10 点提醒我"))
        guard case .once(let date) = r.trigger else {
            Issue.record("expected .once"); return
        }
        #expect(hourMinute(date) == (10, 0))
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        #expect(Calendar.current.isDate(date, inSameDayAs: tomorrow))
    }

    @Test func halfPastClock() throws {
        let r = try #require(parse("晚上 9 点半提醒我"))
        guard case .once(let date) = r.trigger else {
            Issue.record("expected .once"); return
        }
        #expect(hourMinute(date) == (21, 30))
    }

    // MARK: - 标签

    @Test func labelEmpty_whenPureTime() throws {
        let r = try #require(parse("一小时后提醒我"))
        #expect(r.label.isEmpty)
    }

    @Test func labelStripsNoiseWords() throws {
        let r = try #require(parse("今晚提醒我去复盘一下项目"))
        #expect(r.label.contains("复盘"))
        #expect(!r.label.contains("提醒"))
        #expect(!r.label.contains("今晚"))
    }
}
