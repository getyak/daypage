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

    /// Disclosure state for the grouped activity + recent-days section
    /// (「记录足迹」) and the utilities group (「工具」) — both collapsed by
    /// default so the drawer opens to a single, calm screen.
    @AppStorage("sidebar.tracesExpanded") private var tracesExpanded = false
    @AppStorage("sidebar.toolsExpanded") private var toolsExpanded = false

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

                        navSection
                            .padding(.top, DSSpacing.xl2)

                        // 活动热力图 + 最近记录折叠进同一个「记录足迹」
                        // 折叠组（默认收起），让首屏只剩身份 + 导航。
                        tracesSection
                            .padding(.top, DSSpacing.sm)

                        // 动作中心 + 调度折叠进同一个「工具」组（默认
                        // 收起），计数在折叠行上仍然可见。
                        toolsSection
                            .padding(.top, DSSpacing.sm)

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
        .task(id: nav.isSidebarOpen) {
            // Covers the drawer's first presentation as well as later opens.
            // Wait for the slide to settle; SwiftUI cancels this scan if the
            // drawer closes before the delay completes.
            guard nav.isSidebarOpen else { return }
            do { try await Task.sleep(nanoseconds: 320_000_000) }
            catch { return }
            guard !Task.isCancelled, nav.isSidebarOpen else { return }
            await sidebarVM.refreshRecentDaysAsync()
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

    /// Activity heatmap — lives inside the collapsed 「记录足迹」 disclosure,
    /// whose container already applies the drawer's row inset.
    private var heatmapSection: some View {
        SidebarHeatmapView(
            counts: sidebarVM.heatmapCounts,
            totalEntries: sidebarVM.totalEntries16Weeks,
            streak: sidebarVM.currentStreak,
            longestStreak: sidebarVM.longestStreak,
            totalPages: sidebarVM.totalPages,
            totalWordCount: sidebarVM.totalWordCount
        )
        .padding(.horizontal, DSSpacing.xs)
        .padding(.top, DSSpacing.md)
    }

    // MARK: - Nav Items

    /// Primary nav: Today / Archive / Graph + the "Ask the past" agent (D1).
    /// Global Search lives in the Today / Archive headers (one unified
    /// SearchView) — the drawer's old duplicate search row is gone.
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
            askRow
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
                Text(NSLocalizedString("sidebar.tools.system_actions", value: "动作中心", comment: "System action center row"))
                    .font(DSType.bodyMD)
                    .foregroundColor(DSColor.inkMuted)
                Spacer(minLength: DSSpacing.sm)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar.system-actions")
        .accessibilityLabel(NSLocalizedString("sidebar.tools.system_actions", value: "动作中心", comment: "System action center row"))
        .accessibilityHint(NSLocalizedString("sidebar.tools.system_actions.hint", value: "查看并审批 DayPage 的系统动作提案", comment: "System action center hint"))
    }

    /// Entry to the "调度中心" (ScheduleHubView). Mirrors `askRow`
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

    // MARK: - Collapsed Groups (记录足迹 / 工具)

    /// Shared disclosure header for the two collapsed groups below the
    /// primary navigation: quiet label + optional count badge + rotating
    /// chevron. 44pt touch target, VoiceOver toggle state (expanded /
    /// collapsed), and a localized title/hint pair for locale parity.
    private func disclosureRow(
        title: String,
        hint: String,
        badge: String?,
        isExpanded: Bool,
        onToggle: @escaping () -> Void
    ) -> some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Text(title)
                    .font(DSType.mono9)
                    .foregroundColor(DSColor.inkMuted)
                    .tracking(1.2)
                if let badge {
                    Text(badge)
                        .font(DSType.mono9)
                        .foregroundColor(DSColor.inkMuted)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(DSColor.amberSoft, in: Capsule())
                }
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(DSColor.inkMuted)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
            }
            .padding(.leading, 48)  // align with nav text column (10 + 26 + 12)
            .padding(.trailing, DSSpacing.lg)
            .padding(.vertical, DSSpacing.sm)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(isExpanded
            ? NSLocalizedString("a11y.expanded", comment: "Disclosure expanded state")
            : NSLocalizedString("a11y.collapsed", comment: "Disclosure collapsed state"))
        .accessibilityHint(hint)
        .accessibilityAddTraits(.isButton)
    }

    /// 「记录足迹」— the activity heatmap and the recent-day jump list in ONE
    /// collapsed group below the primary navigation (default closed). The
    /// recent rows keep their "commit history" behavior: tapping jumps to
    /// that day's detail view in Archive.
    private var tracesSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            disclosureRow(
                title: NSLocalizedString("sidebar.traces", value: "记录足迹", comment: "Traces disclosure: activity heatmap + recent days"),
                hint: NSLocalizedString("sidebar.traces.hint", value: "显示或隐藏活动足迹与最近记录", comment: "Traces disclosure hint"),
                badge: sidebarVM.recentDays.isEmpty ? nil : "\(sidebarVM.recentDays.count)",
                isExpanded: tracesExpanded
            ) {
                Haptics.soft()
                withAnimation(Motion.respectReduceMotion(Motion.expand)) {
                    tracesExpanded.toggle()
                }
            }

            if tracesExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    if hasActivity {
                        heatmapSection
                    }
                    ForEach(sidebarVM.recentDays) { day in
                        recentRow(day: day)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, DSSpacing.md)
        .clipped()  // keep collapsing rows from sliding over the section below
    }

    /// 「工具」— action center + schedule hub in ONE collapsed group (default
    /// closed). Pending visibility is preserved: the collapsed row keeps the
    /// upcoming-reminder count badge, and the action center (approvals) stays
    /// one tap away inside — never hidden irretrievably.
    private var toolsSection: some View {
        let upcomingCount = flagStore.isEnabled(.captureReminder)
            ? reminderService.upcoming(limit: 99).count
            : 0
        return VStack(alignment: .leading, spacing: 2) {
            disclosureRow(
                title: NSLocalizedString("sidebar.tools", value: "工具", comment: "Utilities disclosure: action center + schedule"),
                hint: NSLocalizedString("sidebar.tools.hint", value: "显示或隐藏动作中心与调度", comment: "Utilities disclosure hint"),
                badge: upcomingCount > 0 ? "\(upcomingCount)" : nil,
                isExpanded: toolsExpanded
            ) {
                Haptics.soft()
                withAnimation(Motion.respectReduceMotion(Motion.expand)) {
                    toolsExpanded.toggle()
                }
            }

            if toolsExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    systemActionsRow
                    if flagStore.isEnabled(.captureReminder) {
                        scheduleRow
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, DSSpacing.md)
        .clipped()
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
