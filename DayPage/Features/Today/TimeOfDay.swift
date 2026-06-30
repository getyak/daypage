import SwiftUI
import DayPageServices

/// Formats the device's current UTC offset as a compact GMT token for the Today header.
/// e.g. GMT+7, GMT-3:30, GMT+5:45, GMT (zero offset)
enum TimeZoneBadge {
    static func gmtOffset(for tz: TimeZone, at date: Date) -> String {
        let totalSeconds = tz.secondsFromGMT(for: date)
        guard totalSeconds != 0 else { return "GMT" }
        let sign = totalSeconds > 0 ? "+" : "-"
        let abs = Swift.abs(totalSeconds)
        let hours = abs / 3600
        let minutes = (abs % 3600) / 60
        if minutes == 0 {
            return "GMT\(sign)\(hours)"
        } else {
            return String(format: "GMT\(sign)\(hours):%02d", minutes)
        }
    }
}

/// Pure time-of-day bucketing shared by the Day Orb and the kicker.
enum TimeOfDay: Int {
    case morning    = 0
    case afternoon  = 1
    case evening    = 2
    case lateNight  = 3

    static func bucket(hour: Int) -> TimeOfDay {
        switch hour {
        case 5...11:  return .morning
        case 12...17: return .afternoon
        case 18...22: return .evening
        default:      return .lateNight
        }
    }

    static func from(_ date: Date, calendar: Calendar = .current) -> TimeOfDay {
        let hour = calendar.component(.hour, from: date)
        return bucket(hour: hour)
    }

    var greetingKey: String {
        switch self {
        case .morning:   return "today.greeting.morning"
        case .afternoon: return "today.greeting.afternoon"
        case .evening:   return "today.greeting.evening"
        case .lateNight: return "today.greeting.latenight"
        }
    }

    var bucketIndex: Int { rawValue }

    var tint: Color {
        switch self {
        case .morning:   return Color(red: 0.45, green: 0.55, blue: 0.88)  // cool periwinkle dawn
        case .afternoon: return DSColor.accentAmber                         // midday amber (canonical)
        case .evening:   return Color(red: 0.85, green: 0.40, blue: 0.15)  // warm orange-ember evening
        case .lateNight: return Color(red: 0.28, green: 0.22, blue: 0.60)  // deep indigo late-night
        }
    }

    /// Continuously interpolated tint that drifts smoothly between bucket anchors.
    /// Anchor hours are bucket midpoints: morning≈08:00, afternoon≈14:30, evening≈20:00, late-night≈01:30.
    /// The original discrete `tint` is unchanged for back-compat.
    static func continuousTint(at date: Date, calendar: Calendar = .current) -> Color {
        struct Anchor {
            let minuteOfDay: Double  // 0 = 00:00, 1439 = 23:59
            let r, g, b: Double
        }
        // Anchor colors match the four discrete tints, centred on bucket midpoints.
        // accentAmber resolves to (1.0, 0.75, 0.0) — the canonical midday amber.
        let anchors: [Anchor] = [
            Anchor(minuteOfDay:  90, r: 0.28, g: 0.22, b: 0.60), // 01:30 late-night
            Anchor(minuteOfDay: 480, r: 0.45, g: 0.55, b: 0.88), // 08:00 morning
            Anchor(minuteOfDay: 870, r: 1.00, g: 0.75, b: 0.00), // 14:30 afternoon
            Anchor(minuteOfDay: 1200, r: 0.85, g: 0.40, b: 0.15), // 20:00 evening
        ]
        let hour   = Double(calendar.component(.hour,   from: date))
        let minute = Double(calendar.component(.minute, from: date))
        let current = hour * 60 + minute  // 0…1439

        // Find the two nearest anchors by circular clock distance.
        // We extend the anchor list with wrap-around copies to handle midnight crossings.
        let dayMinutes = 24.0 * 60.0
        // Compute forward (clockwise) distance from current to each anchor.
        func forwardDist(_ anchor: Anchor) -> Double {
            let d = anchor.minuteOfDay - current
            return d < 0 ? d + dayMinutes : d
        }
        // Sort anchors by forward distance; the first is the "next" anchor, the last is "prev".
        let sorted = anchors.sorted { forwardDist($0) < forwardDist($1) }
        let next = sorted[0]
        let prev = sorted[anchors.count - 1]

        // Distance from prev to current (going forward).
        let distFromPrev: Double = {
            let d = current - prev.minuteOfDay
            return d < 0 ? d + dayMinutes : d
        }()
        // Arc between prev and next.
        let arcPrevNext: Double = {
            let d = next.minuteOfDay - prev.minuteOfDay
            return d <= 0 ? d + dayMinutes : d
        }()
        let t = arcPrevNext > 0 ? min(1, max(0, distFromPrev / arcPrevNext)) : 0

        let r = prev.r + t * (next.r - prev.r)
        let g = prev.g + t * (next.g - prev.g)
        let b = prev.b + t * (next.b - prev.b)
        return Color(red: r, green: g, blue: b)
    }
}
