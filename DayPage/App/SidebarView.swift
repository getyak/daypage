import SwiftUI
import UIKit
import DayPageServices

// MARK: - SidebarView

struct SidebarView: View {

    @EnvironmentObject private var nav: AppNavigationModel
    @EnvironmentObject private var authService: AuthService
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @EnvironmentObject private var sidebarVM: SidebarViewModel
    @State private var showSettings = false
    @State private var showAccountSheet = false

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

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        profileRow
                        if hasActivity {
                            heatmapSection
                        }

                        navSection
                            .padding(.top, DSSpacing.xl2)

                        if !sidebarVM.recentDays.isEmpty {
                            recentSection
                                .padding(.top, DSSpacing.sm)
                        }
                        if dynamicTypeSize.isAccessibilitySize {
                            bottomSection
                        }
                    }
                    .padding(.bottom, DSSpacing.xl2)
                }

                if !dynamicTypeSize.isAccessibilitySize {
                    Rectangle()
                        .fill(DSColor.inkFaint)
                        .frame(height: 0.5)
                    bottomSection
                }
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

    /// A single dismissal control is enough here. The app name and year were
    /// decorative chrome that competed with the account and navigation.
    private var brandHeader: some View {
        HStack {
            Button {
                Haptics.soft()
                nav.closeSidebar()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DSColor.inkPrimary)
                    .frame(width: 44, height: 44)
                    .background(DSColor.surfaceWhite.opacity(0.56), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("a11y.nav.close", comment: "Sidebar close button"))

            Spacer()
        }
        .padding(.horizontal, DSSpacing.xl)
        .padding(.top, 44)
        .padding(.bottom, DSSpacing.sm)
    }

    // MARK: - Profile Row

    /// Identity and one clear action. Membership metadata belongs in the
    /// account sheet, not in the navigation drawer.
    private var profileRow: some View {
        Button {
            Haptics.tapConfirm()
            showAccountSheet = true
        } label: {
            HStack(spacing: DSSpacing.md) {
                ZStack {
                    Circle()
                        .fill(DSColor.surfaceSunken)
                        .frame(width: 40, height: 40)
                    if sidebarVM.isLoggedIn {
                        Text(sidebarVM.accountInitial)
                            .font(.headline.weight(.semibold))
                            .foregroundColor(DSColor.accentOnBg)
                    } else {
                        Image(systemName: "person")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(DSColor.inkSecondary)
                            .accessibilityHidden(true)
                    }
                }

                Text(profileName)
                    .font(.headline.weight(.semibold))
                    .foregroundColor(DSColor.inkPrimary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()

                if !sidebarVM.isLoggedIn && !dynamicTypeSize.isAccessibilitySize {
                    Text(NSLocalizedString("sidebar.profile.sync", value: "Sync", comment: "Account sync action"))
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(DSColor.accentOnBg)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DSColor.inkSubtle)
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, DSSpacing.xl)
        .padding(.vertical, DSSpacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(profileName)
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

    // MARK: - Activity

    private var hasActivity: Bool {
        sidebarVM.totalEntries16Weeks > 0
            || sidebarVM.totalPages > 0
            || sidebarVM.totalWordCount > 0
    }

    private var heatmapSection: some View {
        SidebarHeatmapView(
            counts: sidebarVM.heatmapCounts,
            totalEntries: sidebarVM.totalEntries16Weeks,
            streak: sidebarVM.currentStreak,
            longestStreak: sidebarVM.longestStreak,
            totalPages: sidebarVM.totalPages,
            totalWordCount: sidebarVM.totalWordCount
        )
        .padding(.horizontal, DSSpacing.xl)
        .padding(.top, DSSpacing.md)
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
            // A quiet gap separates destinations (Today / Archive / Graph)
            // from tools that act across those destinations. A divider or
            // another all-caps label added hierarchy chrome the drawer does
            // not need; six points is enough to make the two groups scan.
            Color.clear
                .frame(height: 6)
                .accessibilityHidden(true)
            // Issue #16 (2026-07-03): global-search row. Between the
            // structured tabs (Today/Archive/Graph) and the memory-chat
            // agent so the sidebar reads as a top-down "cite → filter →
            // ask" ladder.
            searchRow
            askRow
            systemActionsRow
            // Schedule hub — capture-reminder CRUD lives here. Gated by the
            // same feature flag as the reminder scheduler, so it disappears
            // entirely when the flag is off (kill switch parity).
            if flagStore.isEnabled(.captureReminder) {
                scheduleRow
            }
        }
        .padding(.horizontal, DSSpacing.md)
    }

    /// The trust boundary is a first-class destination, not a settings toggle:
    /// pending proposals, exact approval revisions, receipts, reconciliation
    /// and undo are all visible from this single surface.
    private var systemActionsRow: some View {
        Button {
            Haptics.light()
            nav.closeSidebar()
            nav.systemActionPresentation = .center(selectedProposalID: nil)
        } label: {
            HStack(spacing: DSSpacing.md) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 26, height: 26)
                    .foregroundColor(DSColor.inkMuted)
                Text("动作中心")
                    .font(DSType.bodyMD)
                    .foregroundColor(DSColor.inkMuted)
                Spacer(minLength: DSSpacing.sm)
                if !dynamicTypeSize.isAccessibilitySize {
                    Text("REVIEW")
                        .font(DSType.mono9)
                        .tracking(1.1)
                        .foregroundColor(DSColor.accentOnBg)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(DSColor.amberSoft, in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar.system-actions")
        .accessibilityLabel("动作中心")
        .accessibilityHint("查看并审批 DayPage 的系统动作提案")
    }

    /// Entry to the "调度中心" (ScheduleHubView). Mirrors `askRow`/`searchRow`
    /// styling, plus a mono badge showing how many reminders will fire next so
    /// the drawer surfaces at-a-glance scheduling state. Closes the drawer,
    /// then presents the hub as a sheet (Settings-style).
    private var scheduleRow: some View {
        let upcomingCount = reminderService.upcoming(limit: 99).count
        return Button {
            Haptics.light()
            // sheet 由 RootView 挂在 nav.showScheduleHub 上(全局稳定层),关抽屉
            // 不会影响它 —— 所以同 tick closeSidebar + 置 true 即可,无需延迟。
            // (旧法把 sheet 挂在 SidebarView 上,抽屉离屏后其 @State 失活,呈现被丢。)
            nav.closeSidebar()
            nav.showScheduleHub = true
        } label: {
            sidebarRowLabel(
                icon: "clock",
                label: NSLocalizedString("sidebar.nav.schedule", value: "调度", comment: "Schedule hub nav row"),
                badge: upcomingCount > 0 ? "\(upcomingCount)" : nil
            )
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
            sidebarRowLabel(
                icon: "magnifyingglass",
                label: NSLocalizedString("sidebar.nav.search", comment: "Search nav row")
            )
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
            sidebarRowLabel(
                icon: "sparkles",
                label: NSLocalizedString("sidebar.ask_past", comment: "Ask the past chat entry")
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar.ask-past")
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
            sidebarRowLabel(
                icon: icon,
                label: label,
                isActive: isActive,
                isDisabled: disabled,
                badge: disabled ? "Post-MVP" : nil
            )
        }
        .disabled(disabled)
        .buttonStyle(.plain)
        .accessibilityIdentifier(sidebarIdentifier(for: tab))
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

    private func sidebarIdentifier(for tab: AppTab) -> String {
        switch tab {
        case .today: return "sidebar.tab.today"
        case .archive: return "sidebar.tab.archive"
        case .graph: return "sidebar.tab.graph"
        case .feedback: return "sidebar.tab.feedback"
        }
    }

    private func sidebarRowLabel(
        icon: String,
        label: String,
        isActive: Bool = false,
        isDisabled: Bool = false,
        badge: String? = nil
    ) -> some View {
        HStack(spacing: DSSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(
                    isDisabled ? DSColor.inkSubtle
                    : isActive ? DSColor.accentOnBg
                    : DSColor.inkSecondary
                )
                .frame(width: 24, height: 24)

            Text(label)
                .font(.body.weight(isActive ? .semibold : .regular))
                .foregroundColor(
                    isDisabled ? DSColor.inkSubtle
                    : isActive ? DSColor.inkPrimary
                    : DSColor.inkSecondary
                )

            Spacer(minLength: DSSpacing.sm)

            if let badge {
                Text(badge)
                    .font(.caption2.weight(.medium))
                    .foregroundColor(DSColor.inkMuted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(DSColor.surfaceSunken, in: Capsule())
            }
        }
        .padding(.horizontal, DSSpacing.md)
        .frame(minHeight: 52)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous)
                .fill(isActive ? DSColor.amberSoft : Color.clear)
        )
        .contentShape(Rectangle())
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
            .frame(minHeight: 44)
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
            .frame(minHeight: 44)
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
                sidebarRowLabel(
                    icon: "gearshape",
                    label: NSLocalizedString("sidebar.settings", comment: "Settings row")
                )
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(NSLocalizedString("a11y.settings", comment: "Settings entry"))
            .accessibilityHint(NSLocalizedString("a11y.settings.hint", comment: "Opens app settings"))
            .accessibilityAddTraits(.isButton)

        }
        .padding(.horizontal, DSSpacing.md)
        .padding(.vertical, DSSpacing.sm)
        .padding(.bottom, DSSpacing.xl2)
    }

    // MARK: - Date Formatting

    private static func formatRowTitle(_ dateString: String) -> String {
        RelativeDate.label(for: dateString, style: .natural)
    }
}
