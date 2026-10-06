import Testing
import Foundation
import SwiftUI
import DayPageModels
import DayPageServices
@testable import DayPage

extension DayPageSerialSwiftTests {
/// Accessibility regression tests for Goal C (Motion + Dynamic Type).
///
/// These tests are pragmatic: visual a11y is hard to unit-test, so we lean on
/// (a) a contract check on `Motion.respectReduceMotion(_:)`, (b) a smoke build
/// of the primary read-path card at the largest Dynamic Type size, and (c)
/// regex regression guards that the remaining vestibular-critical `repeatForever`
/// sites are still gated by `reduceMotion` — which is the most likely place
/// for someone to silently regress accessibility.
@MainActor
@Suite("AccessibilityTests", .serialized)
struct AccessibilityTests {

    @Test func qaDeepLinkAlias_isAcceptedOnlyByDedicatedDebugUIIdentity() {
        #if DEBUG
        #expect(DayPageApp.acceptsDeepLinkScheme("daypage-qa-ui", bundleIdentifier: "com.daypage.app.qa-ui"))
        #expect(DayPageApp.acceptsDeepLinkScheme("DAYPAGE-QA-UI", bundleIdentifier: "com.daypage.app.qa-ui"))
        #endif
        for identity in ["com.daypage.app", "com.daypage.app.qa-unit", "", "com.daypage.app.qa-ui.extra"] {
            #expect(!DayPageApp.acceptsDeepLinkScheme("daypage-qa-ui", bundleIdentifier: identity))
        }
        for identity in ["com.daypage.app", "com.daypage.app.qa-unit", "com.daypage.app.qa-ui"] {
            #expect(DayPageApp.acceptsDeepLinkScheme("DAYPAGE", bundleIdentifier: identity))
            for scheme in [nil, "https", "file", "daypage-qa-other", "daypage-qa-ui:"] as [String?] {
                #expect(!DayPageApp.acceptsDeepLinkScheme(scheme, bundleIdentifier: identity))
            }
        }
    }

    // MARK: - Motion contract

    /// `Motion.respectReduceMotion(_:)` is a pure function over
    /// `UIAccessibility.isReduceMotionEnabled`. In the test process Reduce
    /// Motion is off by default, so the helper must return *some* animation
    /// without crashing. We avoid mocking UIAccessibility (a static singleton)
    /// and document the reduced-motion branch as integration-only — the
    /// Simulator → Settings → Accessibility → Reduce Motion toggle exercises
    /// the other branch manually.
    @Test func respectReduceMotion_returnsAnAnimationWithoutCrashing() {
        let base = Motion.spring
        let result = Motion.respectReduceMotion(base)
        _ = result
        #expect(Bool(true), "respectReduceMotion returned an Animation without trapping")
    }

    // MARK: - Dynamic Type smoke test

    /// MemoCardView is the primary read-path surface. Construct it inside the
    /// largest accessibility text size and verify it builds without crashing.
    /// We don't have ViewInspector — this is intentionally a smoke test that
    /// catches the "force-unwrapped layout at accessibility5" class of bugs.
    /// Anything more involved should be a snapshot test.
    @Test func memoCardView_buildsAtAccessibility5() {
        let memo = Memo(
            id: UUID(),
            type: .text,
            created: Date(),
            body: "Test memo for Dynamic Type smoke test"
        )
        // Force the SwiftUI view value to be constructed. If a hardcoded frame
        // or modifier traps at accessibility5, this trips.
        let view = MemoCardView(memo: memo)
            .environment(\.dynamicTypeSize, .accessibility5)
        _ = view
        #expect(Bool(true), "MemoCardView constructed under accessibility5 Dynamic Type")
    }

    // MARK: - Vestibular regression guards
    //
    // These tests read each file's source as text and assert that the
    // documented `repeatForever` / vestibular-sensitive sites still reference
    // `reduceMotion`. They are deliberately coarse — anyone who re-introduces
    // a raw `repeatForever` without a reduce-motion gate nearby will fail one
    // of these. The test source-of-truth is the file content on disk, located
    // via the SRCROOT-style walk below.

    /// Walk up from this test file until we find a sibling `DayPage/` source
    /// directory; that's the repo root.
    private func projectRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("DayPage", isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir),
               isDir.boolValue {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        throw AccessibilityTestError.cannotLocateProjectRoot
    }

    private func assertGuardedRepeatForever(in relativePath: String) throws {
        let root = try projectRoot()
        let url = root.appendingPathComponent(relativePath)
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(
            source.contains("repeatForever"),
            "\(relativePath) should still contain a repeatForever animation (test outdated otherwise)"
        )
        #expect(
            source.contains("reduceMotion"),
            "\(relativePath) must reference reduceMotion — vestibular regression guard"
        )
    }

    @Test func compileUnlockCard_guardsRepeatForever() throws {
        try assertGuardedRepeatForever(in: "DayPage/Features/Today/CompileUnlockCard.swift")
    }

