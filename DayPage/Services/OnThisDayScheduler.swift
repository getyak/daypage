import Foundation
import UIKit

// MARK: - OnThisDayScheduler

@MainActor
final class OnThisDayScheduler: ObservableObject {

    static let shared = OnThisDayScheduler()

    private let nextFireKey = "onThisDayNextFireAt"
    private let refreshHourKey = "onThisDayRefreshHour"
    private let dismissedDateKey = AppSettings.Keys.onThisDayDismissed
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

    private var observerTokens: [NSObjectProtocol] = []

    private init() {
        setupNotifications()
    }

    deinit {
        observerTokens.forEach { NotificationCenter.default.removeObserver($0) }
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

    /// R8 — async wrapper invoked by TodayView after `OnThisDayIndex.isReady`
    /// flips. Re-runs candidate selection against the freshly-loaded index
    /// and broadcasts the result on the same `.onThisDayShouldShow` channel
    /// the becomeActive observer uses, so `TodayViewModel.onThisDayEntry`
    /// updates through one well-known seam. Respects isDismissedToday so a
    /// user who dismissed the card earlier today doesn't see it re-emerge
    /// after a background index refresh.
    func refreshTodayEntry() async {
        guard isEnabled else { return }
        guard !isDismissedToday() else { return }
        guard let entry = OnThisDayIndex.shared.candidate(for: Date()) else { return }
        NotificationCenter.default.post(
            name: .onThisDayShouldShow,
            object: entry
        )
    }

    /// R6 — public dismiss API. Persists today's date under
    /// `AppSettings.Keys.onThisDayDismissed` so `shouldShowToday()` returns
    /// nil for the rest of the local day. Survives backgrounding and
    /// relaunch; rolls off at the next local midnight (the key compares
    /// against `dayString(from: Date())`).
    func markDismissedForToday() {
        UserDefaults.standard.set(dayString(from: Date()), forKey: dismissedDateKey)
    }

    /// Test seam — exposes the persisted-dismiss check so unit tests can
    /// verify markDismissedForToday() flips the flag without reaching into
    /// UserDefaults directly. Production paths call shouldShowToday().
    func isDismissedTodayForTesting() -> Bool {
        isDismissedToday()
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
        let timeToken = NotificationCenter.default.addObserver(
            forName: UIApplication.significantTimeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recomputeNextFireAt()
            }
        }

        let activeToken = NotificationCenter.default.addObserver(
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

        observerTokens = [timeToken, activeToken]
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
    /// Posted by: OnThisDayScheduler.evaluateAndBroadcast / scheduleDeliveryIfNeeded —
    /// when an anniversary daily-page should surface at the top of Today (e.g. "1 year ago today").
    /// Observed by: TodayViewModel (.publisher — injects the On-This-Day card into the
    /// top of the timeline feed).
    static let onThisDayShouldShow = Notification.Name("com.daypage.onThisDayShouldShow")
}
