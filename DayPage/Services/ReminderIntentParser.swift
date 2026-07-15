import Foundation

// MARK: - ReminderIntentParser
//
// 自然语言 → 提醒调度(vNext,2026-07-15)。把「每天 22:00 提醒我写日记」
// 「一小时后提醒我」「今晚提醒我复盘」「周一三五 9 点提醒我晨记」解析成
// `Reminder.Trigger + label`,直接落进 CaptureReminderService 统一调度器。
//
// 设计原则(与 IntentRouter 同一哲学):
//   • 纯启发式规则,零 LLM 调用 —— 排提醒是高频小意图,不值一次网络往返;
//     解析失败由对话层追问,而不是把模糊输入猜成错误时间。
//   • 时间语义只有一个口径:相对词(今晚/明早/N 小时后)全部走
//     RelativeTimeResolver,与 UI 快捷 chips 共用,避免两处「今晚是几点」分叉。
//   • 拦截在视图层(Coach / 问过去)IntentRouter 之前;本解析器自带
//     「必须包含提醒动词」的门 —— 没有「提醒/remind/叫我」不会误触发。
//
// 解析能力(超出即返回 nil,让对话层追问):
//   重复:每天 / 工作日 / 周末 / 周一三五(任意周几组合)+ 时分
//   一次:N 分钟后 / N 小时后 / 半小时后 / 今晚 / 明早 / 明晚 /
//         今天|明天 + 时分 / 裸时分(已过顺延到明天,由 Resolver 处理)
//   时分:22:00 / 22点 / 22 点半 / 晚上 10 点 / 早上八点(中文数字一~十二)
//   标签:剥掉时间短语和提醒动词后的剩余文本(「今晚提醒我复盘」→「复盘」)

struct ParsedReminder: Equatable {
    let trigger: Reminder.Trigger
    let label: String
}

enum ReminderIntentParser {

    // MARK: - Public entry

    /// 解析一句自然语言。返回 nil = 不是提醒请求,或时间无法可靠解析。
    /// `now`/`calendar` 可注入便于测试。
    static func parse(
        _ text: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ParsedReminder? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        // 门:必须包含提醒动词,否则不是本解析器的事。
        guard containsReminderVerb(raw) else { return nil }

        var consumed = Set<Range<String.Index>>()

        // 1. 重复规则(每天/工作日/周末/周几组合)优先于一次性。
        if let days = parseRepeatDays(raw, consumed: &consumed) {
            // 重复提醒必须有明确时分,否则语义不完整 → 交给对话层追问。
            guard let (h, m) = parseClockTime(raw, consumed: &consumed) else { return nil }
            let trigger: Reminder.Trigger = days.count == 7
                ? .daily(hour: h, minute: m)
                : .weekdays(days: days, hour: h, minute: m)
            return ParsedReminder(trigger: trigger, label: extractLabel(raw, consumed: consumed))
        }

        // 2. 相对间隔:N 分钟/小时后。
        if let interval = parseAfterInterval(raw, consumed: &consumed),
           let date = RelativeTimeResolver.resolve(.afterSeconds(interval), now: now, calendar: calendar) {
            return ParsedReminder(trigger: .once(date), label: extractLabel(raw, consumed: consumed))
        }

        // 3. 相对日词(今晚/明早/明晚/今天/明天)± 具体时分。
        let dayWord = parseDayWord(raw, consumed: &consumed)
        let clock = parseClockTime(raw, consumed: &consumed)

        switch (dayWord, clock) {
        case (.some(let word), .some(let hm)):
            // 「明天下午 3 点」:相对日 + 显式时分。
            guard let base = resolveDayWord(word, now: now, calendar: calendar) else { return nil }
            var comps = calendar.dateComponents([.year, .month, .day], from: base)
            comps.hour = hm.hour
            comps.minute = hm.minute
            guard let date = calendar.date(from: comps), date > now else {
                // 「今晚 8 点」但已 21 点 —— 过去时刻不猜,追问。
                return nil
            }
            return ParsedReminder(trigger: .once(date), label: extractLabel(raw, consumed: consumed))

        case (.some(let word), .none):
            // 裸相对日词:今晚→20:00 / 明早→08:00(RelativeTimeResolver 口径)。
            guard let token = defaultToken(for: word),
                  let date = RelativeTimeResolver.resolve(token, now: now, calendar: calendar),
                  date > now else { return nil }
            return ParsedReminder(trigger: .once(date), label: extractLabel(raw, consumed: consumed))

        case (.none, .some(let hm)):
            // 裸时分「10 点提醒我」:今天该时分,已过顺延明天(Resolver 语义)。
            guard let date = RelativeTimeResolver.resolve(
                .at(hour: hm.hour, minute: hm.minute), now: now, calendar: calendar
            ) else { return nil }
            return ParsedReminder(trigger: .once(date), label: extractLabel(raw, consumed: consumed))

        case (.none, .none):
            // 有提醒动词但没有任何可解析时间 —— 让对话层追问。
            return nil
        }
    }