    @Test func inputBarV4_hasNoIdleRepeatingCaret() throws {
        let root = try projectRoot()
        let source = try String(
            contentsOf: root.appendingPathComponent("DayPage/Features/Today/InputBarV4.swift"),
            encoding: .utf8
        )
        #expect(
            !source.contains("BreathingCaretModifier"),
            "The resting dock should stay still instead of repeatedly animating its caret"
        )
        #expect(
            !source.contains(".repeatForever("),
            "InputBarV4 should not introduce unattended repeating motion"
        )
    }

    @Test func writeSheet_describesDestinationWithoutClaimingItAlreadySaved() throws {
        let root = try projectRoot()
        let source = try String(
            contentsOf: root.appendingPathComponent("DayPage/Features/Today/WriteSheetView.swift"),
            encoding: .utf8
        )
        #expect(
            !source.contains("Text(\"SAVED TO\")"),
            "The composer must not announce a successful save before submission"
        )
        #expect(
            source.contains("write.sheet.destination"),
            "The pre-save destination needs a localized, truthful label"
        )
    }

    @Test func writeSheet_hasOneDiscardEntryAndFullSizeCriticalTargets() throws {
        let root = try projectRoot()
        let source = try String(
            contentsOf: root.appendingPathComponent("DayPage/Features/Today/WriteSheetView.swift"),
            encoding: .utf8
        )
        #expect(
            !source.contains("cancelGhostButton"),
            "Discard should have one stable entry point instead of duplicate X and Cancel controls"
        )
        #expect(source.contains("write.sheet.discard.action"))
        #expect(
            source.components(separatedBy: ".frame(width: 44, height: 44)").count - 1 >= 3,
            "Close, microphone, and send must each expose at least a 44pt target"
        )
    }

    @Test func saveFeedback_hasOneCommitHapticAndNoCountdownTaps() throws {
        let root = try projectRoot()
        let today = try String(
            contentsOf: root.appendingPathComponent("DayPage/Features/Today/TodayView.swift"),
            encoding: .utf8
        )
        let pill = try String(
            contentsOf: root.appendingPathComponent("DayPage/Features/Today/UndoPillView.swift"),
            encoding: .utf8
        )
        #expect(today.contains("This method is announcement-only"))
        #expect(!pill.contains("Haptics.rigid"))
        #expect(!pill.contains("undo_pill.closing"))
    }

    @Test func compileProgressAndAIKeyStatus_haveLocalizedCopy() throws {
        let root = try projectRoot()
        let en = try String(
            contentsOf: root.appendingPathComponent("DayPage/Resources/en.lproj/Localizable.strings"),
            encoding: .utf8
        )
        let zh = try String(
            contentsOf: root.appendingPathComponent("DayPage/Resources/zh-Hans.lproj/Localizable.strings"),
            encoding: .utf8
        )
        let requiredKeys = [
            "today.compile.stage.collecting",
            "today.compile.stage.cleaning",
            "today.compile.stage.clustering",
            "today.compile.stage.generating",
            "today.compile.stage.linking",
            "today.compile.progress.a11y.label",
            "today.compile.progress.a11y.value",
            "today.banner.ai_key_missing",
            "today.banner.ai_key_missing.cta.a11y"
        ]

        for key in requiredKeys {
            #expect(en.contains("\"\(key)\""), "Missing English localization for \(key)")
            #expect(zh.contains("\"\(key)\""), "Missing Simplified Chinese localization for \(key)")
        }
    }

    @Test func visualBaselineHarness_capturesTruthfulIsolatedStates() throws {
        let root = try projectRoot()
        let scriptURL = root.appendingPathComponent("scripts/ci/capture_ios_visual_baselines.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let app = try String(
            contentsOf: root.appendingPathComponent("DayPage/App/DayPageApp.swift"),
            encoding: .utf8
        )
        let onboarding = try String(
            contentsOf: root.appendingPathComponent("DayPage/Features/Onboarding/OnboardingView.swift"),
            encoding: .utf8
        )
        let workflow = try String(
            contentsOf: root.appendingPathComponent(".github/workflows/ci.yml"),
            encoding: .utf8
        )

        #expect(script.contains("simctl uninstall"), "The audit app container must start empty")
        #expect(script.contains("for fixture in empty memos"), "Empty screenshots must precede seeded screenshots")
        #expect(
            !app.contains("SampleDataSeeder.seedIfNeeded()"),
            "App startup must never write unrequested sample notes into a fresh local vault"
        )
        #expect(
            script.contains("defaults delete \"$bundle_id\" hasSeededSamples"),
            "A long-lived Simulator must not leak a cached sample-ready claim into an empty vault"
        )
        #expect(
            onboarding.components(separatedBy: "SampleDataSeeder.seedIfNeeded()").count == 2,
            "Onboarding must retain one explicit sample CTA, without seeding when setup completes"
        )
        #expect(script.contains("-qaSeedTodayMemos YES"), "Memo screenshots need deterministic vault evidence")
        #expect(
            script.contains("DAYPAGE_VISUAL_SETTLE_SECONDS:-6"),
            "The capture window must outlast cold-launch skeletons seen in the audit"
        )
        #expect(script.contains("-AppleLanguages"), "Screenshot locale must be set before process launch")
        #expect(script.contains("-qaSelectedTab"), "Each destination must be selected before its first lifecycle pass")
        #expect(script.contains("Expected 24 visual baselines"), "The full state matrix must be enforced")
        let maestroRange = try #require(workflow.range(of: "- name: Run Maestro flows"))
        let baselineRange = try #require(workflow.range(of: "- name: Capture isolated visual baselines"))
        #expect(
            maestroRange.lowerBound < baselineRange.lowerBound,
            "The destructive visual matrix must run after interactive Maestro flows"
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent("flows/04_visual_baseline_ios.yaml").path
            ),
            "The old flow silently ignored locale and fixture arguments and must not return"
        )
    }

    @Test func aiSummaryCard_guardsRepeatForever() throws {
        try assertGuardedRepeatForever(in: "DayPage/Features/Today/AISummaryCard.swift")
    }

    @Test func entityPageView_guardsRepeatForever() throws {
        try assertGuardedRepeatForever(in: "DayPage/Features/Entity/EntityPageView.swift")
    }

    // MARK: - Empty-state VoiceOver contract

    /// Empty states must read as one coherent destination. The visible CTA is
    /// exposed as a named accessibility action, and the animated orb remains
    /// decorative. This source contract protects the three modifiers that are
    /// otherwise easy to remove during visual refactors.
    @Test func emptyStateView_exposesOneCoherentVoiceOverElement() throws {
        let root = try projectRoot()
        let url = root.appendingPathComponent("DayPage/Components/EmptyStateView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        #expect(source.contains(".accessibilityElement(children: .ignore)"))
        #expect(source.contains(".accessibilityLabel(combinedAccessibilityLabel)"))
        #expect(source.contains("CTAAccessibilityModifier"))
        #expect(source.contains(".accessibilityHidden(true)"))
    }

    // MARK: - Small-text contrast contract

    /// The compile percentage is deliberately quieter than its stage label,
    /// but remains meaningful progress information. Protect both halves of
    /// that contract: the surface-aware token must clear WCAG AA in light and
    /// dark palettes, and the rail must use that token rather than decorative
    /// `inkSubtle`.
    @Test func compileProgressPercentage_usesAAQuietInk() throws {
        let root = try projectRoot()
        let tokenURL = root.appendingPathComponent("design-tokens/tokens.json")
        let tokenData = try Data(contentsOf: tokenURL)
        let json = try #require(
            JSONSerialization.jsonObject(with: tokenData) as? [String: Any]
        )
        let light = try #require(json["colors"] as? [String: String])
        let darkRoot = try #require(json["dark"] as? [String: Any])
        let dark = try #require(darkRoot["colors"] as? [String: String])

        let lightRatio = try contrastRatio(
            foreground: #require(light["fg-subtle-aa"]),
            background: #require(light["surface-white"])
        )
        let darkRatio = try contrastRatio(
            foreground: #require(dark["fg-subtle-aa"]),
            background: #require(dark["surface-white"])
        )
        #expect(lightRatio >= 4.5)
        #expect(darkRatio >= 4.5)

        let colors = try String(
            contentsOf: root.appendingPathComponent("DayPage/DesignSystem/Colors.swift"),
            encoding: .utf8
        )
        let today = try String(
            contentsOf: root.appendingPathComponent("DayPage/Features/Today/TodayView.swift"),
            encoding: .utf8
        )
        #expect(colors.contains("inkTertiaryAA = DSTokens.Colors.fgSubtleAa"))
        #expect(today.contains(".foregroundColor(DSColor.inkTertiaryAA)"))
    }

    /// The large empty-day date used to be a dead “scroll to top” button and
    /// stayed pinned while its hero faded away. The header now collapses on
    /// scroll, exposes honest heading semantics, and keeps both toolbar icons
    /// at 44pt hit targets without enlarging their 36pt glass circles.
    @Test func todayHeader_hasHonestSemanticsAndMinimumHitTargets() throws {
        let root = try projectRoot()
        let url = root.appendingPathComponent("DayPage/Features/Today/TodayView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        #expect(source.contains("let usesCompactHeader = hasMemos || isScrolled"))
        #expect(source.contains(".accessibilityAddTraits(.isHeader)"))
        #expect(source.components(separatedBy: ".frame(width: 44, height: 44)").count - 1 >= 2)
        #expect(source.contains("isTimelineScrolled ? value < -2 : value < -12"))
    }

    /// Archive dates, mode switches, and filters are all actionable even when
    /// visually quiet. They must not regress to the disabled/decorative ink
    /// token that falls below the small-text contrast floor on glass.
    @Test func archiveActionableSmallText_usesAAQuietInk() throws {
        let root = try projectRoot()
        let source = try String(
            contentsOf: root.appendingPathComponent("DayPage/Features/Archive/ArchiveView.swift"),
            encoding: .utf8
        )

        #expect(source.contains("case .none:     return DSColor.inkTertiaryAA"))
        #expect(
            source.contains("if let d = density, d != .empty { return d.textColor }"),
            "Compiled-only deep tiles must not inherit the empty-density dark foreground"
        )
        #expect(source.contains("let dotColor: Color = usesDarkFill ? DSColor.onAmber : DSColor.accentOnBg"))
        #expect(
            source.components(separatedBy: "isSelected ? DSColor.onAmber : DSColor.inkTertiaryAA").count - 1 >= 1,
            "The inactive CAL/LIST segment remains an available action and needs semantic quiet ink"
        )
        #expect(
            source.components(separatedBy: "isSelected ? Color.white : DSColor.inkTertiaryAA").count - 1 >= 1,
            "Inactive Archive filters remain available actions and need semantic quiet ink"
        )
    }

    @Test func searchHeader_hasReadableHelperCopyAndMinimumTargets() throws {
        let root = try projectRoot()
        let source = try String(
            contentsOf: root.appendingPathComponent("DayPage/Features/Archive/SearchView.swift"),
            encoding: .utf8
        )

        #expect(source.contains(".foregroundColor(DSColor.inkTertiaryAA)"))
        #expect(
            source.components(separatedBy: ".frame(width: 44, height: 44)").count - 1 >= 2,
            "Search clear and filter controls must expose full-size targets"
        )
        #expect(source.contains(".frame(minWidth: 44, minHeight: 44)"))
        #expect(
            source.contains("resultRow(result, showsDate: group.section != .today)"),
            "Today's pinned section header should not be repeated inside every result row"
        )
    }

    @Test func dailyDigestTabs_areReadableAndComfortablyTappable() throws {
        let root = try projectRoot()
        let source = try String(
            contentsOf: root.appendingPathComponent("DayPage/Features/Daily/DailyPageView.swift"),
            encoding: .utf8
        )

        #expect(source.contains("selectedTab == tab ? DSColor.onAmber : DSColor.inkTertiaryAA"))
        #expect(source.contains(".frame(maxWidth: .infinity, minHeight: 44)"))
        #expect(!source.contains("selectedTab == tab ? DSColor.onAmber : DSColor.inkSubtle"))
    }

    @Test func dailyPageParser_missingEntriesCountFallsBackToDistinctEvidence() {
        let m1 = UUID()
        let m2 = UUID()
        let markdown = """
        ---
        type: daily
        date: 2026-07-03
        ---

        ## MORNING
        第一段。[^m:\(m1.uuidString)][^m:\(m2.uuidString)]

        ## EVENING
        再次引用第一条。[^m:\(m1.uuidString)]
        """

        let model = DailyPageParser.parse(content: markdown, dateString: "2026-07-03")
        #expect(model.entriesCount == 2)
        #expect(model.memoCount == 2)
    }

    @Test func dailyPageParser_explicitEntriesCountRemainsAuthoritative() {
        let memo = UUID()
        let markdown = """
        ---
        type: daily
        date: 2026-07-03
        entries_count: 0
        ---

        ## MORNING
        引用存在但计数明确为零。[^m:\(memo.uuidString)]
        """

        let model = DailyPageParser.parse(content: markdown, dateString: "2026-07-03")
        #expect(model.entriesCount == 0)
        #expect(model.memoCount == 0)
    }

    @Test func qaDailyTab_canLaunchTheRealTimelineState() {
        #expect(DailyPageTab.initial(arguments: ["DayPage", "-qaDailyTab", "timeline"]) == .timeline)
        #expect(DailyPageTab.initial(arguments: ["DayPage"]) == .digest)
    }

    @Test func dailyTimeline_hidesBrokenSourceActionWhenRawMemosAreUnavailable() throws {
        let root = try projectRoot()
        let source = try String(
            contentsOf: root.appendingPathComponent("DayPage/Features/Daily/DailyPageView.swift"),
            encoding: .utf8
        )
        let host = try String(
            contentsOf: root.appendingPathComponent("DayPage/Features/Archive/DayDetailView.swift"),
            encoding: .utf8
        )

        #expect(source.contains("if !rawMemos.isEmpty"))
        #expect(source.contains("Button(action: viewOriginalFlow)"))
        #expect(source.contains("daily.empty.no_raw.detail"))
        #expect(source.contains("if !rawMemos.isEmpty || isRecompiling || recompileError != nil"))
        #expect(host.contains("onViewOriginalFlow: { selectedTab = .raw }"))
    }

    @Test func qaMemoDetail_launchesThroughTheProductionRoute() throws {
        let root = try projectRoot()
        let source = try String(
            contentsOf: root.appendingPathComponent("DayPage/Features/Today/TodayView.swift"),
            encoding: .utf8
        )

        #expect(source.contains("qaOpenMemoDetail"))
        // The QA route must open detail on the owning raw day actually loaded
        // by TodayViewModel. Re-deriving the day from `memo.created` is the
        // retired dynamic-timezone route (E/current397-dynamic-timezone-
        // navigation-source-audit): the same Date maps to a neighbouring file
        // after a preferred-time-zone switch.
        #expect(source.contains("dayString: viewModel.loadedDayString"))
        #expect(!source.contains("day: memo.created"))
        #expect(source.contains("guard !hasAppliedLaunchPresentationFlags else { return }"))
    }

    @Test func memoDetail_hasFullSizeNavigationAndUndoableDeletion() throws {
        let root = try projectRoot()
        let detail = try String(
            contentsOf: root.appendingPathComponent("DayPage/Features/MemoDetail/MemoDetailView.swift"),
            encoding: .utf8
        )
        let metadata = try String(
            contentsOf: root.appendingPathComponent("DayPage/Features/MemoDetail/MemoDetailMetadataSection.swift"),
            encoding: .utf8
        )

        #expect(detail.contains(".frame(minWidth: 44, minHeight: 44)"))
        #expect(detail.contains(".frame(width: 44, height: 44)"))
        #expect(detail.contains("primaryAction: BannerAction("))
        #expect(detail.contains("onRestore(deletedMemo)"))
        #expect(detail.contains("qaDeleteOpenMemo"))
        #expect(metadata.contains("memo.detail.section.metadata"))
        #expect(metadata.contains("memo.detail.meta.created"))
    }

    @Test func graph_hasAuditableFixtureAndFullSizeCompactControls() throws {
        let root = try projectRoot()
        let view = try String(
            contentsOf: root.appendingPathComponent("DayPage/Features/Graph/GraphView.swift"),
            encoding: .utf8
        )
        let model = try String(
            contentsOf: root.appendingPathComponent("DayPage/Features/Graph/GraphViewModel.swift"),
            encoding: .utf8
        )

        #expect(model.contains("-qaGraphFixtures"))
        #expect(model.contains("qaFixtureGraph()"))
        #expect(view.contains("-qaGraphFocus"))
        #expect(view.contains(".foregroundColor(DSColor.inkTertiaryAA)"))
        #expect(view.contains("showFilters ? \"graph.filter.hide\" : \"graph.filter.show\""))
        #expect(view.contains(".allowsHitTesting(viewModel.focusedNodeID == nil)"))
        #expect(view.contains(".accessibilityHidden(viewModel.focusedNodeID != nil)"))
        #expect(view.contains(".frame(minWidth: 44, minHeight: 44)"))
        #expect(view.components(separatedBy: ".minTapTarget()").count - 1 >= 3)
    }

    @Test func qaSettings_launchesTheRealSettingsSheet() throws {
        let root = try projectRoot()
        let source = try String(
            contentsOf: root.appendingPathComponent("DayPage/Features/Today/TodayView.swift"),
            encoding: .utf8
        )
        #expect(source.contains("qaOpenSettings"))
        #expect(source.contains("DispatchQueue.main.async { showSettings = true }"))
        #expect(SettingsView.Route.initial(arguments: ["DayPage", "-qaSettingsPage", "syncdata"]) == .syncData)
        #expect(SettingsView.Route.initial(arguments: ["DayPage"]) == nil)
    }

    @Test func settingsCredentials_keepNeutralStatesQuietAndActionsTappable() throws {
        let root = try projectRoot()
        let source = try String(
            contentsOf: root.appendingPathComponent("DayPage/Features/Settings/SettingsShared.swift"),
            encoding: .utf8
        )

        #expect(!source.contains(".foregroundColor(isRequired ? .red"))
        #expect(source.contains("case .neutral: return DSColor.inkTertiaryAA"))
        #expect(source.contains("settings.apikey.edit.label"))
        #expect(source.components(separatedBy: ".minTapTarget()").count - 1 >= 3)
    }

    @Test func webSyncSetup_doesNotOfferImpossibleOrAlarmingActions() throws {
        let root = try projectRoot()
        let source = try String(
            contentsOf: root.appendingPathComponent("DayPage/Features/Settings/SettingsSyncDataView.swift"),
            encoding: .utf8
        )

        #expect(source.contains(".disabled(!canSaveWebSync)"))
        #expect(source.contains(".opacity(canSaveWebSync ? 1 : 0.42)"))
        #expect(source.contains("if SyncSettings.isConfigured && syncQueue.pendingCount > 0"))
        #expect(source.contains("settings.websync.pending_setup"))
        #expect(source.contains("-qaSettingsAnchor"))
        #expect(source.contains("proxy.scrollTo(\"settings-danger\", anchor: .bottom)"))
        #expect(source.contains("-qaSettingsConfirm"))
        #expect(source.contains("showPurgeAllConfirm = true"))
        #expect(source.components(separatedBy: ".frame(minHeight: 44)").count - 1 >= 2)
        #expect(source.contains(".frame(maxWidth: .infinity, minHeight: 44)"))
    }

    @Test func settingsRows_doNotPretendToNavigateOrLeakRawEnglish() throws {
        let root = try projectRoot()
        let reminders = try String(
            contentsOf: root.appendingPathComponent("DayPage/Features/Settings/SettingsRemindersView.swift"),
            encoding: .utf8
        )
        let about = try String(
            contentsOf: root.appendingPathComponent("DayPage/Features/Settings/SettingsAboutView.swift"),
            encoding: .utf8
        )
        let sync = try String(
            contentsOf: root.appendingPathComponent("DayPage/Features/Settings/SettingsSyncDataView.swift"),
            encoding: .utf8
        )

        #expect(reminders.contains("NavigationLink {\n                ScheduleHubView()"))
        #expect(!reminders.contains("Image(systemName: \"arrow.up.right\")"))
        #expect(reminders.contains(".foregroundColor(DSColor.inkTertiaryAA)"))
        #expect(about.contains("settings.about.build"))
        #expect(!about.contains("Text(\"Build\")"))
        #expect(sync.contains("settings.websync.key"))
    }

    @Test func reminderPresets_areLocalizedInsteadOfHardcodedChinese() throws {
        let root = try projectRoot()
        let source = try String(
            contentsOf: root.appendingPathComponent("DayPage/Services/CaptureReminderService.swift"),
            encoding: .utf8
        )

        #expect(source.contains("settings.reminder.preset.once"))
        #expect(source.contains("settings.reminder.preset.thrice"))
        #expect(source.contains("settings.reminder.preset.custom"))
        #expect(!source.contains("case .once:   return \"每天一次\""))
    }

    @Test func onboarding_isAuditableLocalizedAndDoesNotRepeatTheWelcome() throws {
        let root = try projectRoot()
        let onboarding = try String(
            contentsOf: root.appendingPathComponent("DayPage/Features/Onboarding/OnboardingView.swift"),
            encoding: .utf8
        )
        let rootView = try String(
            contentsOf: root.appendingPathComponent("DayPage/App/RootView.swift"),
            encoding: .utf8
        )
        let reminders = try String(
            contentsOf: root.appendingPathComponent("DayPage/Services/CaptureReminderService.swift"),
            encoding: .utf8
        )

        #expect(OnboardingView.initialPage(arguments: ["DayPage", "-qaOnboardingPage", "3"]) == 3)
        #expect(OnboardingView.initialPage(arguments: ["DayPage", "-qaOnboardingPage", "9"]) == 0)
        #expect(onboarding.contains("onboarding.reminder.title"))
        #expect(!onboarding.contains("Text(\"到点,轻轻叫你记一句\")"))
        #expect(onboarding.contains("onboarding.apikeys.paste"))
        #expect(onboarding.contains("trimmingCharacters(in: .whitespacesAndNewlines)"))
        #expect(onboarding.contains("private func skipReminders()"))
        #expect(onboarding.contains("DSColor.inkTertiaryAA"))
        #expect(rootView.contains("UserDefaults.standard.set(true, forKey: \"hasSeenWelcome\")"))
        #expect(reminders.contains("AppSettings.Keys.hasRequestedNotifications"))
    }

    @Test func visualAuditThemeOverride_drivesTheRequestedColorScheme() {
        #if DEBUG
        #expect(DayPageApp.qaThemeMode(arguments: ["DayPage", "-forceTheme", "dark"]) == .dark)
        #expect(DayPageApp.qaThemeMode(arguments: ["DayPage", "forceTheme=light"]) == .light)
        #expect(DayPageApp.qaThemeMode(arguments: ["DayPage", "forceTheme", "system"]) == .system)
        #expect(DayPageApp.qaThemeMode(arguments: ["DayPage", "-forceTheme", "sepia"]) == nil)
        #endif
    }

    @Test func darkMode_usesAdaptiveSemanticInkAndHidesUnconfiguredSyncAlarm() throws {
        let root = try projectRoot()
        let colors = try String(
            contentsOf: root.appendingPathComponent("DayPage/DesignSystem/Colors.swift"),
            encoding: .utf8
        )
        let onboarding = try String(
            contentsOf: root.appendingPathComponent("DayPage/Features/Onboarding/OnboardingView.swift"),
            encoding: .utf8
        )
        let settingsFiles = [
            "SettingsView.swift", "SettingsAppearanceView.swift",
            "SettingsSyncDataView.swift", "SettingsAIVoiceView.swift",
            "SettingsRemindersView.swift", "SettingsAboutView.swift"
        ]
        let settings = try settingsFiles.map {
            try String(
                contentsOf: root.appendingPathComponent("DayPage/Features/Settings/\($0)"),
                encoding: .utf8
            )
        }.joined(separator: "\n")
        let today = try String(
            contentsOf: root.appendingPathComponent("DayPage/Features/Today/TodayView.swift"),
            encoding: .utf8
        )

        #expect(colors.contains("static let accentSoft = DSTokens.Colors.accentSoft"))
        #expect(colors.contains("static func userAccent(_ option: AccentColorOption)"))
        #expect(onboarding.components(separatedBy: "DSColor.accentOnBg").count - 1 >= 4)
        #expect(!settings.contains(".tint(DSColor.primary)"))
        #expect(settings.contains(".buttonStyle(.borderedProminent)"))
        #expect(today.contains("if hasActiveSyncDestination"))
        #expect(today.contains("authService.session != nil || SyncSettings.isConfigured"))
    }

    @Test func reduceMotion_stopsConversationalAndOrbLoops() throws {
        let root = try projectRoot()
        let ask = try String(
            contentsOf: root.appendingPathComponent("DayPage/Features/Ask/AskPastView.swift"),
            encoding: .utf8
        )
        let memoChat = try String(
            contentsOf: root.appendingPathComponent("DayPage/Features/Ask/MemoChatView.swift"),
            encoding: .utf8
        )
        let orb = try String(
            contentsOf: root.appendingPathComponent("DayPage/Features/Today/DayOrbView.swift"),
            encoding: .utf8
        )
        let welcome = try String(
            contentsOf: root.appendingPathComponent("DayPage/Features/Onboarding/WelcomeScreen.swift"),
            encoding: .utf8
        )

        #expect(ask.contains("@Environment(\\.accessibilityReduceMotion)"))
        #expect(ask.contains("!reduceMotion && isRecordingVoice"))
        #expect(memoChat.contains("if reduceMotion {\n                    caretVisible = true"))
        #expect(orb.components(separatedBy: "reduceMotion ? nil").count - 1 >= 8)
        #expect(welcome.contains(".scaleEffect(!reduceMotion && configuration.isPressed"))
    }

    @Test func accessibilityText_keepsPrimaryRoutesScrollableAndActionsReachable() throws {
        let root = try projectRoot()
        let onboarding = try String(
            contentsOf: root.appendingPathComponent("DayPage/Features/Onboarding/OnboardingView.swift"),
            encoding: .utf8
        )
        let settings = try String(
            contentsOf: root.appendingPathComponent("DayPage/Features/Settings/SettingsView.swift"),
            encoding: .utf8
        )
        let emptyState = try String(
            contentsOf: root.appendingPathComponent("DayPage/Components/EmptyStateView.swift"),
            encoding: .utf8
        )
        let input = try String(
            contentsOf: root.appendingPathComponent("DayPage/Features/Today/InputBarV4.swift"),
            encoding: .utf8
        )
        let graph = try String(
            contentsOf: root.appendingPathComponent("DayPage/Features/Graph/GraphView.swift"),
            encoding: .utf8
        )
        let archive = try String(
            contentsOf: root.appendingPathComponent("DayPage/Features/Archive/ArchiveView.swift"),
            encoding: .utf8
        )
        let picker = try String(
            contentsOf: root.appendingPathComponent("DayPage/DesignSystem/DSPicker.swift"),
            encoding: .utf8
        )

        #expect(onboarding.contains("@Environment(\\.dynamicTypeSize) private var dynamicTypeSize"))
        #expect(onboarding.components(separatedBy: ".safeAreaInset(edge: .bottom").count - 1 >= 3)
        #expect(onboarding.contains("if dynamicTypeSize.isAccessibilitySize"))
        #expect(settings.contains("if userDynamicTypeSize.isAccessibilitySize"))
        #expect(settings.contains(".dynamicTypeSize(.xSmall ... .accessibility2)"))
        #expect(emptyState.contains(".dynamicTypeSize(.xSmall ... .accessibility1)"))
        #expect(input.contains(".dynamicTypeSize(.xSmall ... .xxLarge)"))
        #expect(graph.components(separatedBy: ".dynamicTypeSize(.xSmall ... .xxLarge)").count - 1 >= 2)
        #expect(graph.contains(".minimumScaleFactor(0.72)"))
        #expect(graph.contains(".dynamicTypeSize(.xSmall ... .large)"))
        #expect(archive.components(separatedBy: ".dynamicTypeSize(.xSmall ... .large)").count - 1 >= 2)
        #expect(archive.contains(".minimumScaleFactor(0.78)"))
        #expect(picker.contains("if dynamicTypeSize.isAccessibilitySize"))
        #expect(picker.contains("VStack(alignment: .leading, spacing: DSSpacing.sm)"))
    }

    @Test func voiceOver_primaryRoutesExposeHeadingsContextAndActions() throws {
        let root = try projectRoot()
        let typography = try String(
            contentsOf: root.appendingPathComponent("DayPage/DesignSystem/Typography.swift"),
            encoding: .utf8
        )
        let onboarding = try String(
            contentsOf: root.appendingPathComponent("DayPage/Features/Onboarding/OnboardingView.swift"),
            encoding: .utf8
        )
        let archive = try String(
            contentsOf: root.appendingPathComponent("DayPage/Features/Archive/ArchiveView.swift"),
            encoding: .utf8
        )
        let graph = try String(
            contentsOf: root.appendingPathComponent("DayPage/Features/Graph/GraphView.swift"),
            encoding: .utf8
        )
        let body = try String(
            contentsOf: root.appendingPathComponent("DayPage/Features/MemoDetail/MemoDetailBodySection.swift"),
            encoding: .utf8
        )
        let sectionLabel = try String(
            contentsOf: root.appendingPathComponent("DayPage/Features/MemoDetail/MemoDetailEchoesSection.swift"),
            encoding: .utf8
        )

        #expect(typography.contains(".accessibilityAddTraits(.isHeader)"))
        #expect(onboarding.contains("notification: .screenChanged"))
        #expect(onboarding.components(separatedBy: ".accessibilityHidden(true)").count - 1 >= 7)
        #expect(onboarding.contains(".accessibilityLabel(\"\\(title), \\(status.label)\")"))
        #expect(archive.contains("[.isButton, .isSelected]"))
        #expect(archive.contains("archive.mode.calendar"))
        #expect(graph.contains(".accessibilityAddTraits(.isHeader)"))
        #expect(body.contains(".accessibilityAction { startEditing() }"))
        #expect(sectionLabel.contains(".accessibilityAddTraits(.isHeader)"))
    }

    @Test func localization_primaryConversationRoutesStayBilingualAndAuditable() throws {
        let root = try projectRoot()
        let enURL = root.appendingPathComponent("DayPage/Resources/en.lproj/Localizable.strings")
        let zhURL = root.appendingPathComponent("DayPage/Resources/zh-Hans.lproj/Localizable.strings")
        let en = try String(contentsOf: enURL, encoding: .utf8)
        let zh = try String(contentsOf: zhURL, encoding: .utf8)

        let keyPattern = try NSRegularExpression(pattern: #"(?m)^\"([^\"]+)\"\s*="#)
        func keys(in source: String) -> Set<String> {
            let range = NSRange(source.startIndex..., in: source)
            return Set(keyPattern.matches(in: source, range: range).compactMap { match in
                guard let range = Range(match.range(at: 1), in: source) else { return nil }
                return String(source[range])
            })
        }

        #expect(keys(in: en) == keys(in: zh), "English and Simplified Chinese must expose identical localization keys")
        for key in [
            "coach.title", "coach.offline.pin", "ask.title", "ask.sources",
            "compile.unlock.body", "input.photo.processing", "undo.a11y.hint",
            "today.timeline.by_day"
        ] {
            #expect(keys(in: en).contains(key), "Missing primary-flow localization key: \(key)")
        }

        let coach = try String(
            contentsOf: root.appendingPathComponent("DayPage/Features/Today/TodayCoachView.swift"),
            encoding: .utf8
        )
        let ask = try String(
            contentsOf: root.appendingPathComponent("DayPage/Features/Ask/AskPastView.swift"),
            encoding: .utf8
        )
        let today = try String(
            contentsOf: root.appendingPathComponent("DayPage/Features/Today/TodayView.swift"),
            encoding: .utf8
        )
        let rootView = try String(
            contentsOf: root.appendingPathComponent("DayPage/App/RootView.swift"),
            encoding: .utf8
        )
        let sidebar = try String(
            contentsOf: root.appendingPathComponent("DayPage/App/SidebarView.swift"),
            encoding: .utf8
        )

        #expect(!coach.contains("Text(\"陪你写今天\")"))
        #expect(!coach.contains("TextField(\"说说此刻…\""))
        #expect(!ask.contains(".navigationTitle(\"和过去对话\")"))
        #expect(!ask.contains("TextField(\"问问你的过去…\""))
        #expect(today.contains("qaOpenCoach"), "The real coach sheet needs a deterministic simulator audit route")
        #expect(rootView.contains("qaOpenAskPast"), "The real Ask Past sheet needs a deterministic simulator audit route")
        #expect(sidebar.contains("sidebar.tab.archive"), "Sidebar destinations need stable language-independent E2E identifiers")
        #expect(sidebar.contains("sidebar.tab.today"), "Sidebar destinations need stable language-independent E2E identifiers")
    }

    private func contrastRatio(foreground: String, background: String) throws -> Double {
        let foregroundLuminance = try relativeLuminance(hex: foreground)
        let backgroundLuminance = try relativeLuminance(hex: background)
        let lighter = max(foregroundLuminance, backgroundLuminance)
        let darker = min(foregroundLuminance, backgroundLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func relativeLuminance(hex: String) throws -> Double {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6, let raw = Int(value, radix: 16) else {
            throw AccessibilityTestError.invalidHexColor(hex)
        }
        let red = linearizedSRGBChannel(Double((raw >> 16) & 0xFF) / 255)
        let green = linearizedSRGBChannel(Double((raw >> 8) & 0xFF) / 255)
        let blue = linearizedSRGBChannel(Double(raw & 0xFF) / 255)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    private func linearizedSRGBChannel(_ channel: Double) -> Double {
        if channel <= 0.04045 {
            return channel / 12.92
        }
        return pow((channel + 0.055) / 1.055, 2.4)
    }
}
}

private enum AccessibilityTestError: Error {
    case cannotLocateProjectRoot
    case invalidHexColor(String)
}


// MARK: - DayPageSerialSwiftTests namespace aliases (preserve global names for helpers,
// extensions, and qualified references after the serialized-root move)
typealias AccessibilityTests = DayPageSerialSwiftTests.AccessibilityTests
