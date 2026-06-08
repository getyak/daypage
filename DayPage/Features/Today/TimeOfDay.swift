import SwiftUI

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
}
