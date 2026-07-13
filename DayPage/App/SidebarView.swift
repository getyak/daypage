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
                                .padding(.top, 18)
                        }

                        // Always show feedback row at the bottom of the
                        // scrollable area so it stays reachable even when the
                        // Recent list grows.
                        feedbackSection
                            .padding(.top, 18)
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
        .padding(.top, 58)
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
                .font(DSFonts.serif(size: 22, weight: .semibold))
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
            navItem(tab: .archive, icon: "archivebox",
                    label: NSLocalizedString("sidebar.nav.archive", comment: "Archive nav"))
            navItem(tab: .graph, icon: "point.3.connected.trianglepath.dotted",
                    label: NSLocalizedString("sidebar.nav.graph", comment: "Graph nav"))
            // Issue #16 (2026-07-03): global-search row. Between the
            // structured tabs (Today/Archive/Graph) and the memory-chat
            // agent so the sidebar reads as a top-down "cite → filter →
            // ask" ladder.
            searchRow
            askRow
        }
        .padding(.horizontal, DSSpacing.md)
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
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Color.clear)
                    .frame(width: 2, height: 20)
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 20)
                    .foregroundColor(DSColor.inkMuted)
                Text("搜索")
                    .font(DSType.bodyMD)
                    .foregroundColor(DSColor.inkMuted)
            }
            .padding(.trailing, DSSpacing.lg)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar.search")
        .accessibilityLabel("全局搜索")
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
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Color.clear)
                    .frame(width: 2, height: 20)
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 20)
                    .foregroundColor(DSColor.inkMuted)
                Text(NSLocalizedString("sidebar.ask_past", comment: "Ask the past chat entry"))
                    .font(DSType.bodyMD)
                    .foregroundColor(DSColor.inkMuted)
            }
            .padding(.trailing, DSSpacing.lg)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString("sidebar.ask_past", comment: "Ask the past chat entry"))
        .accessibilityHint(NSLocalizedString("sidebar.ask_past.hint", comment: "Ask based on your notes"))
    }

    private var feedbackSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionLabel("Support")
            navItem(tab: .feedback, icon: "bubble.left.and.exclamationmark.bubble.right",
                    label: NSLocalizedString("sidebar.nav.feedback", comment: "Feedback nav"))
        }
        .padding(.horizontal, DSSpacing.md)
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
                // Left amber accent strip
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(isActive ? DSColor.accentOnBg : Color.clear)
                    .frame(width: 2, height: 20)

                Image(systemName: icon)
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 20)
                    .foregroundColor(
                        disabled ? DSColor.inkSubtle
                        : isActive ? DSColor.accentOnBg
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
                        .foregroundColor(DSColor.inkMuted)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(DSColor.amberSoft, in: Capsule())
                }
            }
            .padding(.leading, 0)
            .padding(.trailing, DSSpacing.lg)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isActive ? DSColor.amberSoft : Color.clear)
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
            .padding(.leading, 34)  // align with row text column (2 + 12 + 20)
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

    private func recentRow(day: RecentDay) -> some View {
        Button {
            nav.openArchive(at: day.dateString)
        } label: {
            HStack(spacing: DSSpacing.md) {
                Color.clear.frame(width: 2, height: 20)

                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .frame(width: 20)
                    .foregroundColor(DSColor.accentOnBg.opacity(0.75))

                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.formatRowTitle(day.dateString))
                        .font(DSType.bodySM)
                        .foregroundColor(DSColor.inkPrimary)
                    Text(day.dateString)
                        .font(DSType.mono9)
                        .foregroundColor(DSColor.inkMuted)
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

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(DSType.mono9)
            .foregroundColor(DSColor.inkMuted)
            .tracking(1.2)
            .textCase(.uppercase)
            .padding(.leading, 34)  // align with row text column (2 + 12 + 20)
            .padding(.bottom, DSSpacing.xs)
            // Use isHeader so VoiceOver rotor lists these as section titles
            // rather than skipping them; users can jump between sections.
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Bottom Section

    private var bottomSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Settings
            Button {
                Haptics.tapConfirm()
                showSettings = true
            } label: {
                HStack(spacing: DSSpacing.md) {
                    Color.clear.frame(width: 2, height: 20)
                    Image(systemName: "gearshape")
                        .font(.system(size: 16, weight: .regular))
                        .frame(width: 20)
                        .foregroundColor(DSColor.inkMuted)
                    Text(NSLocalizedString("sidebar.settings", comment: "Settings row"))
                        .font(DSType.bodyMD)
                        .foregroundColor(DSColor.inkMuted)
                }
                .padding(.trailing, DSSpacing.lg)
                .padding(.vertical, 11)
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
                Color.clear.frame(width: 2, height: 20)
                ZStack {
                    Circle()
                        .fill(DSColor.amberSoft)
                        .frame(width: 28, height: 28)
                        .overlay(Circle().strokeBorder(DSColor.amberRim, lineWidth: 0.5))
                    Text(initial)
                        .font(DSType.labelSM)
                        .foregroundColor(DSColor.accentOnBg)
                }
                .frame(width: 20)
                Text(email)
                    .font(DSType.bodySM)
                    .foregroundColor(DSColor.inkMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.trailing, DSSpacing.lg)
            .padding(.vertical, 9)
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
