import Foundation

// MARK: - Reminder
//
// 「记录提醒」的统一数据模型。取代旧的 ReminderSlot(每日重复)+ 想象中的
// OneShot(一次性)两套 —— 一个 Reminder 用 `trigger` 表达所有节奏:
//   • .once(Date)        —— 精确到某个绝对时间点,触发后自动消失
//   • .daily(h, m)       —— 每天固定时分
//   • .weekdays(days,h,m)—— 指定周几(1=周日…7=周六)的固定时分
//
// 设计动机(用户决策 2026-07-15):统一调度器,一个模型、一个 schedule 入口,
// AI 和 UI 都只面对这一套 API。复杂度收在调度逻辑里,不外溢到多个类型。
//
// 归属:app target(DayPage/Services/)。只有 CaptureAlarmMetadata 需要
// 跨 Widget target 共享;Reminder 本身不进 Widget,所以留在 app 侧。

/// 一条记录提醒。`trigger` 决定何时触发,其余是展示与来源元信息。
struct Reminder: Codable, Identifiable, Equatable {

    // MARK: Trigger

    /// 触发规则。Codable 用显式 tag,便于未来无损扩展(如 .monthly)。
    enum Trigger: Codable, Equatable {
        /// 一次性:精确到某个绝对时间点。触发后由调度器清理。
        case once(Date)
        /// 每天固定时分。
        case daily(hour: Int, minute: Int)
        /// 指定周几固定时分。weekdays 用 Calendar 周序:1=周日…7=周六。
        case weekdays(days: Set<Int>, hour: Int, minute: Int)
    }

    /// 来源 —— 用户手动建 vs AI 在对话里排。用于 Today 页/埋点区分,不影响调度。
    enum Source: String, Codable, Equatable {
        case user
        case ai
    }

    /// 呈现级别 —— 到点时"多大声"。这是 vNext(2026-07-19)分层的支点:
    ///   • .quiet —— 安静。轻量 UN 通知(interruptionLevel .active + sound nil),
    ///     不夺屏、可真无声,只在锁屏/横幅优雅悬浮。默认。
    ///   • .loud  —— 重要。AlarmKit 全屏闹钟 alert + 声音,给不能错过的事。
    ///
    /// 技术依据(逐行核对 iOS 26.4 SDK):AlarmKit 的 sound 非 Optional、无静音
    /// 档,到点必全屏 alert —— 做不到"安静不响";故安静态走 UN,只有 .loud 走
    /// AlarmKit。Codable 缺字段解码回退 .quiet,老数据无损升级。
    enum Level: String, Codable, Equatable {
        case quiet
        case loud
    }

    let id: UUID
    var trigger: Trigger
    var label: String
    var enabled: Bool
    var source: Source
    var level: Level

    init(
        id: UUID = UUID(),
        trigger: Trigger,
        label: String,
        enabled: Bool = true,
        source: Source = .user,
        level: Level = .quiet
    ) {
        self.id = id
        self.trigger = trigger
        self.label = label
        self.enabled = enabled
        self.source = source
        self.level = level
    }

    // MARK: Codable — level 向后兼容

