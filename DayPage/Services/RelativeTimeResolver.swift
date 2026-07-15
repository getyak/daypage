import Foundation

// MARK: - RelativeTimeResolver
//
// 把「一小时后 / 今晚 / 明早」这类相对时间语义解析成绝对触发时间点(Date)。
// UI 的「稍后提醒」快捷 chips 和 AI 意图解析都调它 —— 单一事实源,避免两处
// 各写一套「今晚是几点」的口径分叉。
//
// 语义约定(可被产品调):
//   • tonight        今晚 → 当天 20:00;若已过则不顺延(返回过去时刻由调用方过滤)
//   • tomorrowMorning明早 → 次日 08:00
//   • tomorrowNight  明晚 → 次日 20:00
//   • afterInterval  相对秒数(如 +3600 = 一小时后)
//   • at             具体时分(今天该时分,已过则明天)
//   • absolute       AI 已给出的绝对 Date,原样透传
//
// 纯静态、无副作用;传入 `now`/`calendar` 便于测试。

enum RelativeTimeResolver {

    /// 支持的相对时间 token。AI 意图 JSON 的 `relative` 字段映射到这里。
    enum Token: Equatable {
        case tonight
        case tomorrowMorning
        case tomorrowNight
        case afterSeconds(TimeInterval)
        case at(hour: Int, minute: Int)
        case absolute(Date)
    }

    /// 今晚的钟点(20:00)。集中成常量,UI 文案与解析共用。
    static let eveningHour = 20
    /// 明早的钟点(08:00)。
    static let morningHour = 8

    /// 解析成绝对触发时间点。返回 nil 表示无法解析(调用方回退)。
    /// 注意:一次性提醒若解析出的时间点已过(如 22:00 说「今晚」),
    /// 返回该过去时刻 —— 由调用方决定顺延还是拒绝(调度器会剔除过期)。
    static func resolve(_ token: Token, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch token {
        case .tonight:
            return dateToday(hour: eveningHour, minute: 0, now: now, calendar: calendar)
        case .tomorrowMorning:
            return dateTomorrow(hour: morningHour, minute: 0, now: now, calendar: calendar)
        case .tomorrowNight:
            return dateTomorrow(hour: eveningHour, minute: 0, now: now, calendar: calendar)
        case .afterSeconds(let secs):
            return now.addingTimeInterval(secs)
        case .at(let h, let m):
            // 今天该时分;已过则明天。
            guard let today = dateToday(hour: h, minute: m, now: now, calendar: calendar) else { return nil }
            return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
        case .absolute(let date):
            return date
        }
    }

    // MARK: - Quick chip tokens (Today「稍后提醒」)

    /// Today 页「稍后提醒我…」的快捷选项。顺序即 UI 展示顺序。
    static var quickChips: [(title: String, token: Token)] {
        [
            ("1 小时后", .afterSeconds(3600)),
            ("今晚", .tonight),
            ("明早", .tomorrowMorning)
        ]
    }

    // MARK: - Helpers

    private static func dateToday(hour: Int, minute: Int, now: Date, calendar: Calendar) -> Date? {
        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = hour
        comps.minute = minute
        return calendar.date(from: comps)
    }

    private static func dateTomorrow(hour: Int, minute: Int, now: Date, calendar: Calendar) -> Date? {
        guard let today = dateToday(hour: hour, minute: minute, now: now, calendar: calendar) else { return nil }
        return calendar.date(byAdding: .day, value: 1, to: today)
    }
}
