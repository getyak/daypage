import CoreGraphics
import Foundation

enum DayProgress {
    /// Fraction of the current local day elapsed: 0.0 at midnight, 1.0 at next midnight.
    /// Uses the actual day length so DST transitions (23h/25h days) are handled correctly.
    static func fraction(at now: Date, calendar: Calendar = .current) -> CGFloat {
        let start = calendar.startOfDay(for: now)
        let next = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        let total = next.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return CGFloat(min(1, max(0, now.timeIntervalSince(start) / total)))
    }
}
