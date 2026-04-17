import Foundation
import UIKit

// MARK: - OnThisDayScheduler

@MainActor
final class OnThisDayScheduler: ObservableObject {

    static let shared = OnThisDayScheduler()

    private let nextFireKey = "onThisDayNextFireAt"
    private let refreshHourKey = "onThisDayRefreshHour"
    private let dismissedDateKey = "onThisDayDismissedDate"
    private let enabledKey = "onThisDayEnabled"

    var refreshHour: Int {
        get { UserDefaults.standard.integer(forKey: refreshHourKey) }
        set { UserDefaults.standard.set(newValue, forKey: refreshHourKey) }
    }

    var isEnabled: Bool {
        get {
            let v = UserDefaults.standard.object(forKey: enabledKey)
            return v == nil ? true : UserDefaults.standard.bool(forKey: enabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    private init() {
        setupNotifications()
    }

    // MARK: - Public API

    func shouldShowToday() -> OnThisDayEntry? {
        guard isEnabled else { return nil }
        guard !isDismissedToday() else { return nil }

        let now = Date()
        if let nextFire = UserDefaults.standard.object(forKey: nextFireKey) as? Date,
           now < nextFire {
            return nil
        }
        return OnThisDayIndex.shared.candidate(for: now)
    }

    func markShown() {
        let nextFire = nextFireDate()
        UserDefaults.standard.set(nextFire, forKey: nextFireKey)
    }

    func forceRefresh() -> OnThisDayEntry? {
        guard isEnabled else { return nil }
        return OnThisDayIndex.shared.candidate(for: Date())
    }

    // MARK: - Private

    private func isDismissedToday() -> Bool {
        let today = dayString(from: Date())
        let dismissed = UserDefaults.standard.string(forKey: dismissedDateKey)
        return dismissed == today
    }

    private func dayString(from date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone.current
        return fmt.string(from: date)
    }

    private func nextFireDate() -> Date {
        var cal = Calendar.current
        cal.timeZone = TimeZone.current
        var components = cal.dateComponents([.year, .month, .day], from: Date())
        components.hour = refreshHour
        components.minute = 0
        components.second = 0
        // Next day at refreshHour
        if let today = cal.date(from: components) {
            return cal.date(byAdding: .day, value: 1, to: today) ?? today
        }
        return Date().addingTimeInterval(86400)
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.significantTimeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recomputeNextFireAt()
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let entry = self.shouldShowToday() {
                    NotificationCenter.default.post(
                        name: .onThisDayShouldShow,
                        object: entry
                    )
                }
            }
        }
    }

    private func recomputeNextFireAt() {
        if let existing = UserDefaults.standard.object(forKey: nextFireKey) as? Date {
            // Recompute next fire in new timezone
            let nextFire = nextFireDate()
            // Only update if the existing date is more than a day off (timezone jump)
            if abs(existing.timeIntervalSince(nextFire)) > 3600 {
                UserDefaults.standard.set(nextFire, forKey: nextFireKey)
            }
        }
    }
}

// MARK: - Notification Name

extension Notification.Name {
    static let onThisDayShouldShow = Notification.Name("com.daypage.onThisDayShouldShow")
}
