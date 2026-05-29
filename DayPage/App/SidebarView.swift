import SwiftUI
import UIKit

// MARK: - SidebarView

struct SidebarView: View {

    @EnvironmentObject private var nav: AppNavigationModel
    @EnvironmentObject private var authService: AuthService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                        // Museum-aesthetic hero stack: profile → heatmap → stats.
                        profileRow
                        heatmapSection
                        statsSection

                        navSection
                            .padding(.top, 22)

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
            if isOpen {
                sidebarVM.refreshRecentDays()
                // Pre-warm the impact generator while the drawer is animating
                // open so the first nav tap fires with minimum latency.
                UIImpactFeedbackGenerator(style: .light).prepare()
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showAccountSheet) {
            AccountSheet()
        }
    }

    // MARK: - Brand Header

    /// Museum-aesthetic utility bar: a quiet close button + a tiny mono
    /// wordmark, replacing the old oversized serif logo.
    private var brandHeader: some View {
        HStack {
            Button {
                Haptics.soft()
                nav.closeSidebar()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DSColor.inkPrimary)
                    .frame(width: 34, height: 34)
                    .background(DSColor.surfaceSunken, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close navigation")

            Spacer()

            Text("DAYPAGE · 2026")
                .font(DSType.mono10)
                .tracking(2.0)
                .foregroundColor(DSColor.inkMuted)
        }
        .padding(.horizontal, 20)
        .padding(.top, 58)
        .padding(.bottom, 12)
    }

    // MARK: - Profile Row (museum-aesthetic)

    /// 46pt amber-gradient avatar + serif name + mono membership + chevron.
    private var profileRow: some View {
        Button {
            showAccountSheet = true
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: "C9A677"), Color(hex: "5D3000")],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 46, height: 46)
                    Text(sidebarVM.isLoggedIn ? sidebarVM.accountInitial : "·")
                        .font(DSFonts.serif(size: 20, weight: .semibold))
                        .foregroundColor(Color(hex: "FAF8F6"))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(profileName)
                        .font(DSFonts.serif(size: 19, weight: .semibold))
                        .foregroundColor(DSColor.inkPrimary)
                        .lineLimit(1)
                    Text(membershipLine)
                        .font(DSType.mono10)
                        .tracking(1.2)
                        .foregroundColor(DSColor.inkSubtle)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DSColor.inkSubtle)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var profileName: String {
        guard sidebarVM.isLoggedIn, !sidebarVM.accountEmail.isEmpty else { return "DayPage" }
        // Use the local part of the email as a friendly display name.
        return String(sidebarVM.accountEmail.prefix(while: { $0 != "@" }))
    }

    /// "MEMBER · SINCE <year>" using the real account creation year from the
    /// auth session. Falls back to a yearless "MEMBER" when signed out or the
    /// join year is unavailable, rather than printing a misleading hardcoded year.
    private var membershipLine: String {
        if let year = sidebarVM.joinYear {
            return "MEMBER · SINCE \(year)"
        }
        return "MEMBER"
    }

    // MARK: - Heatmap + Stats

    private var heatmapSection: some View {
        SidebarHeatmapView(
            counts: sidebarVM.heatmapCounts,
            totalEntries: sidebarVM.totalEntries16Weeks,
            streak: sidebarVM.currentStreak
        )
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }

    /// STREAK / PAGES / WORDS triplet on a single hairline-divided white card.
    private var statsSection: some View {
        HStack(spacing: 0) {
            statCell(label: "STREAK", value: "\(sidebarVM.currentStreak)", unit: "DAYS", first: true)
            statDivider
            statCell(label: "PAGES", value: "\(sidebarVM.totalPages)", unit: "TOTAL", first: false)
            statDivider
            statCell(label: "WORDS", value: formatWords(sidebarVM.totalWordCount), unit: "TOTAL", first: false)
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DSColor.surfaceWhite)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(DSColor.borderSubtle, lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.04), radius: 1, x: 0, y: 1)
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private func statCell(label: String, value: String, unit: String, first: Bool) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(DSType.mono9).tracking(1.4)
                .foregroundColor(DSColor.inkSubtle)
            Text(value)
                .font(DSFonts.serif(size: 22, weight: .semibold))
                .foregroundColor(DSColor.inkPrimary)
            Text(unit)
                .font(DSType.mono9).tracking(1.2)
                .foregroundColor(DSColor.inkSubtle)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    private var statDivider: some View {
        Rectangle()
            .fill(DSColor.borderSubtle)
            .frame(width: 0.5)
            .padding(.vertical, 12)
    }

    /// "58k" style compaction for the word stat.
    private func formatWords(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return "\(n / 1000)k" }
        return "\(n)"
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
                if nav.selectedTab != tab {
                    Haptics.light()
                }
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