    // MARK: - Reminder verb gate

    private static let reminderVerbs: [String] = [
        "提醒我", "提醒一下", "提醒", "叫我", "记得叫", "喊我",
        "remind me", "remind", "wake me"
    ]

    static func containsReminderVerb(_ text: String) -> Bool {
        let s = text.lowercased()
        return reminderVerbs.contains { s.contains($0) }
    }

    // MARK: - Repeat days

    /// 解析重复语义。返回 nil = 非重复;[1...7] 全集 = 每天。
    /// Calendar weekday 口径:1=周日 … 7=周六。
    private static func parseRepeatDays(
        _ text: String, consumed: inout Set<Range<String.Index>>
    ) -> Set<Int>? {
        // 注意:range 必须在原文上取(caseInsensitive),不能用 lowercased()
        // 副本的 String.Index 套回原文 —— 跨实例 index 是未定义行为。
        for phrase in ["每天", "每日", "天天", "every day", "everyday", "daily"] {
            if let r = text.range(of: phrase, options: [.caseInsensitive]) {
                consumed.insert(r)
                return [1, 2, 3, 4, 5, 6, 7]
            }
        }
        for phrase in ["每个工作日", "工作日", "weekdays"] {
            if let r = text.range(of: phrase, options: [.caseInsensitive]) {
                consumed.insert(r)
                return [2, 3, 4, 5, 6]
            }
        }
        for phrase in ["每周末", "周末", "weekends"] {
            if let r = text.range(of: phrase, options: [.caseInsensitive]) {
                consumed.insert(r)
                return [1, 7]
            }
        }

        // 「每周一」「周一三五」「每周二、四」—— 抓「每?周/星期/礼拜」后面
        // 连续的日字符序列(一二三四五六日天,允许顿号/逗号/空格分隔)。
        let dayChars: [Character: Int] = [
            "一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7, "日": 1, "天": 1
        ]
        let pattern = "(每?)(周|星期|礼拜)([一二三四五六日天][、，,\\s]*)+"
        if let regex = try? NSRegularExpression(pattern: pattern),
           let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let whole = Range(m.range, in: text) {
            var days = Set<Int>()
            for ch in text[whole] {
                if let d = dayChars[ch] { days.insert(d) }
            }
            if !days.isEmpty {
                consumed.insert(whole)
                return days
            }
        }
        return nil
    }

    // MARK: - Relative interval (N 分钟/小时后)

