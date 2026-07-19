import SwiftUI
import UIKit
import DayPageServices

// MARK: - SidebarView

struct SidebarView: View {

    @EnvironmentObject private var nav: AppNavigationModel
    @EnvironmentObject private var authService: AuthService

    @EnvironmentObject private var sidebarVM: SidebarViewModel
    @State private var showSettings = false
    @State private var showAccountSheet = false
    @State private var showSchedule = false

    /// Live reminder service — drives the schedule row's "upcoming" badge and
    /// the feature-flag gate. Shared singleton so it stays in sync with Today.
    @StateObject private var reminderService = CaptureReminderService.shared
    @StateObject private var flagStore = FeatureFlagStore.shared

    /// Disclosure state for the Recent jump list — collapsed by default so
    /// the drawer opens to a single, calm screen (heatmap + stats + nav).
    @AppStorage("sidebar.recentExpanded") private var recentExpanded = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Liquid Glass drawer — dual-track (Phase 2 demo).
            // iOS 26 → native .glassEffect panel: drops the opaque cream base
            //          so the drawer genuinely refracts the timeline behind it.
            // iOS 16–25 → warm cream base + ultraThinMaterial (current look).
            // See docs/liquid-glass-vNext.md.
            sidebarBackground
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
                    .padding(.bottom, DSSpacing.sm)

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
                                .padding(.top, 22)
                        }
                    }
                    .padding(.bottom, DSSpacing.xl2)
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
            //
            // Defer the vault scan until AFTER the 0.28s slide animation
            // completes. Firing it on the opening frame used to publish four
            // @Published updates (recentDays / streakDays / heatmapCounts /
            // stats) into the middle of the slide, which re-invalidated the
            // drawer subtree and produced the "一闪一闪" that the user reported.
            // Waiting a beat lets the panel finish sliding first, then the
            // stats fade in without fighting the transform.
            if isOpen {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 320_000_000)
                    guard nav.isSidebarOpen else { return }
                    sidebarVM.refreshRecentDays()
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showSchedule) {
            NavigationStack { ScheduleHubView() }
        }
        .sheet(isPresented: $showAccountSheet) {
            AccountSheet()
        }
    }

    // MARK: - Drawer Background (dual-track Liquid Glass)

    /// Drawer background routed through the dual-track engine (#771):
    /// iOS 26 → native glass panel that refracts the timeline behind it;
    /// iOS 16–25 → warm faux-glass; Reduce Transparency → opaque warm fill.
    /// This replaces the bespoke hand-written OS branch — `dpGlass` is exactly
    /// the abstraction this property used to inline.
    private var sidebarBackground: some View {
        Color.clear.dpGlass(.panel, in: Rectangle())
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
            .accessibilityLabel(NSLocalizedString("a11y.nav.close", comment: "Sidebar close button"))

            Spacer()

            Text("DAYPAGE · 2026")
                .font(DSType.mono10)
                .tracking(2.0)
                .foregroundColor(DSColor.inkMuted)
                // Wordmark — purely decorative; VoiceOver users land on the
                // close button and then go straight into the profile row.
                .accessibilityHidden(true)
        }
        .padding(.horizontal, DSSpacing.xl)
        .padding(.top, 44)
        .padding(.bottom, DSSpacing.md)
    }

    // MARK: - Profile Row (museum-aesthetic)

    /// 46pt amber-gradient avatar + serif name + mono membership + chevron.
    private var profileRow: some View {
        Button {
            Haptics.tapConfirm()
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
                        .font(DSFonts.serif(size: 20, weight: .semibold, relativeTo: .title3))
                        .foregroundColor(Color(hex: "FAF8F6"))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(profileName)
                        .font(DSFonts.serif(size: 19, weight: .semibold, relativeTo: .title3))
                        .foregroundColor(DSColor.inkPrimary)
                        .lineLimit(1)
                    Text(membershipLine)
                        .font(DSType.mono10)
                        .tracking(1.2)
                        .foregroundColor(DSColor.inkMuted)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DSColor.inkMuted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, DSSpacing.xl)
        .padding(.vertical, 10)
        // Merge avatar + name + membership line into a single VoiceOver focus
        // so the user hears "<name>, <membership>" once instead of three
        // separate elements that read as "·, Local Account, LOCAL · TAP TO SYNC".
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(profileName), \(membershipLine)")
        .accessibilityHint(sidebarVM.isLoggedIn
            ? "Opens account details"
            : "Opens sign-in"
        )
    }

    private var profileName: String {
        guard sidebarVM.isLoggedIn, !sidebarVM.accountEmail.isEmpty else {
            return NSLocalizedString("sidebar.profile.local_account", comment: "")
        }
        return String(sidebarVM.accountEmail.prefix(while: { $0 != "@" }))
    }

    /// "MEMBER · SINCE <year>" using the real account creation year from the
    /// auth session. Falls back to a local-account hint when signed out.
    private var membershipLine: String {
        if let year = sidebarVM.joinYear {
            return "MEMBER · SINCE \(year)"
        }
        if sidebarVM.isLoggedIn {
            return "MEMBER"
        }
        return NSLocalizedString("sidebar.profile.tap_to_sync", comment: "")
    }

    // MARK: - Heatmap + Stats

    private var heatmapSection: some View {
        SidebarHeatmapView(
            counts: sidebarVM.heatmapCounts,
            totalEntries: sidebarVM.totalEntries16Weeks,
            streak: sidebarVM.currentStreak,
            longestStreak: sidebarVM.longestStreak
        )
        .padding(.horizontal, DSSpacing.xl)
        .padding(.top, DSSpacing.xs)
    }

    /// STREAK / PAGES / WORDS triplet on a single hairline-divided white card.
    private var statsSection: some View {
        HStack(spacing: 0) {
            let streakUnit = sidebarVM.longestStreak > sidebarVM.currentStreak
                ? "BEST \(sidebarVM.longestStreak)"
                : "DAYS"
            statCell(label: "STREAK", value: "\(sidebarVM.currentStreak)", unit: streakUnit, first: true)
                .accessibilityLabel(sidebarVM.longestStreak > sidebarVM.currentStreak
                    ? "Streak \(sidebarVM.currentStreak) days, personal best \(sidebarVM.longestStreak) days"
                    : "Streak \(sidebarVM.currentStreak) days"
                )
            statDivider
            statCell(label: "DAILIES", value: "\(sidebarVM.totalPages)", unit: "COMPILED", first: false)
                .accessibilityLabel("\(sidebarVM.totalPages) dailies compiled")
            statDivider
            statCell(label: "WORDS", value: formatWords(sidebarVM.totalWordCount), unit: "TOTAL", first: false)
                .accessibilityLabel("\(sidebarVM.totalWordCount) words total")
        }
        .background(
            RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                .fill(DSColor.surfaceWhite)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                .strokeBorder(DSColor.borderSubtle, lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.04), radius: 1, x: 0, y: 1)
        .padding(.horizontal, DSSpacing.xl)
        .padding(.top, DSSpacing.md)
    }

    private func statCell(label: String, value: String, unit: String, first: Bool) -> some View {
        VStack(spacing: DSSpacing.xs) {
            Text(label)
                .font(DSType.mono9).tracking(1.4)
                .foregroundColor(DSColor.inkMuted)
            Text(value)
                .font(DSFonts.serif(size: 22, weight: .semibold, relativeTo: .title2))
                .foregroundColor(DSColor.inkPrimary)
            Text(unit)
                .font(DSType.mono9).tracking(1.2)
                .foregroundColor(DSColor.inkMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        // Each stat cell reads as one focus (e.g. "STREAK 5 BEST 12") instead
        // of three separate StaticText nodes. Call sites that need a richer
        // phrase override via `.accessibilityLabel(...)`.
        .accessibilityElement(children: .combine)
    }

    private var statDivider: some View {
        Rectangle()
            .fill(DSColor.borderSubtle)
            .frame(width: 0.5)
            .padding(.vertical, DSSpacing.md)
            .accessibilityHidden(true)
    }

    /// "58k" style compaction for the word stat.
    private func formatWords(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return "\(n / 1000)k" }
        return "\(n)"
    }

    // MARK: - Nav Items

    /// Primary nav: Today / Archive / Graph + the "Ask the past" agent (D1).
    private var navSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            navItem(tab: .today, icon: "square.and.pencil",
                    label: NSLocalizedString("sidebar.nav.today", comment: "Today nav"))
            // Icon set rationale (W1 redesign): one optical family, all
            // `.medium` weight. `books.vertical` reads "bound journals"
            // (archivebox read "cardboard box"); `circle.hexagongrid` stays
            // crisp at 16pt where the dotted-triangle graph glyph smeared.
            navItem(tab: .archive, icon: "books.vertical",
                    label: NSLocalizedString("sidebar.nav.archive", comment: "Archive nav"))
            navItem(tab: .graph, icon: "circle.hexagongrid",
                    label: NSLocalizedString("sidebar.nav.graph", comment: "Graph nav"))
            // Issue #16 (2026-07-03): global-search row. Between the
            // structured tabs (Today/Archive/Graph) and the memory-chat
            // agent so the sidebar reads as a top-down "cite → filter →
            // ask" ladder.
            searchRow
            askRow
            // Schedule hub — capture-reminder CRUD lives here. Gated by the
            // same feature flag as the reminder scheduler, so it disappears
            // entirely when the flag is off (kill switch parity).
            if flagStore.isEnabled(.captureReminder) {
                scheduleRow
            }
        }
        .padding(.horizontal, DSSpacing.md)
    }

    /// Entry to the "调度中心" (ScheduleHubView). Mirrors `askRow`/`searchRow`
    /// styling, plus a mono badge showing how many reminders will fire next so
    /// the drawer surfaces at-a-glance scheduling state. Closes the drawer,
    /// then presents the hub as a sheet (Settings-style).
    private var scheduleRow: some View {
        let upcomingCount = reminderService.upcoming(limit: 99).count
        return Button {
            Haptics.light()
            // closeSidebar() 会 animate 抽屉离屏并标 .accessibilityHidden;若在
            // 同一 tick 里 showSchedule = true,SidebarView(sheet 宿主)正被移出,
            // .sheet 呈现被抑制 → 点了没反应(实测)。等关闭动画走完再弹,复用
            // 本文件 recentDays 刷新用的同款延迟模式。
            nav.closeSidebar()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 320_000_000)
                showSchedule = true
            }
        } label: {
            HStack(spacing: DSSpacing.md) {
                Image(systemName: "clock")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 26, height: 26)
                    .foregroundColor(DSColor.inkMuted)
                Text(NSLocalizedString("sidebar.nav.schedule", value: "调度", comment: "Schedule hub nav row"))
                    .font(DSType.bodyMD)
                    .foregroundColor(DSColor.inkMuted)
                if upcomingCount > 0 {
                    Spacer(minLength: DSSpacing.sm)
                    Text("\(upcomingCount)")
                        .font(DSType.mono9)
                        .foregroundColor(DSColor.inkMuted)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(DSColor.amberSoft, in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar.schedule")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(NSLocalizedString("sidebar.nav.schedule", value: "调度", comment: "Schedule hub nav row"))
        .accessibilityValue(upcomingCount > 0
            ? String(format: NSLocalizedString("sidebar.schedule.upcoming", value: "%d 条即将触发", comment: "Upcoming reminders count"), upcomingCount)
            : "")
        .accessibilityHint(NSLocalizedString("sidebar.schedule.hint", value: "打开调度中心", comment: "Schedule hub hint"))
    }

    /// Issue #16 (2026-07-03): entry to the app-wide SearchView. Reuses
    /// AppNavigationModel.pendingSearchQuery — the same rail the URL
    /// scheme `daypage://search?q=` already flows through — so a single
    /// downstream consumer keeps its authority.
    private var searchRow: some View {
        Button {
            Haptics.light()
            nav.closeSidebar()
            nav.selectedTab = .archive
            nav.pendingSearchQuery = ""
        } label: {
            HStack(spacing: DSSpacing.md) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 26, height: 26)
                    .foregroundColor(DSColor.inkMuted)
                Text(NSLocalizedString("sidebar.nav.search", comment: "Search nav row"))
                    .font(DSType.bodyMD)
                    .foregroundColor(DSColor.inkMuted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar.search")
        .accessibilityLabel(NSLocalizedString("sidebar.nav.search.a11y", comment: "Global search a11y label"))
    }

    /// In-app entry point for the D1 "和过去对话" memory-chat agent. Without
    /// this the agent is only reachable via the Siri/Shortcuts intent, leaving
    /// it invisible to most users. Tapping seeds `pendingAskQuery` with an empty
    /// string so RootView presents AskPastView in its empty-prompt state.
    private var askRow: some View {
        Button {
            Haptics.light()
            nav.closeSidebar()
            nav.pendingAskQuery = ""
        } label: {
            HStack(spacing: DSSpacing.md) {
                // `sparkles` — the AI-voice glyph. The old compound
                // `sparkle.magnifyingglass` collided with the search row's
                // magnifier one row above.
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 26, height: 26)
                    .foregroundColor(DSColor.inkMuted)
                Text(NSLocalizedString("sidebar.ask_past", comment: "Ask the past chat entry"))
                    .font(DSType.bodyMD)
                    .foregroundColor(DSColor.inkMuted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString("sidebar.ask_past", comment: "Ask the past chat entry"))
        .accessibilityHint(NSLocalizedString("sidebar.ask_past.hint", comment: "Ask based on your notes"))
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
            HStack(spacing: DSSpacing.md) {
                // Icon on a soft 26pt backing when active — the selection
                // reads as one warm rounded block instead of the old edge-to-
                // edge fill + 2pt "toothpick" strip.
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(
                        disabled ? DSColor.inkSubtle
                        : isActive ? DSColor.accentOnBg
                        : DSColor.inkMuted
                    )
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isActive ? DSColor.accentOnBg.opacity(0.12) : Color.clear)
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
                        .foregroundColor(DSColor.inkMuted)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(DSColor.amberSoft, in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isActive ? DSColor.amberSoft : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .disabled(disabled)
        .buttonStyle(.plain)
        // Merge the amber strip + icon + label + "Post-MVP" badge into one
        // focus, then announce the destination + selection state.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityHint(disabled
            ? "Coming after MVP"
            : (tab == .feedback ? "Opens feedback" : "Navigates to \(label)")
        )
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Recent Section

    /// "Commit history" style list: the most recent days that actually have
    /// memos, tapping a row jumps straight to that day's detail view in
    /// Archive. Refreshed on every sidebar open via `refreshRecentDays()`.
    ///
    /// Collapsed by default — the heatmap above already tells the "recent
    /// activity" story at a glance, so seven always-on list rows were
    /// redundant weight that forced the drawer to scroll. The disclosure
    /// state persists across launches for users who want the jump list open.
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            recentDisclosureRow

            if recentExpanded {
                ForEach(sidebarVM.recentDays) { day in
                    recentRow(day: day)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, DSSpacing.md)
        .clipped()  // keep collapsing rows from sliding over the section below
    }

    /// Section header doubling as the expand/collapse control: mono label +
    /// day count + rotating chevron, styled like `sectionLabel` so the
    /// museum-aesthetic ladder stays intact.
    private var recentDisclosureRow: some View {
        Button {
            Haptics.soft()
            withAnimation(Motion.respectReduceMotion(Motion.expand)) {
                recentExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Text("Recent")
                    .font(DSType.mono9)
                    .foregroundColor(DSColor.inkMuted)
                    .tracking(1.2)
                    .textCase(.uppercase)
                Text("\(sidebarVM.recentDays.count)")
                    .font(DSType.mono9)
                    .foregroundColor(DSColor.inkMuted)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(DSColor.amberSoft, in: Capsule())
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(DSColor.inkMuted)
                    .rotationEffect(.degrees(recentExpanded ? 0 : -90))
            }
            .padding(.leading, 48)  // align with nav text column (10 + 26 + 12)
            .padding(.trailing, DSSpacing.lg)
            .padding(.vertical, DSSpacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(NSLocalizedString("sidebar.recent", comment: "Recent section toggle"))
        .accessibilityValue(recentExpanded
            ? NSLocalizedString("a11y.expanded", comment: "Disclosure expanded state")
            : NSLocalizedString("a11y.collapsed", comment: "Disclosure collapsed state"))
        .accessibilityHint(NSLocalizedString("sidebar.recent.hint", comment: "Recent toggle hint"))
        .accessibilityAddTraits(.isButton)
    }

    /// Ledger-style jump row: relative date + one-line teaser, bare mono
    /// count on the right. (W1: the 6pt amber dot carried no information and
    /// the per-row count capsule duplicated the disclosure badge.)
    private func recentRow(day: RecentDay) -> some View {
        Button {
            nav.openArchive(at: day.dateString)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: DSSpacing.sm) {
                Text(Self.formatRowTitle(day.dateString))
                    .font(DSType.bodySM)
                    .foregroundColor(DSColor.inkPrimary)
                    .layoutPriority(1)

                if let excerpt = day.excerpt, !excerpt.isEmpty {
                    Text("· \(excerpt)")
                        .font(DSType.bodySM)
                        .foregroundColor(DSColor.inkMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: DSSpacing.sm)

                Text("\(day.memoCount)")
                    .font(DSType.mono10)
                    .foregroundColor(DSColor.inkMuted)
            }
            .padding(.leading, 48)  // align with nav text column (10 + 26 + 12)
            .padding(.trailing, DSSpacing.lg)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // "Today, 3 entries" / "Apr 13, 1 entry" — one phrase, then trait.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(Self.formatRowTitle(day.dateString)), \(day.memoCount) \(day.memoCount == 1 ? "entry" : "entries")")
        .accessibilityHint("Opens this day in Archive")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Bottom Section

    private var bottomSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Feedback — lives with Settings in the anchored bottom block
            // (W1: the old scroll-area "Support" section label was one layer
            // of hierarchy more than two utility rows deserve).
            navItem(tab: .feedback, icon: "paperplane",
                    label: NSLocalizedString("sidebar.nav.feedback", comment: "Feedback nav"))

            // Settings
            Button {
                Haptics.tapConfirm()
                showSettings = true
            } label: {
                HStack(spacing: DSSpacing.md) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 26, height: 26)
                        .foregroundColor(DSColor.inkMuted)
                    Text(NSLocalizedString("sidebar.settings", comment: "Settings row"))
                        .font(DSType.bodyMD)
                        .foregroundColor(DSColor.inkMuted)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(NSLocalizedString("a11y.settings", comment: "Settings entry"))
            .accessibilityHint(NSLocalizedString("a11y.settings.hint", comment: "Opens app settings"))
            .accessibilityAddTraits(.isButton)

            // Account (when logged in)
            if sidebarVM.isLoggedIn {
                accountRow
            }
        }
        .padding(.horizontal, DSSpacing.md)
        .padding(.vertical, DSSpacing.sm)
        .padding(.bottom, DSSpacing.xl2)
    }

    private var accountRow: some View {
        let email = sidebarVM.accountEmail
        let initial = sidebarVM.accountInitial

        return Button {
            Haptics.tapConfirm()
            showAccountSheet = true
        } label: {
            HStack(spacing: DSSpacing.md) {
                ZStack {
                    Circle()
                        .fill(DSColor.amberSoft)
                        .frame(width: 24, height: 24)
                        .overlay(Circle().strokeBorder(DSColor.amberRim, lineWidth: 0.5))
                    Text(initial)
                        .font(DSType.labelSM)
                        .foregroundColor(DSColor.accentOnBg)
                }
                .frame(width: 26, height: 26)
                Text(email)
                    .font(DSType.bodySM)
                    .foregroundColor(DSColor.inkMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Signed in as \(email)")
        .accessibilityHint("Opens account details")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Date Formatting

    private static func formatRowTitle(_ dateString: String) -> String {
        RelativeDate.label(for: dateString, style: .natural)
    }
}
