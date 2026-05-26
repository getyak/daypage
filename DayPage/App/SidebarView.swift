import SwiftUI

// MARK: - SidebarView

struct SidebarView: View {

    @EnvironmentObject private var nav: AppNavigationModel
    @EnvironmentObject private var authService: AuthService

    @StateObject private var sidebarVM = SidebarViewModel()
    @State private var showSettings = false
    @State private var showAccountSheet = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Liquid Glass drawer — warm cream base + ultraThinMaterial blur
            // gives the sidebar the "floating panel above the timeline" feel
            // that matches Today's ambient glass language. RootView's scrim
            // sits behind this layer so the drawer reads as elevated.
            ZStack {
                DSColor.bgWarm
                Rectangle()
                    .fill(DSColor.glassHi)
                    .background(.ultraThinMaterial)
            }
            .ignoresSafeArea()
            .overlay(alignment: .trailing) {
                // Hairline rim along the right edge — separates the drawer
                // from the dimmed timeline behind the scrim.
                Rectangle()
                    .fill(DSColor.glassRimD)
                    .frame(width: 0.5)
                    .ignoresSafeArea(edges: .vertical)
            }

            VStack(alignment: .leading, spacing: 0) {
                brandHeader

                Rectangle()
                    .fill(DSColor.inkFaint)
                    .frame(height: 0.5)
                    .padding(.bottom, 8)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        navSection
                            .padding(.top, 4)

                        if !sidebarVM.recentDays.isEmpty {
                            recentSection
                                .padding(.top, 18)
                        }

                        // Always show feedback row at the bottom of the
                        // scrollable area so it stays reachable even when the
                        // Recent list grows.
                        feedbackSection
                            .padding(.top, 18)
                    }
                    .padding(.bottom, 24)
                }

                Rectangle()
                    .fill(DSColor.inkFaint)
                    .frame(height: 0.5)

                bottomSection
            }
            .frame(maxHeight: .infinity)
        }
        .task {
            sidebarVM.bind(authService: authService)
        }
        .onChange(of: nav.isSidebarOpen) { isOpen in
            // Refresh the recent-day list every time the drawer opens so the
            // user sees the latest activity without having to relaunch.
            if isOpen { sidebarVM.refreshRecentDays() }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showAccountSheet) {
            AccountSheet()
        }
    }

    // MARK: - Brand Header

    private var brandHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DayPage")
                .font(DSType.serifDisplay32)
                .foregroundColor(DSColor.inkPrimary)
            Text("your daily log")
                .font(DSType.mono10)
                .foregroundColor(DSColor.inkSubtle)
                .textCase(.uppercase)
                .tracking(1.0)
            activityDots
        }
        .padding(.horizontal, 24)
        .padding(.top, 64)
        .padding(.bottom, 24)
    }

    /// 7 circles representing memo activity for the last 7 days (today on the right).
    private var activityDots: some View {
        let days = last7DayPairs()
        let todayStr = Self.isoFormatter.string(from: Date())
        return HStack(spacing: 5) {
            ForEach(days, id: \.dateString) { pair in
                let isToday = pair.dateString == todayStr
                let count = pair.count
                let label = Self.dotAccessibilityLabel(for: pair.dateString, count: count)
                Button {
                    Haptics.soft()
                    nav.openArchive(at: pair.dateString)
                } label: {
                    Circle()
                        .fill(count > 0 ? DSColor.amberAccent : DSColor.inkFaint)
                        .frame(width: 8, height: 8)
                        .opacity(count > 0 ? min(0.4 + Double(count) * 0.15, 1.0) : 0.25)
                        .overlay {
                            if isToday {
                                Circle()
                                    .strokeBorder(DSColor.amberRim, lineWidth: 1)
                            }
                        }
                        .dsAnimation(Motion.spring, value: count)
                }
                .frame(width: 28, height: 28)
                .contentShape(Circle())
                .buttonStyle(.plain)
                .accessibilityLabel(label)
                .accessibilityHint("Opens this day in Archive")
            }
        }
        .padding(.top, 2)
    }

    /// Returns date+count pairs for the last 7 days (index 0 = 6 days ago, index 6 = today).
    private func last7DayPairs() -> [(dateString: String, count: Int)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<7).reversed().map { daysAgo in
            guard let date = cal.date(byAdding: .day, value: -daysAgo, to: today) else {
                return (dateString: "", count: 0)
            }
            let dateStr = Self.isoFormatter.string(from: date)
            let count = sidebarVM.recentDays.first(where: { $0.dateString == dateStr })?.memoCount ?? 0
            return (dateString: dateStr, count: count)
        }
    }

    private static func dotAccessibilityLabel(for dateString: String, count: Int) -> String {
        guard let date = isoFormatter.date(from: dateString) else { return dateString }
        let weekday = weekdayFormatter.string(from: date)
        if count == 0 {
            return "\(weekday), no notes"
        } else {
            return "\(weekday), \(count) \(count == 1 ? "note" : "notes")"
        }
    }

    // MARK: - Nav Items

    /// Primary nav: Today / Archive / Graph.
    private var navSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            navItem(tab: .today, icon: "square.and.pencil", label: "Today")
            navItem(tab: .archive, icon: "archivebox", label: "Archive")
            navItem(tab: .graph, icon: "point.3.connected.trianglepath.dotted", label: "Graph")
        }
        .padding(.horizontal, 12)
    }

    private var feedbackSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionLabel("Support")
            navItem(tab: .feedback, icon: "bubble.left.and.exclamationmark.bubble.right", label: "Feedback")
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private func navItem(tab: AppTab, icon: String, label: String, disabled: Bool = false) -> some View {
        let isActive = nav.selectedTab == tab && tab != .feedback

        Button {
            guard !disabled else { return }
            if tab == .feedback {
                nav.openFeedbackPanel()
            } else {
                nav.navigate(to: tab)
            }
        } label: {
            HStack(spacing: 12) {
                // Left amber accent strip
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(isActive ? DSColor.amberAccent : Color.clear)
                    .frame(width: 2, height: 20)

                Image(systemName: icon)
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 20)
                    .foregroundColor(
                        disabled ? DSColor.inkSubtle
                        : isActive ? DSColor.amberAccent
                        : DSColor.inkMuted
                    )

                Text(label)
                    .font(isActive ? DSType.titleSM : DSType.bodyMD)
                    .foregroundColor(
                        disabled ? DSColor.inkSubtle
                        : isActive ? DSColor.inkPrimary
                        : DSColor.inkMuted
                    )

                if disabled {
                    Spacer()
                    Text("Post-MVP")
                        .font(DSType.mono9)
                        .foregroundColor(DSColor.inkSubtle)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(DSColor.amberSoft, in: Capsule())
                }
            }
            .padding(.leading, 0)
            .padding(.trailing, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isActive ? DSColor.amberSoft : Color.clear)
            .contentShape(Rectangle())
        }
        .disabled(disabled)
        .buttonStyle(.plain)
    }

    // MARK: - Recent Section

    /// "Commit history" style list: the most recent days that actually have
    /// memos, tapping a row jumps straight to that day's detail view in
    /// Archive. Refreshed on every sidebar open via `refreshRecentDays()`.
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionLabel("Recent")

            ForEach(sidebarVM.recentDays) { day in
                recentRow(day: day)
            }
        }
        .padding(.horizontal, 12)
    }

    private func recentRow(day: RecentDay) -> some View {
        Button {
            nav.openArchive(at: day.dateString)
        } label: {
            HStack(spacing: 12) {
                Color.clear.frame(width: 2, height: 20)

                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .frame(width: 20)
                    .foregroundColor(DSColor.amberAccent.opacity(0.75))

                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.formatRowTitle(day.dateString))
                        .font(DSType.bodySM)
                        .foregroundColor(DSColor.inkPrimary)
                    Text(day.dateString)
                        .font(DSType.mono9)
                        .foregroundColor(DSColor.inkSubtle)
                        .tracking(0.5)
                        .textCase(.uppercase)
                }

                Spacer()

                Text("\(day.memoCount)")
                    .font(DSType.mono10)
                    .foregroundColor(DSColor.inkMuted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(DSColor.amberSoft, in: Capsule())
            }
            .padding(.trailing, 16)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(DSType.mono9)
            .foregroundColor(DSColor.inkSubtle)
            .tracking(1.2)
            .textCase(.uppercase)
            .padding(.leading, 34)  // align with row text column (2 + 12 + 20)
            .padding(.bottom, 4)
    }

    // MARK: - Bottom Section

    private var bottomSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Settings
            Button {
                showSettings = true
            } label: {
                HStack(spacing: 12) {
                    Color.clear.frame(width: 2, height: 20)
                    Image(systemName: "gearshape")
                        .font(.system(size: 16, weight: .regular))
                        .frame(width: 20)
                        .foregroundColor(DSColor.inkMuted)
                    Text("Settings")
                        .font(DSType.bodyMD)
                        .foregroundColor(DSColor.inkMuted)
                }
                .padding(.trailing, 16)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Account (when logged in)
            if sidebarVM.isLoggedIn {
                accountRow
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .padding(.bottom, 24)
    }

    private var accountRow: some View {
        let email = sidebarVM.accountEmail
        let initial = sidebarVM.accountInitial

        return Button {
            showAccountSheet = true
        } label: {
            HStack(spacing: 12) {
                Color.clear.frame(width: 2, height: 20)
                ZStack {
                    Circle()
                        .fill(DSColor.amberSoft)
                        .frame(width: 28, height: 28)
                        .overlay(Circle().strokeBorder(DSColor.amberRim, lineWidth: 0.5))
                    Text(initial)
                        .font(DSType.labelSM)
                        .foregroundColor(DSColor.amberDeep)
                }
                .frame(width: 20)
                Text(email)
                    .font(DSType.bodySM)
                    .foregroundColor(DSColor.inkMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.trailing, 16)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Date Formatting

    /// Renders the row title as "Today" / "Yesterday" / weekday name to keep
    /// the list scannable; falls back to month-day for older entries.
    private static func formatRowTitle(_ dateString: String) -> String {
        guard let date = isoFormatter.date(from: dateString) else { return dateString }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let daysAgo = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day ?? 0
        if daysAgo < 7 { return weekdayFormatter.string(from: date) }
        return monthDayFormatter.string(from: date)
    }

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEEE"
        return f
    }()

    private static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMM d"
        return f
    }()
}