    /// 手写 decode 只为一件事:老数据(无 `level` 字段)解码成 `.quiet` 而非
    /// 抛错。其余字段用默认合成行为。`trigger`/`source` 仍走自动 Codable。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        trigger = try c.decode(Trigger.self, forKey: .trigger)
        label = try c.decode(String.self, forKey: .label)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        source = try c.decode(Source.self, forKey: .source)
        level = try c.decodeIfPresent(Level.self, forKey: .level) ?? .quiet
    }

    private enum CodingKeys: String, CodingKey {
        case id, trigger, label, enabled, source, level
    }

    // MARK: - Derived display

    /// 该 trigger 的「时分」—— 一次性取其本地时分,重复直接取字段。
    var timeComponents: (hour: Int, minute: Int) {
        switch trigger {
        case .once(let date):
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            return (c.hour ?? 0, c.minute ?? 0)
        case .daily(let h, let m):
            return (h, m)
        case .weekdays(_, let h, let m):
            return (h, m)
        }
    }

    /// "HH:mm" 展示用。
    var timeString: String {
        let (h, m) = timeComponents
        return String(format: "%02d:%02d", h, m)
    }

    /// 重复规则的一句人类可读描述(「每天」「工作日」「周六」「今晚一次」)。
    var repeatDescription: String {
        switch trigger {
        case .once(let date):
            return Self.relativeDayLabel(for: date)
        case .daily:
            return "每天"
        case .weekdays(let days, _, _):
            return Self.weekdayLabel(for: days)
        }
    }

    /// 是否一次性 —— 用于调度器决定过期剔除,及 UI 分组。
    var isOneShot: Bool {
        if case .once = trigger { return true }
        return false
    }

    /// 下次触发时间点。已启用时计算,禁用返回 nil。用于 Today 胶囊排序 &
    /// 「即将触发」筛选。一次性直接返回 fireDate;重复算从 now 起最近一次。
    func nextFireDate(after now: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard enabled else { return nil }
        switch trigger {
        case .once(let date):
            return date > now ? date : nil
        case .daily(let h, let m):
            return Self.nextDaily(hour: h, minute: m, after: now, calendar: calendar)
        case .weekdays(let days, let h, let m):
            return Self.nextWeekday(days: days, hour: h, minute: m, after: now, calendar: calendar)
        }
    }

    // MARK: - Next-fire helpers

    private static func nextDaily(hour: Int, minute: Int, after now: Date, calendar: Calendar) -> Date? {
        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = hour
        comps.minute = minute
        guard let today = calendar.date(from: comps) else { return nil }
        if today > now { return today }
        return calendar.date(byAdding: .day, value: 1, to: today)
    }

    private static func nextWeekday(days: Set<Int>, hour: Int, minute: Int, after now: Date, calendar: Calendar) -> Date? {
        guard !days.isEmpty else { return nil }
        // 从今天起最多看 7 天,命中第一个「周几匹配且时间在 now 之后」的点。
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            guard days.contains(weekday) else { continue }
            var comps = calendar.dateComponents([.year, .month, .day], from: day)
            comps.hour = hour
            comps.minute = minute
            guard let candidate = calendar.date(from: comps) else { continue }
            if candidate > now { return candidate }
        }
        return nil
    }

    // MARK: - Label helpers

    /// 周几集合 → 「每天」「工作日」「周末」「周一、三、五」这类描述。
    static func weekdayLabel(for days: Set<Int>) -> String {
        let all: Set<Int> = [1, 2, 3, 4, 5, 6, 7]
        let workdays: Set<Int> = [2, 3, 4, 5, 6]
        let weekend: Set<Int> = [1, 7]
        if days == all { return "每天" }
        if days == workdays { return "工作日" }
        if days == weekend { return "周末" }
        let names = ["", "日", "一", "二", "三", "四", "五", "六"]
        let sorted = days.sorted { orderKey($0) < orderKey($1) }
        let joined = sorted.map { names[$0] }.joined(separator: "、")
        return "周\(joined)"
    }

    /// 排序键:周一→周日(把周日=1 排到最后,符合中文「周一到周日」直觉)。
    private static func orderKey(_ weekday: Int) -> Int {
        weekday == 1 ? 8 : weekday
    }

    /// 一次性提醒的日期标签:今天/明天/后天 + 时间,或具体日期。
    static func relativeDayLabel(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        let time = f.string(from: date)

        let startOfNow = calendar.startOfDay(for: now)
        let startOfDate = calendar.startOfDay(for: date)
        let dayDiff = calendar.dateComponents([.day], from: startOfNow, to: startOfDate).day ?? 0
        switch dayDiff {
        case 0: return "今天 \(time)"
        case 1: return "明天 \(time)"
        case 2: return "后天 \(time)"
        default:
            f.dateFormat = "M月d日 HH:mm"
            return f.string(from: date)
        }
    }

    // MARK: - Prompt body

    /// 通知正文 —— 随时段给一句轻提示,不用命令式。沿用旧 ReminderSlot 语气。
    var promptBody: String {
        let (h, _) = timeComponents
        switch h {
        case 5..<11:  return "早上好 · 记一句此刻在想什么"
        case 11..<15: return "间隙里 · 留一条给今天"
        case 15..<19: return "下午了 · 有什么值得记下的"
        default:      return "睡前 · 把今天收进一句话"
        }
    }
}

// MARK: - Preset defaults

extension Reminder {
    /// 每天一次(晚 21:00)。
    static var onceDefaults: [Reminder] {
        [Reminder(trigger: .daily(hour: 21, minute: 0), label: "睡前")]
    }

    /// 早中晚三次(09:00 / 13:00 / 21:00)。
    static var thriceDefaults: [Reminder] {
        [
            Reminder(trigger: .daily(hour: 9, minute: 0), label: "早"),
            Reminder(trigger: .daily(hour: 13, minute: 0), label: "午"),
            Reminder(trigger: .daily(hour: 21, minute: 0), label: "晚")
        ]
    }
}