    private static func parseAfterInterval(
        _ text: String, consumed: inout Set<Range<String.Index>>
    ) -> TimeInterval? {
        // 半小时后 / 半个小时后
        for phrase in ["半小时后", "半个小时后", "半小时之后"] {
            if let r = text.range(of: phrase) {
                consumed.insert(r)
                return 1800
            }
        }
        // N 分钟后 / N 个?小时后 / in N minutes / in N hours(中文数字或阿拉伯数字)
        let patterns: [(String, TimeInterval)] = [
            ("([0-9一二两三四五六七八九十]+)\\s*分钟\\s*(后|之后)", 60),
            ("([0-9一二两三四五六七八九十]+)\\s*个?\\s*小时\\s*(后|之后)", 3600),
            ("in\\s+([0-9]+)\\s+minutes?", 60),
            ("in\\s+([0-9]+)\\s+hours?", 3600),
            ("in\\s+(an?)\\s+hour", 3600)
        ]
        for (pattern, unit) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let whole = Range(m.range, in: text) else { continue }
            var numText = "1"
            if m.numberOfRanges > 1, let nr = Range(m.range(at: 1), in: text) {
                numText = String(text[nr]).lowercased()
            }
            let n: Int? = (numText == "an" || numText == "a") ? 1 : chineseOrArabicNumber(numText)
            guard let n, n > 0 else { continue }
            consumed.insert(whole)
            return TimeInterval(n) * unit
        }
        return nil
    }

    // MARK: - Day words (今晚/明早/…)

    private enum DayWord { case tonight, tomorrowMorning, tomorrowNight, today, tomorrow }

    private static func parseDayWord(
        _ text: String, consumed: inout Set<Range<String.Index>>
    ) -> DayWord? {
        let table: [(String, DayWord)] = [
            ("今晚", .tonight), ("今天晚上", .tonight), ("tonight", .tonight),
            ("明早", .tomorrowMorning), ("明天早上", .tomorrowMorning),
            ("明天上午", .tomorrowMorning), ("tomorrow morning", .tomorrowMorning),
            ("明晚", .tomorrowNight), ("明天晚上", .tomorrowNight), ("tomorrow night", .tomorrowNight),
            ("明天", .tomorrow), ("tomorrow", .tomorrow),
            ("今天", .today), ("today", .today)
        ]
        // 长词优先(「明天晚上」要在「明天」之前命中);range 取自原文。
        for (phrase, word) in table.sorted(by: { $0.0.count > $1.0.count }) {
            if let r = text.range(of: phrase, options: [.caseInsensitive]) {
                consumed.insert(r)
                return word
            }
        }
        return nil
    }

    /// 裸相对日词的默认 token(与 UI 快捷 chips 完全同一口径)。
    /// 裸「今天/明天」没有默认钟点 —— 返回 nil 走追问。
    private static func defaultToken(for word: DayWord) -> RelativeTimeResolver.Token? {
        switch word {
        case .tonight:         return .tonight
        case .tomorrowMorning: return .tomorrowMorning
        case .tomorrowNight:   return .tomorrowNight
        case .today, .tomorrow: return nil
        }
    }

    /// 相对日词 → 当天零点(用于与显式时分组合)。
    private static func resolveDayWord(_ word: DayWord, now: Date, calendar: Calendar) -> Date? {
        switch word {
        case .today, .tonight:
            return calendar.startOfDay(for: now)
        case .tomorrow, .tomorrowMorning, .tomorrowNight:
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        }
    }

    // MARK: - Clock time (22:00 / 22点 / 晚上 10 点 / 早上八点半)

    private static func parseClockTime(
        _ text: String, consumed: inout Set<Range<String.Index>>
    ) -> (hour: Int, minute: Int)? {
        // 时段修饰词 → 12 小时制换算。
        let s = text.lowercased()
        var pmHint = false
        var amHint = false
        for phrase in ["下午", "晚上", "傍晚", "夜里", "pm"] where s.contains(phrase) { pmHint = true }
        for phrase in ["早上", "上午", "凌晨", "清晨", "am"] where s.contains(phrase) { amHint = true }

        // HH:mm / HH：mm
        if let regex = try? NSRegularExpression(pattern: "([0-9]{1,2})[:：]([0-9]{2})"),
           let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let whole = Range(m.range, in: text),
           let hr = Range(m.range(at: 1), in: text), let mr = Range(m.range(at: 2), in: text),
           let h = Int(text[hr]), let mm = Int(text[mr]), h < 24, mm < 60 {
            consumed.insert(whole)
            return (normalizeHour(h, pm: pmHint, am: amHint), mm)
        }

        // N 点 / N 点半 / N 点 M 分(N 支持中文数字一~十二)
        let pattern = "([0-9一二两三四五六七八九十]{1,3})\\s*点\\s*(半|[0-9]{1,2}\\s*分)?"
        if let regex = try? NSRegularExpression(pattern: pattern),
           let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let whole = Range(m.range, in: text),
           let hr = Range(m.range(at: 1), in: text),
           let h = chineseOrArabicNumber(String(text[hr])), h <= 24 {
            var minute = 0
            if m.numberOfRanges > 2, let tail = Range(m.range(at: 2), in: text) {
                let t = String(text[tail])
                if t == "半" {
                    minute = 30
                } else if let mm = Int(t.replacingOccurrences(of: "分", with: "")
                                        .trimmingCharacters(in: .whitespaces)), mm < 60 {
                    minute = mm
                }
            }
            consumed.insert(whole)
            return (normalizeHour(h, pm: pmHint, am: amHint), minute)
        }

        // at H / at H:MM (英文)
        if let regex = try? NSRegularExpression(pattern: "at\\s+([0-9]{1,2})(?::([0-9]{2}))?\\s*(am|pm)?", options: [.caseInsensitive]),
           let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let whole = Range(m.range, in: text),
           let hr = Range(m.range(at: 1), in: text), let h = Int(text[hr]), h <= 24 {
            var minute = 0
            if m.numberOfRanges > 2, let mr = Range(m.range(at: 2), in: text), let mm = Int(text[mr]), mm < 60 {
                minute = mm
            }
            var pm = pmHint, am = amHint
            if m.numberOfRanges > 3, let sr = Range(m.range(at: 3), in: text) {
                let suffix = text[sr].lowercased()
                pm = pm || suffix == "pm"
                am = am || suffix == "am"
            }
            consumed.insert(whole)
            return (normalizeHour(h, pm: pm, am: am), minute)
        }

        return nil
    }

    /// 12 小时制换算:「晚上 10 点」→ 22;「早上 8 点」→ 8;无修饰不动。
    private static func normalizeHour(_ h: Int, pm: Bool, am: Bool) -> Int {
        if pm && h < 12 { return h + 12 }
        if am && h == 12 { return 0 }
        return h
    }

    // MARK: - Label extraction

    /// 剥掉时间短语(consumed ranges)和提醒动词、连接词后,剩下的就是标签。
    private static func extractLabel(_ text: String, consumed: Set<Range<String.Index>>) -> String {
        // 按 range 挖空(从后往前,前缀 index 保持有效)。重叠的 range 跳过,
        // 避免二次删除越界。
        var result = text
        var lastRemovedLower: String.Index? = nil
        for r in consumed.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            if let bound = lastRemovedLower, r.upperBound > bound { continue }
            result.removeSubrange(r)
            lastRemovedLower = r.lowerBound
        }
        // 剥提醒动词、黏连的语气/连接词,以及仅作 12h 换算 hint 用的时段
        // 修饰词(parseClockTime 只读不 consume,在这里统一清掉)。
        let noise = [
            "提醒我", "提醒一下", "提醒", "叫我", "记得叫", "喊我", "记得",
            "remind me to", "remind me", "remind", "wake me up", "wake me",
            "下午", "晚上", "早上", "上午", "凌晨", "傍晚", "夜里", "清晨",
            "am", "pm",
            "请", "帮我", "麻烦", "记录", "去", "要"
        ]
        for phrase in noise.sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: phrase, with: " ", options: [.caseInsensitive])
        }
        let cleaned = result
            .components(separatedBy: CharacterSet(charactersIn: " ，。,.!？?、；;的"))
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned
    }

    // MARK: - Numbers

    /// "22" → 22;"十" → 10;"两" → 2;"十一" → 11;"二十" → 20。
    private static func chineseOrArabicNumber(_ s: String) -> Int? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if let n = Int(trimmed) { return n }
        let digits: [Character: Int] = [
            "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5,
            "六": 6, "七": 7, "八": 8, "九": 9
        ]
        // 十 / 十N / N十 / N十M
        if trimmed == "十" { return 10 }
        if trimmed.count == 2, trimmed.hasPrefix("十"), let last = trimmed.last, let d = digits[last] {
            return 10 + d
        }
        if trimmed.count == 2, trimmed.hasSuffix("十"), let first = trimmed.first, let d = digits[first] {
            return d * 10
        }
        if trimmed.count == 3 {
            let chars = Array(trimmed)
            if chars[1] == "十", let tens = digits[chars[0]], let ones = digits[chars[2]] {
                return tens * 10 + ones
            }
        }
        if trimmed.count == 1, let ch = trimmed.first, let d = digits[ch] { return d }
        return nil
    }
}
