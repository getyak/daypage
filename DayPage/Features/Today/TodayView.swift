import SwiftUI
import CoreLocation
import DayPageModels
import DayPageStorage
import DayPageServices

// MARK: - View.modify helper (crash-fix utility)
//
// Applies a transform that returns `some View`, inserting a type-erasure-free
// boundary between modifier groups. Used by TodayView.body to split a giant
// modifier chain into several shallower generic types — see the crash-fix
// comment in TodayView.body. The transform itself decides the concrete type,
// so each `.modify { ... }` call caps the nesting depth the Swift runtime must
// resolve at launch on arm64e Release builds.
extension View {
    @ViewBuilder
    func modify<Transformed: View>(_ transform: (Self) -> Transformed) -> Transformed {
        transform(self)
    }
}

struct TodayView: View {

    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var nav: AppNavigationModel
    @StateObject private var viewModel = TodayViewModel()
    @StateObject private var passiveLocation = PassiveLocationService.shared
    @StateObject private var bannerCenter = BannerCenter.shared
    @StateObject private var voiceQueue = VoiceAttachmentQueue.shared
    @StateObject private var migrationService = VaultMigrationService.shared
    @StateObject private var compilationService = CompilationService.shared
    // F2: surface offline / AI-disabled state right under the header so the
    // user knows why compile + voice transcribe behave differently.
    @StateObject private var networkMonitor = NetworkMonitor.shared
    // R5: offline sync queue — drives the "N 条 memo 待同步" banner just
    // under the AI key banner. Observes pendingCount + oldestPendingDate to
    // switch between neutral and "已等待 N 小时" red variants.
    @StateObject private var syncQueue = SyncQueueService.shared
    /// Issue #5 (2026-07-03): stage-aware source of truth for the top
    /// compile progress banner. See `compileProgressBanner`.
    @StateObject private var compileService = BackgroundCompilationService.shared
    /// Issue #13 (2026-07-03): today's declared focus lenses. Drives the
    /// small chip row above the input surface; CompilationService reads
    /// the same store on the next compile.
    @StateObject private var focusStore = TodayFocusStore.shared
    @AppStorage(AppSettings.Keys.aiFeaturesEnabled) private var aiFeaturesEnabled: Bool = true
    @EnvironmentObject private var sidebarVM: SidebarViewModel

    @Environment(\.scenePhase) private var scenePhase

    @State private var showSyncBanner: Bool = false
    // Issue #814: the weekly-recap preview card was removed from Today —
    // Archive's entry card is now the single surface for This Week. Today
    // stays a pure raw-capture canvas with fewer stacked banners.
    // R6: drives the modal sheet that surfaces the first N pending memo
    // IDs when the user taps the sync-queue banner. Replaces the bare
    // BannerCenter alert with a sheet you can actually scan.
    @State private var showSyncQueueSheet: Bool = false
    @State private var showAuthSheet: Bool = false

    // R3 — A2: Reflects "AI compile + Whisper are gagged because either the
    // DeepSeek (Qwen-compatible) or OpenAI Whisper key is missing in Keychain
    // AND no compile-time fallback was bundled". Recomputed onAppear + on
    // scenePhase=.active so editing keys in Settings flips the banner without
    // a relaunch.
    @State private var aiKeyMissing: Bool = false

    // R3 — A2: Session-only "user dismissed the banner" flag. Combined with
    // `aiBannerDismissedUntil` (SceneStorage, see below) so a tap on the
    // close x hides the banner for 24h, while a relaunch in the same scene
    // honours the cooldown too. The session flag is cleared on a fresh
    // process launch (because @State is per-instance), so a relaunch with
    // expired cooldown will re-show the banner.
    @State private var aiBannerDismissedSession: Bool = false
    /// Epoch-seconds timestamp until which the banner stays suppressed.
    /// Zero or past = show again. 24h cooldown after manual dismiss.
    @SceneStorage("aiKeyBanner.dismissedUntil") private var aiBannerDismissedUntil: Double = 0

    /// 输入栏中的草稿文本。SceneStorage persists the draft across backgrounding and process kills.
    @SceneStorage("today.draftText") private var draftText: String = ""

    /// R5: iPad multi-window safety — Info.plist sets
    /// `UIApplicationSupportsMultipleScenes = true`, so two windows (split-view
    /// / Stage Manager) can run TodayView simultaneously. Without a per-scene
    /// suffix, both windows write the same `today.draftText.backup`
    /// UserDefaults key on every keystroke and clobber each other. SceneStorage
    /// is per-scene, so each window gets its own stable UUID that survives
    /// backgrounding and process kills, scoping the backup key to this scene.
    @SceneStorage("today.draftBackupSceneID") private var draftBackupSceneID: String = UUID().uuidString

    /// Per-scene UserDefaults key for the draft backup mirror. See
    /// `draftBackupSceneID` for the multi-window rationale.
    private var draftBackupKey: String { "today.draftText.backup.\(draftBackupSceneID)" }

    /// Whether to show the Daily Page sheet.
    @State private var showDailyPage: Bool = false

    /// Date string for the fallback yesterday daily page sheet.
    @State private var fallbackDailyPageDateString: String? = nil

    /// Date string for opening a historical day from the timeline via tap or
    /// long-press → "Open Daily Page". Drives a dedicated `.fullScreenCover`
    /// so it doesn't collide with the today/fallback covers.
    @State private var timelineNavDateString: String? = nil

    /// Plain-text payload for the system share sheet when the user shares a
    /// timeline day. Identifiable wrapper because `.sheet(item:)` needs an id.
    @State private var timelineShareText: TimelineShareText? = nil

    /// Whether to show the Settings sheet.
    @State private var showSettings: Bool = false

    /// Date string for On This Day navigation.
    @State private var onThisDayDateString: String? = nil

    // R9-HIGH A2: `onThisDayShownAtTop` @State removed. The top vs fallback
    // OnThisDay card decision is now driven by the `shouldShowOnThisDayAtTop`
    // computed property, which both call sites read in the same render pass
    // — eliminating the lazy-onAppear race that briefly rendered two cards.

    /// Current time for the header timestamp (refreshed every minute).
    @State private var currentTime: Date = Date()

    /// Whether the daily page card is swiped open to reveal the recompile action.
    @State private var dailyPageRevealed: Bool = false

    /// Session-only flag: true once the "restored unsent draft" banner has been shown this session.
    @State private var draftRestoredBannerShown: Bool = false

    // R4-MEDIUM #38 — iCloud conflict banner.
    // When ConflictMerger posts `.vaultConflictResolved` we surface a brief
    // orange banner explaining that an automatic merge happened and which
    // day's file was affected. Auto-fades after 3 seconds.
    @State private var iCloudConflictBannerVisible: Bool = false
    @State private var iCloudConflictBannerDate: String = ""

    // US-006: Date the draft was last modified, stored in UserDefaults.
    // If the draft is older than 30 days it is auto-cleared on next launch.
    @AppStorage("today.draftDate") private var draftDate: Double = 0

    // Rolling count of the last successfully-loaded memo set for today.
    // Drives MemoListSkeleton so placeholder height matches expected content height.
    @AppStorage("today.skeletonCardCount") private var skeletonCardCount: Int = 3

    // US-009: Text to restore if undo is tapped within 5s of submit.
    @State private var undoText: String? = nil
    @State private var undoTask: Task<Void, Never>? = nil

    // B3: Debounces the per-keystroke draftDate UserDefaults write. Without
    // this, every character typed in the composer issued a synchronous
    // UserDefaults.set(...) — a known cause of main-thread hitches on long
    // drafts. We coalesce into one write 0.8s after the user pauses typing.
    @State private var draftSaveTask: Task<Void, Never>? = nil

    // US-010: First-run tutorial overlay
    @State private var showTutorial: Bool = false

    // Issue #302: share-card sheet payload. Set by long-press on a memo.
    @State private var sharePayload: SharePayload? = nil

    // Issue #309 W2: multi-select mode. When non-nil, the timeline is in
    // selection mode: card taps toggle membership instead of navigating,
    // swipe panels are disabled, and a top action bar lets the user share
    // the selection as a collage. Reset to nil to leave the mode.
    //
    // Set is session-scoped — switching tabs or backgrounding the app
    // clears it implicitly (TodayView re-renders fresh). We don't persist
    // across launches; selection is always an immediate action.
    @State private var selectedMemoIds: Set<UUID>? = nil

    /// Programmatic memo-detail navigation. The card body no longer uses a
    /// SwiftUI NavigationLink (the swipe gesture's UIKit host hit-tests to
    /// self, which would swallow the link's tap); instead a tap recognizer
    /// fires `onOpen`, which sets this id and drives `navigationDestination`.
    @State private var openedMemoID: UUID? = nil

    /// iOS 18+ zoom transition: the tapped card is the `matchedTransitionSource`
    /// and MemoDetailView zooms out of it (App Store / Photos-style hero).
    /// iOS 16–17 keeps the plain push — see `CardZoomSource` /
    /// `CardZoomDestination` at the bottom of this file.
    @Namespace private var detailZoomNamespace

    /// v8 WriteSheet — bottom-sheet text composer opened from the dock's text
    /// affordance (composer.jsx:183). Routes saves through `submitCombinedMemo`
    /// (the same path the inline composer uses) via `draftText`.
    @State private var showWriteSheet: Bool = false

    /// Issue #804: Today sparkle 现在打开 `TodayCoachView`（陪写引导）。
    /// AskPastView（RAG 「问过去」）保留在侧边栏 + Siri intent —— 两条路径
    /// 语义不同，不再共用这个 state。
    @State private var showTodayCoach: Bool = false

    /// Issue #2: flips true after the empty-state "See a sample journal" link
    /// runs `SampleDataSeeder.seedIfNeeded()`. Rebinds the link label so a
    /// user who taps it twice does not get a silent no-op — they see
    /// "已生成 · 打开昨天看看" and know where to look next.
    @State private var sampleSeeded: Bool = SampleDataSeeder.hasSeededSamples

    /// Toggled each time the Day Orb is tapped to focus the composer input.
    @State private var orbFocusToggle: Bool = false
    /// Toggled each time a new memo is added while the orb hero is visible, triggering a capture-reward glow pulse.
    @State private var orbCapturePulse: Bool = false

    /// US-019: controls the markdown export share sheet.
    @State private var showExportSheet: Bool = false
    @State private var exportFileURL: URL? = nil

    /// One-time discoverable pulse on the export button (fires when button first appears with >=1 memo).
    @State private var exportHintPulse: Bool = false
    /// One-time discoverable pulse on the AI summary card (fires when a compiled summary first appears).
    @State private var summaryHintPulse: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var orbBreathing: Bool = false
    @State private var orbTapBounce: Bool = false

    /// Accumulated rotation for the settings gear — a gear should turn when
    /// tapped. Bumped by a quarter turn on each tap so the spin feels mechanical.
    @State private var settingsGearRotation: Double = 0

    /// Hint offset for the one-time swipe-left nudge on the Daily Page card.
    @State private var dailyPageHintOffset: CGFloat = 0
    @State private var memoCardHintOffset: CGFloat = 0

    /// Tracks the highest word-count milestone (100/250/500) already announced this session.
    /// Reset to 0 when all memos are deleted so milestones re-arm on a fresh day.
    @State private var lastWordMilestone: Int = 0

    /// When non-nil, a glass milestone toast is shown at the top of the timeline.
    /// Cleared automatically after 2.5 s by milestoneToastTask.
    @State private var wordMilestoneToast: Int? = nil
    /// Tracks the active dismiss Task so a new milestone cancels the prior timer before starting its own.
    @State private var milestoneToastTask: Task<Void, Never>? = nil

    /// Session-only: true once the 3-memo unlock celebration has fired this session.
    /// Resets to false when memo count drops back below 3 so delete+readd re-fires it.
    @State private var didCelebrateUnlock: Bool = false
    /// Drives the one-shot amber glow pulse on the compile button at unlock.
    @State private var unlockGlow: Bool = false
    /// Tracks the previous memo count so escalating haptics only fire on additions, not deletions.
    @State private var lastMemoCount: Int = 0

    /// True when a new memo arrived while the user was scrolled past the ~240pt threshold.
    /// Drives the amber dot badge on the scroll-to-top button. Cleared on scroll-to-top.
    @State private var hasNewContentAboveFold: Bool = false

    /// Session-only: true once the compile-completion celebration has fired for the current daily page.
    /// Resets to false when isDailyPageCompiled becomes false (recompile/new day) so it re-fires.
    @State private var didCelebrateCompile: Bool = false
    /// Drives the one-shot amber glow + scale reveal on the daily page card after compilation.
    @State private var compileRevealGlow: Bool = false

    /// Drives the one-shot amber glow pulse on the orb / timeline top after pull-to-refresh.
    @State private var refreshGlow: Bool = false

    /// Drives the amber glow pulse on the word-count token in the header subline at milestones.
    @State private var wordMilestoneGlow: Bool = false
    /// Tracks the last milestone index (count of thresholds crossed) so we only fire on additions.
    @State private var lastWordMilestoneIndex: Int = 0
    private let wordMilestones: [Int] = [100, 300, 500]

    /// Milestone feedback when the scroll-to-top progress ring fills to 100%.
    @State private var didReachScrollEnd: Bool = false
    @State private var scrollRingGlow: Bool = false
    /// Tracks which 1/3-ring milestone bucket (0/1/2) has already fired a haptic tick this scroll gesture.
    @State private var lastScrollMilestone: Int = 0

    /// Scroll proxy captured from the timeline ScrollViewReader; used by composeSection
    /// to scroll to the top anchor after a new memo is added.
    @State private var timelineScrollProxy: ScrollViewProxy? = nil

    // US-005: Tracks timeline scroll offset to activate the glass header bar.
    // Becomes negative as the user scrolls down; < -8 triggers the frosted glass.
    //
    // Perf: NEVER read this value from the view body — every scroll frame would
    // then invalidate the 3.8k-line TodayView and drop frames. Consumers read
    // the derived, threshold-bucketed booleans below (`isTimelineScrolled`,
    // `showScrollToTopButton`, `scrollProgressBucket`), which change O(1)
    // times per scroll instead of O(60Hz).
    @State private var timelineScrollOffset: CGFloat = 0
    /// True once the timeline has scrolled past 8pt — activates the glass
    /// header bar. Flips at most twice per scroll gesture.
    @State private var isTimelineScrolled: Bool = false
    /// True once the timeline has scrolled past 240pt — surfaces the
    /// scroll-to-top button and the "back to top" affordance.
    @State private var showScrollToTopButton: Bool = false
    /// Quantized progress (0…20) of the scroll-to-top ring so the ring
    /// re-renders at most 21 times across the 1200pt travel instead of once
    /// per scroll frame. Divide by 20.0 at the read site to recover 0.0–1.0.
    @State private var scrollProgressBucket: Int = 0

    private var isInSelectionMode: Bool { selectedMemoIds != nil }

    /// Number of word milestones the user has currently crossed (0–3).
    private var currentWordMilestoneIndex: Int {
        wordMilestones.filter { $0 <= viewModel.todayWordCount }.count
    }

    /// Progress of the scroll-to-top ring: 0 at 240pt (button appears), 1 after
    /// 1200pt more. Reads the quantized bucket (0…20) so the ring's stroke
    /// re-renders at most 21 times across the travel rather than each frame.
    private var scrollProgress: CGFloat {
        CGFloat(scrollProgressBucket) / 20.0
    }

    /// Fraction of the current local day elapsed (0.0 at midnight, 1.0 at next midnight).
    private var dayProgress: CGFloat {
        DayProgress.fraction(at: currentTime)
    }

    /// Live drag offset for the daily page card (negative = pulled left).
    @GestureState private var dailyPageDrag: CGFloat = 0

    private let headerTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var todayPendingDrafts: [VisitDraft] {
        passiveLocation.todayPendingDrafts()
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                // V4: Warm ambient canvas — glass surfaces refract against this
                AmbientBackground()
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    // MARK: Sidebar/Header (US-021: extracted subview)
                    sidebarSection

                    // Issue #814: weekly-recap preview card removed — Archive
                    // owns the This Week entry point now.

                    // MARK: AI key missing banner (R3 — A2)
                    //
                    // Museum-aesthetic redesign (#793): the banner used to
                    // dominate the first screen with an amber wash + CTA.
                    // For a calm capture surface we now surface it ONLY
                    // when the user genuinely needs to act — i.e. the day
                    // is empty (nothing to compile = a teaching moment),
                    // not every launch. With memos present the same
                    // condition shows up as a small amber dot on the
                    // settings gear (a quieter affordance, set elsewhere).
                    if shouldShowAIKeyBanner && viewModel.memos.isEmpty {
                        aiKeyMissingBanner
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    // MARK: Compile Progress Banner (Issue #5, 2026-07-03)
                    //
                    // Shows the current stage of an in-flight compilation
                    // (collecting → cleaning → clustering → generating →
                    // linking). Hidden when the service is `.idle` so the
                    // surface stays quiet 99% of the time — the banner is
                    // a reassurance signal for the ~15-60 second window an
                    // AI compile actually runs. Observing
                    // BackgroundCompilationService directly (it is now an
                    // ObservableObject) keeps it as the single source of
                    // truth for both foreground and background triggers.
                    if compileService.stage != .idle {
                        compileProgressBanner
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    // MARK: Today Focus Chips (Issue #13, 2026-07-03)
                    //
                    // A quiet horizontal ScrollView of five toggle chips
                    // (工作 / 情绪 / 健康 / 关系 / 学习). Selecting one
                    // updates TodayFocusStore, which
                    // CompilationService.buildPrompt reads at compile time
                    // — no code path lives in TodayView beyond the toggle.
                    // Rendered before the timeline so the user sees "the
                    // AI knows what I care about today" as soon as they
                    // land on Today.
                    //
                    // 2026-07-04: shown only while the day is EMPTY. Once
                    // memos exist the chips stop earning their row — the
                    // declared focus already flowed into TodayFocusStore and
                    // the compile prompt, and the timeline needs the space.
                    if viewModel.memos.isEmpty {
                        todayFocusRow
                            .padding(.bottom, DSSpacing.xs)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    // MARK: Offline Sync Queue Banner (R5)
                    //
                    // Museum-aesthetic redesign (#793): "1 条待同步" used to
                    // claim a full 44pt row on the first screen — too noisy
                    // for a normal capture flow. Now we only surface the
                    // banner when something is actually stuck (>= 5 memos
                    // pending OR oldest entry waited > 1h). Small queues
                    // are invisible — the round-trip still happens in the
                    // background and the queue indicator on the settings
                    // gear (set elsewhere) lets the curious user dig in.
                    if FeatureFlagStore.shared.isEnabled(.offlineQueue)
                        && (syncQueue.pendingCount >= 5 || syncQueueWaitedTooLong) {
                        syncQueuePendingBanner
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    // MARK: On This Day Top Card (R8-CRITICAL)
                    //
                    // 顶部独立 OnThisDayCard section — 脱离 fallbackContentView
                    // 那条只在 viewModel.memos.isEmpty 时才显示的死路。 普通用户
                    // 每天都会写 memo， 之前永远看不到时光胶囊； 现在只要存在
                    // viewModel.onThisDayEntry（由 OnThisDayIndex.candidate 或
                    // .onThisDayShouldShow 注入）就在头条位置出现。
                    //
                    // Sits AFTER the AI key / sync queue banners (those are
                    // sticky "system status" rows that must always own the
                    // very top) but BEFORE every Today-content section
                    // (orbHero / timeline / fallback). Dismiss persists for
                    // the rest of the day via OnThisDayScheduler — same
                    // behavior the fallback path uses, so users can't
                    // double-dismiss.
                    //
                    // R9-HIGH A2: gated by `shouldShowOnThisDayAtTop`, which
                    // the fallback path negates in the same render pass. No
                    // more lazy `.onAppear` flag flip — the two paths agree
                    // synchronously, eliminating the brief double-card race.
                    // R9-HIGH A3: the same computed also yields to ≥ 2
                    // sticky banners so the composer isn't pushed off the
                    // visible viewport on small devices (iPhone 12 mini).
                    if shouldShowOnThisDayAtTop,
                       let entry = viewModel.onThisDayEntry {
                        OnThisDayCard(
                            entry: entry,
                            onDismiss: {
                                OnThisDayScheduler.shared.markDismissedForToday()
                                viewModel.onThisDayEntry = nil
                            },
                            onTap: { tapped in
                                handleOnThisDayTap(tapped)
                            }
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    // MARK: Compilation Progress Bar
                    if viewModel.isCompiling {
                        CompilationProgressBar(stage: compilationService.stage)
                            .transition(.opacity)
                            .animation(Motion.fade, value: viewModel.isCompiling)
                    }

                    // MARK: Compilation Failed Banner
                    if let failureMsg = viewModel.compilationFailedError {
                        CompilationFailedBanner(message: failureMsg) {
                            viewModel.compilationFailedError = nil
                            viewModel.compile()
                        } onDismiss: {
                            viewModel.compilationFailedError = nil
                        }
                    }

                    // MARK: Sync Prompt Banner
                    if showSyncBanner {
                        syncBanner
                    }

                    // MARK: iCloud Conflict Resolved Banner (R4-MEDIUM #38)
                    if iCloudConflictBannerVisible {
                        iCloudConflictBanner
                    }

                    // MARK: Location Draft Card
                    if !todayPendingDrafts.isEmpty {
                        LocationDraftCard(
                            drafts: todayPendingDrafts,
                            onConfirm: { draft in
                                do { try passiveLocation.confirmDraft(draft) }
                                catch { DayPageLogger.shared.error("TodayView: confirmDraft: \(error)") }
                                viewModel.load()
                            },
                            onIgnore: { draft in
                                passiveLocation.ignoreDraft(draft)
                            },
                            onConfirmAll: {
                                for draft in todayPendingDrafts {
                                    do { try passiveLocation.confirmDraft(draft) }
                                    catch { DayPageLogger.shared.error("TodayView: confirmDraft: \(error)") }
                                }
                                viewModel.load()
                            },
                            onIgnoreAll: {
                                for draft in todayPendingDrafts {
                                    passiveLocation.ignoreDraft(draft)
                                }
                            }
                        )
                    }

                    // MARK: Day Orb Hero — serif date + mono kicker + orb
                    // Hide when memos exist: the header already shows the date,
                    // and the 140pt orb wastes prime content space once there
                    // are signals in the timeline. (#US-016)
                    if viewModel.memos.isEmpty {
                        orbHero
                            .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
                            .animation(Motion.dismiss, value: viewModel.memos.isEmpty)
                    }

                    // MARK: Selection toolbar (issue #309 W2)
                    // Renders only while in multi-select mode, between the
                    // header and the timeline. Lifted out of the ScrollView
                    // so it stays pinned during scroll and never overlaps a
                    // selected card's chrome.
                    if let selected = selectedMemoIds {
                        selectionToolbar(selectedIds: selected)
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                            .padding(.bottom, 4)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    // MARK: Timeline (US-021: extracted subview)
                    timelineSection

                    // MARK: Compose (US-021: extracted subview)
                    composeSection
                }
                // US-009: Undo pill shown for 5s after memo submit
                .overlay(alignment: .bottom) {
                    if let text = undoText {
                        UndoPillView {
                            draftText = text
                            undoText = nil
                            undoTask?.cancel()
                        } onDismiss: {
                            undoText = nil
                            undoTask?.cancel()
                        }
                        .padding(.bottom, 96)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(Motion.rise, value: undoText != nil)
                // Undo pill shown for 5s after memo delete
                .overlay(alignment: .bottom) {
                    if viewModel.lastDeletedMemo != nil {
                        UndoPillView(label: NSLocalizedString("undo_pill.label.delete", comment: "Undo delete pill label")) {
                            viewModel.undoDelete()
                        } onDismiss: {
                            viewModel.lastDeletedMemo = nil
                        }
                        .padding(.bottom, 96)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(Motion.rise, value: viewModel.lastDeletedMemo != nil)
                // Scroll-to-top chevron — fades in at bottom-trailing when scrolled past 240pt
                .overlay(alignment: .bottomTrailing) {
                    if showScrollToTopButton && !viewModel.memos.isEmpty && !isInSelectionMode {
                        Button {
                            hasNewContentAboveFold = false
                            Haptics.soft()
                            withAnimation(reduceMotion ? nil : Motion.spring) {
                                timelineScrollProxy?.scrollTo("timelineTop", anchor: .top)
                            }
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "chevron.up")
                                    .font(DSType.bodySM)
                                    .foregroundColor(DSColor.inkMuted)
                                    .frame(width: 28, height: 28)
                                    .glassSurface(in: Circle())
                                    .overlay(
                                        Circle()
                                            .trim(from: 0, to: scrollProgress)
                                            .stroke(
                                                DSColor.accentAmber,
                                                style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                                            )
                                            .rotationEffect(.degrees(-90))
                                            .animation(reduceMotion ? nil : Motion.fade, value: scrollProgress)
                                    )
                                    .shadow(
                                        color: DSColor.accentAmber.opacity(scrollRingGlow ? 0.5 : 0),
                                        radius: scrollRingGlow ? 14 : 0
                                    )
                                    .animation(reduceMotion ? nil : .easeOut(duration: 0.6), value: scrollRingGlow)
                                    .clipShape(Circle())

                                if hasNewContentAboveFold {
                                    Circle()
                                        .fill(DSColor.accentAmber)
                                        .frame(width: 7, height: 7)
                                        .offset(x: 1, y: -1)
                                        .transition(.scale)
                                        .animation(reduceMotion ? nil : Motion.spring, value: hasNewContentAboveFold)
                                }
                            }
                        }
                        .padding(.trailing, 20)
                        .padding(.bottom, 96)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                        .accessibilityLabel(hasNewContentAboveFold
                            ? NSLocalizedString("scroll_to_top.label.new_content", comment: "")
                            : NSLocalizedString("scroll_to_top.label.default", comment: ""))
                        .accessibilityHint("Returns to the top of today's timeline")
                        .accessibilityIdentifier("scroll-to-top-button")
                    }
                }
                .animation(reduceMotion ? nil : Motion.rise, value: showScrollToTopButton)
                .onChange(of: scrollProgress) { progress in
                    // Intermediate milestone ticks at 33% and 66% fill.
                    let milestone = Int(progress * 3) // 0/1/2/3
                    if milestone > lastScrollMilestone && milestone < 3 && !reduceMotion {
                        Haptics.rigid(intensity: 0.3 + 0.2 * CGFloat(milestone))
                        lastScrollMilestone = milestone
                    }
                    if progress >= 1.0 && !didReachScrollEnd {
                        didReachScrollEnd = true
                        hasNewContentAboveFold = false
                        Haptics.soft()
                        if !reduceMotion {
                            scrollRingGlow = true
                            Task {
                                try? await Task.sleep(nanoseconds: 600_000_000)
                                scrollRingGlow = false
                            }
                        }
                    } else if progress < 0.95 {
                        didReachScrollEnd = false
                        lastScrollMilestone = 0
                    }
                }
                // Word-count milestone glass toast — slides in from the top for 2.5 s.
                .overlay(alignment: .top) {
                    if let milestone = wordMilestoneToast {
                        Text(String(format: NSLocalizedString("today.milestone.words", comment: ""), milestone))
                            .font(DSType.mono10)
                            .tracking(1.0)
                            .textCase(.uppercase)
                            .foregroundColor(DSColor.amberAccent)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .glassSurface(in: Capsule())
                            .padding(.top, 8)
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .allowsHitTesting(false)
                    }
                }
                .animation(reduceMotion ? nil : Motion.rise, value: wordMilestoneToast != nil)
                // Submit error toast — scoped animation lives on the overlay
                // container so only the toast itself animates, not the whole
                // ZStack tree. (#217)
                .overlay(alignment: .top) {
                    ZStack(alignment: .top) {
                        if let err = viewModel.submitError {
                            // B1: Add an inline "retry" affordance when the
                            // failed-body breadcrumb is still around so the
                            // user doesn't have to manually re-fire the send.
                            // Falls back to text-only when no body is staged
                            // (e.g. photo/voice-only flows).
                            HStack(spacing: 12) {
                                Text(err)
                                    .bodySMStyle()
                                    .foregroundColor(DSColor.onError)
                                    .accessibilityLabel(err)

                                if let retryBody = viewModel.lastFailedBody, !retryBody.isEmpty {
                                    Button {
                                        Haptics.soft()
                                        // Keep the body around for ANOTHER
                                        // failure: submitCombinedMemo will
                                        // re-stamp lastFailedBody on error.
                                        viewModel.submitError = nil
                                        viewModel.submitCombinedMemo(body: retryBody)
                                    } label: {
                                        Text(NSLocalizedString("submit.error.retry", comment: "Retry submit"))
                                            .font(DSFonts.inter(size: 12, weight: .semibold))
                                            .foregroundColor(DSColor.onError)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 4)
                                            .background(
                                                Capsule().stroke(DSColor.onError.opacity(0.6), lineWidth: 1)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("submit-error-retry")
                                    .accessibilityLabel(NSLocalizedString("submit.error.retry", comment: "Retry submit"))
                                }
                            }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(DSColor.error)
                                .padding(.top, 8)
                                .transition(.move(edge: .top).combined(with: .opacity))
                                .accessibilityIdentifier("submit-error-toast")
                                .accessibilityElement(children: .contain)
                                .accessibilityHint(NSLocalizedString("Tap or swipe to dismiss", comment: "submit error toast dismiss hint"))
                                .onTapGesture {
                                    withAnimation(Motion.rise) { viewModel.submitError = nil }
                                }
                                .gesture(
                                    DragGesture(minimumDistance: 20)
                                        .onEnded { value in
                                            if value.translation.height < -10 || abs(value.translation.width) > 40 {
                                                Haptics.soft()
                                                withAnimation(Motion.rise) { viewModel.submitError = nil }
                                            }
                                        }
                                )
                                .onAppear {
                                    Haptics.warn()
                                    UIAccessibility.post(notification: .announcement, argument: err)
                                    let captured = err
                                    Task { @MainActor in
                                        try? await Task.sleep(for: .seconds(3))
                                        if viewModel.submitError == captured {
                                            viewModel.submitError = nil
                                        }
                                    }
                                }
                        }
                    }
                    .animation(Motion.rise, value: viewModel.submitError)
                }
            }
            // CRASH-FIX (真机 arm64e Release 启动栈溢出): TodayView.body 原本在
            // 单一 NavigationStack/ZStack 上链式挂了 ~37 个顶层 modifier
            // (.onChange/.onReceive/.sheet/.fullScreenCover/.overlay)，编译成一个
            // 极深的嵌套泛型类型。真机 Release 下 Swift runtime 用
            // swift_getTypeByMangledName 解析该类型时递归深度超限 → SIGSEGV
            // (KERN_PROTECTION_FAILURE at Stack Guard)。模拟器/Debug 栈布局不同
            // 故不复现。把 modifier 链拆成 3 个 @ViewBuilder 修饰函数，每个返回
            // 独立 `some View` 类型，在中间插入类型边界，打断运行时递归深度。
            .modify { applyNavigationAndOverlays($0) }
            .modify { applyLifecycleHooks($0) }
            .modify { applySheetsAndCovers($0) }
            .modify { applyAuxiliarySheets($0) }
        }
    }

    // MARK: - Body modifier groups (crash-fix: break giant generic type)

    /// navigationBar 隐藏 + 侧栏边缘手势 + memo 详情 navigationDestination。
    @ViewBuilder
    private func applyNavigationAndOverlays(_ content: some View) -> some View {
        content
            .navigationBarHidden(true)
            // US-030: left-edge swipe (within first 20pt) opens sidebar
            .gesture(
                DragGesture(minimumDistance: 20, coordinateSpace: .local)
                    .onEnded { value in
                        guard value.startLocation.x < 20,
                              value.translation.width > 40,
                              abs(value.translation.width) > abs(value.translation.height) * 1.2
                        else { return }
                        nav.openSidebar()
                    }
            )
            .navigationDestination(for: UUID.self) { memoID in
                if let memo = viewModel.memos.first(where: { $0.id == memoID }) {
                    MemoDetailView(memo: memo, vm: viewModel)
                }
            }
            // Programmatic detail navigation for the card-body tap (the swipe
            // card drives this instead of a NavigationLink — see openedMemoID).
            // Uses isPresented (iOS 16+) rather than item: to stay portable.
            .navigationDestination(
                isPresented: Binding(
                    get: { openedMemoID != nil },
                    set: { if !$0 { openedMemoID = nil } }
                )
            ) {
                if let id = openedMemoID,
                   let memo = viewModel.memos.first(where: { $0.id == id }) {
                    MemoDetailView(memo: memo, vm: viewModel)
                        .modifier(CardZoomDestination(
                            id: id, namespace: detailZoomNamespace
                        ))
                }
            }
    }

    /// 所有生命周期/状态监听 hook（onAppear / onChange / onReceive）。
    @ViewBuilder
    private func applyLifecycleHooks(_ content: some View) -> some View {
        content
            .onAppear {
                clearDraftIfExpired()
                // R4-B2: SceneStorage may come back empty after a process kill
                // even though we wrote on every keystroke. Fall back to the
                // UserDefaults mirror so the user doesn't lose the in-flight
                // draft. Only restore when SceneStorage is empty — never
                // clobber a fresh keystroke that's already in flight.
                if draftText.isEmpty,
                   let backup = UserDefaults.standard.string(forKey: draftBackupKey),
                   !backup.isEmpty {
                    draftText = backup
                }
                viewModel.load()
                // Drain any inflight drafts left behind by a submit that
                // never reached RawStorage.append (kill-during-await, OS
                // eviction, explicit cancel). Issue #23.
                viewModel.recoverInflightDrafts()
                updateVoiceQueueBanner(count: voiceQueue.pendingCount)
                showDraftRestoredBannerIfNeeded()
                applyLaunchPresentationFlags()
                if InputBarTutorialOverlay.shouldShow {
                    showTutorial = true
                }
                // Seed the milestone tracker from the current word count so that
                // already-crossed milestones don't re-fire on launch.
                lastWordMilestoneIndex = wordMilestones.filter { $0 <= viewModel.todayWordCount }.count
                // R3 — A2: seed AI key state so the banner appears (or stays
                // hidden) on the very first render rather than only after the
                // next scenePhase flip.
                refreshAIKeyMissing()
            }
            .onChange(of: draftText) { _ in
                // B3: Debounce — only persist `draftDate` after typing pauses
                // for 0.8s. Cancels any in-flight write each keystroke, so a
                // burst of typing produces exactly one UserDefaults write.
                //
                // R4-B2: also mirror the body into UserDefaults under
                // `today.draftText.backup`. SceneStorage survives backgrounding
                // but NOT a process kill — iOS may evict saved scene state
                // under memory pressure, and the user loses every keystroke
                // since the last "Send". UserDefaults is flushed at process
                // exit, so it acts as the cold-launch fallback that TodayView
                // .onAppear reads when SceneStorage comes back empty.
                draftSaveTask?.cancel()
                let snapshot = draftText
                draftSaveTask = Task {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        draftDate = Date().timeIntervalSince1970
                        UserDefaults.standard.set(snapshot, forKey: draftBackupKey)
                    }
                }
            }
            .onChange(of: voiceQueue.pendingCount) { count in
                updateVoiceQueueBanner(count: count)
                // When a transcription finishes (count drops), reload memos so the
                // newly-written transcript appears in the card without user intervention.
                viewModel.load()
            }
            // Reload when app returns from background to correct the active date (midnight crossover).
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    viewModel.load()
                    // R3 — A2: re-check Keychain so the banner flips off the
                    // moment the user comes back from Settings → API Keys.
                    refreshAIKeyMissing()
                    // R9-HIGH A1: removed the third refreshWeeklyRecapPreview
                    // call here. .onAppear (cold launch) + .weeklyRecapAvailable
                    // (mid-session daemon publish) already cover the cache-
                    // miss-then-hit window; the scenePhase trigger was a
                    // redundant third path that just thrashed the debounce.
                }
            }
            // Re-seed the word milestone tracker once data finishes loading so
            // pre-existing word counts on app launch don't trigger celebrations.
            .onChange(of: viewModel.loadState) { state in
                if state == .ready {
                    lastWordMilestoneIndex = wordMilestones.filter { $0 <= viewModel.todayWordCount }.count
                }
            }
            // US-017: consume pending draft text from daypage://memo/new?text=…
            .onChange(of: nav.pendingDraftText) { text in
                guard let text else { return }
                draftText = text
                nav.pendingDraftText = nil
            }
            // Bridge the ViewModel settings flag to the View-local sheet binding.
            .onChange(of: viewModel.shouldShowSettings) { show in
                if show {
                    showSettings = true
                    viewModel.shouldShowSettings = false
                }
            }
            // Restore failed draft body into the composer so the user can retry.
            // Only restores when the composer is empty — never clobbers a new draft.
            .onChange(of: viewModel.lastFailedBody) { failedBody in
                guard let body = failedBody else { return }
                viewModel.lastFailedBody = nil
                // R4-B2: clear UserDefaults backup mirror together with the
                // failure-restore path. The restored body has now flowed back
                // into `draftText`, which is itself mirrored to the backup on
                // every keystroke — but if the user dismisses without typing,
                // the stale backup would survive next launch.
                UserDefaults.standard.removeObject(forKey: draftBackupKey)
                guard draftText.isEmpty else { return }
                draftText = body
                orbFocusToggle.toggle()
                Haptics.warn()
            }
            // R8 — wake the top OnThisDayCard as soon as the OnThisDayIndex
            // finishes its first-launch scan. Without this hook, the index
            // would finish ~1-2s after cold launch but the card would stay
            // dark until the next .onAppear / becomeActive pass (or a long-
            // press on the header). Pairs with the @Published isReady flag
            // and the .userInitiated detached task in DayPageApp.
            .onReceive(OnThisDayIndex.shared.$isReady) { ready in
                guard ready else { return }
                Task { @MainActor in
                    await OnThisDayScheduler.shared.refreshTodayEntry()
                }
            }
            // R4-B3: 0 点后台编译失败后，前台 scenePhase active 自动重试
            // 成功时收到这条通知。仅显示 ds-style toast — 不再发系统通知，
            // 避免与已经推过的失败通知互相打架。#814 起前台重试补编的是
            // 昨天（今天只在结束后编译一次），文案随之调整。
            .onReceive(NotificationCenter.default.publisher(for: .compileSucceededForeground)) { _ in
                bannerCenter.show(AppBannerModel(
                    kind: .success,
                    title: NSLocalizedString(
                        "today.compile.foregroundRetry.success",
                        value: "昨日 Daily Page 已补齐编译",
                        comment: "Toast shown when the missed midnight compile is retried on foreground and succeeds"
                    ),
                    autoDismiss: true
                ))
            }
            // R4-MEDIUM #38 — iCloud conflict resolution surfaces here so the
            // user sees that an automatic merge happened. The notification's
            // object is ConflictResolutionInfo; we pull `date` for the banner
            // subtitle and auto-dismiss after 3 seconds.
            .onReceive(NotificationCenter.default.publisher(for: .vaultConflictResolved)) { note in
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                if let info = note.object as? ConflictResolutionInfo {
                    iCloudConflictBannerDate = formatter.string(from: info.date)
                } else {
                    iCloudConflictBannerDate = formatter.string(from: Date())
                }
                withAnimation { iCloudConflictBannerVisible = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    withAnimation { iCloudConflictBannerVisible = false }
                }
            }
    }

    /// 所有 sheet / fullScreenCover / banner / writeSheet overlay 与 quick-capture hook。
    @ViewBuilder
    private func applySheetsAndCovers(_ content: some View) -> some View {
        content
            // Daily Page full-screen sheet
            .fullScreenCover(isPresented: $showDailyPage) {
                let dateStr: String = {
                    let f = DateFormatter()
                    f.dateFormat = "yyyy-MM-dd"
                    f.locale = Locale(identifier: "en_US_POSIX")
                    f.timeZone = TimeZone.current
                    return f.string(from: Date())
                }()
                DailyPageView(
                    dateString: dateStr,
                    onReturnToToday: { question in
                        draftText = question
                        showDailyPage = false
                    }
                )
            }
            // Voice recording half-screen sheet
            // On complete: immediately submit the recording as a standalone memo.
            .sheet(isPresented: $viewModel.isShowingVoiceRecorder) {
                VoiceRecordingView(
                    onComplete: { result in
                        viewModel.isShowingVoiceRecorder = false
                        viewModel.addVoiceAndSubmit(result: result)
                    },
                    onCancel: {
                        viewModel.cancelVoiceRecording()
                    }
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.hidden)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            // Issue #804: Today sparkle → 陪写引导（TodayCoachView），不再是
            // AskPastView。前者引导写下一条今日 memo，后者是 RAG 历史检索——
            // 用户 tap "让 AI 陪你聊聊今天" 应该进入陪写而非搜索。
            // AskPastView 仍由侧边栏「问过去」和 Siri intent 触发。
            .sheet(isPresented: $showTodayCoach) {
                TodayCoachView(
                    onClose: { showTodayCoach = false },
                    onDidPinDraft: {
                        // 存入后刷新 timeline，让新 memo 立刻可见
                        viewModel.load()
                    }
                )
            }
            // US-019: Markdown export share sheet
            .sheet(isPresented: $showExportSheet) {
                if let url = exportFileURL {
                    ShareSheet(activityItems: [url])
                }
            }
            // Document picker sheet
            .sheet(isPresented: $viewModel.isShowingDocumentPicker) {
                DocumentPickerView(
                    onPick: { url in
                        viewModel.addFileAttachment(url: url)
                    },
                    onCancel: {
                        viewModel.isShowingDocumentPicker = false
                    }
                )
                .ignoresSafeArea()
            }
            // Camera capture sheet (fullScreenCover so the camera UI uses full screen)
            .fullScreenCover(isPresented: $viewModel.isShowingCamera) {
                CameraPickerView(
                    onCapture: { image in
                        viewModel.isShowingCamera = false
                        viewModel.addCameraPhotoAndSubmit(image)
                    },
                    onCancel: {
                        viewModel.isShowingCamera = false
                    }
                )
                .ignoresSafeArea()
            }
            // On This Day navigation to DayDetailView
            .fullScreenCover(item: Binding(
                get: { onThisDayDateString.map { OnThisDayNavTarget(dateString: $0) } },
                set: { onThisDayDateString = $0?.dateString }
            )) { target in
                DayDetailView(dateString: target.dateString)
            }
            // Fallback "yesterday daily page" cover — opened from the zero-memo
            // fallback view when yesterday already has a compiled page.
            // Issue #814: historical days now route to DayDetailView (the
            // 4-state Archive surface with Daily/raw tabs + day swiping) so
            // the app has ONE way to look at a past day instead of two.
            .fullScreenCover(item: Binding(
                get: { fallbackDailyPageDateString.map { OnThisDayNavTarget(dateString: $0) } },
                set: { fallbackDailyPageDateString = $0?.dateString }
            )) { target in
                DayDetailView(dateString: target.dateString)
            }
            // Timeline tap / contextMenu → open that historical day.
            // Kept separate from showDailyPage / fallbackDailyPageDateString so the
            // three navigation entry points don't collide on a single binding.
            .fullScreenCover(item: Binding(
                get: { timelineNavDateString.map { OnThisDayNavTarget(dateString: $0) } },
                set: { timelineNavDateString = $0?.dateString }
            )) { target in
                DayDetailView(dateString: target.dateString)
            }
            // Timeline share sheet — plain text payload, no poster pipeline.
            .sheet(item: $timelineShareText) { payload in
                ShareSheet(activityItems: [payload.text])
            }
    }

    /// banner overlay + tutorial + auth/weekly/migration/share-card sheets +
    /// writeSheet overlay + quick-capture hooks。`applySheetsAndCovers` 的后半，
    /// 进一步拆分以把单段嵌套泛型深度压到栈安全范围内（crash-fix 第二刀）。
    @ViewBuilder
    private func applyAuxiliarySheets(_ content: some View) -> some View {
        content
            .bannerOverlay()
            // US-010: First-run input bar tutorial
            .overlay {
                if showTutorial {
                    InputBarTutorialOverlay(isPresented: $showTutorial)
                        .ignoresSafeArea()
                        .transition(.opacity)
                }
            }
            .animation(Motion.dismiss, value: showTutorial)
            .sheet(isPresented: $showAuthSheet) {
                AuthView()
            }
            // iCloud migration progress sheet — shown during vault migration
            .sheet(isPresented: $migrationService.isMigrating) {
                MigrationProgressSheet(service: migrationService)
            }
            // Issue #302: share-card sheet, opened via long-press on a memo.
            .sheet(item: $sharePayload) { payload in
                ShareCardSheet(payload: payload)
            }
            // v8 WriteSheet — custom bottom sheet (scrim + drag handle + sheet-up
            // anim are drawn inside the view), so it presents as a full-screen
            // overlay rather than a system `.sheet`. Saves route through the same
            // `submitCombinedMemo` path the dock composer uses (draftText binding).
            .overlay { writeSheetOverlay }
            .onAppear {
                evaluateSyncBanner()
                // Handle a Quick Capture trigger that fired before TodayView
                // appeared (cold launch via Widget / Siri / URL scheme).
                if nav.pendingRecordingTrigger != nil {
                    viewModel.isShowingVoiceRecorder = true
                    nav.pendingRecordingTrigger = nil
                }
            }
            .onChange(of: authService.session) { _ in
                evaluateSyncBanner()
            }
            .onChange(of: nav.pendingRecordingTrigger) { newValue in
                guard newValue != nil else { return }
                viewModel.isShowingVoiceRecorder = true
                nav.pendingRecordingTrigger = nil
            }
    }

    // MARK: - Sync Banner Logic

    private func evaluateSyncBanner() {
        // If user is already authenticated, never show the banner
        guard authService.session == nil else {
            showSyncBanner = false
            return
        }
        let saveCount = UserDefaults.standard.integer(forKey: AppSettings.Keys.memoSaveCount)
        let authSkipped = UserDefaults.standard.bool(forKey: AppSettings.Keys.authSkipped)
        guard saveCount >= 3, authSkipped else { return }
        let lastShown = UserDefaults.standard.object(forKey: AppSettings.Keys.lastSyncBannerDate) as? Date
        let sevenDays: TimeInterval = 7 * 24 * 3600
        if let last = lastShown, Date().timeIntervalSince(last) < sevenDays { return }
        showSyncBanner = true
    }

    private func applyLaunchPresentationFlags() {
        let args = ProcessInfo.processInfo.arguments
        if launchFlag("openVoiceRecorder", in: args) {
            viewModel.isShowingVoiceRecorder = true
        }
        if launchFlag("openWriteSheet", in: args) {
            showWriteSheet = true
        }
    }

    private func launchFlag(_ key: String, in args: [String]) -> Bool {
        guard let index = args.firstIndex(of: "-\(key)"),
              args.indices.contains(index + 1) else {
            return false
        }
        return ["1", "true", "yes", "YES", "True", "TRUE"].contains(args[index + 1])
    }

    /// F2: tiny pill rendered above the orb greeting when the app is in
    /// offline / AI-disabled mode. Mono10 + inkSubtle + dot keeps it visually
    /// quiet — informational, not alarming.
    private func modeBadge(text: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(DSColor.inkSubtle.opacity(0.5))
                .frame(width: 6, height: 6)
            Text(text)
                .font(DSType.mono10)
                .foregroundColor(DSColor.inkSubtle)
                .textCase(.uppercase)
                .tracking(0.8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(DSColor.glassLo))
        .accessibilityElement(children: .combine)
    }

    // R4-MEDIUM #38 — banner shown when ConflictMerger reports a successful
    // automatic merge. Stays visible 3 seconds, then fades. Tapping the
    // banner currently just dismisses — a "view details" sheet is tracked as
    // a follow-up; the goal here is to acknowledge that something happened
    // so the user doesn't silently lose a write.
    private var iCloudConflictBanner: some View {
        DSBanner(
            kind: .warning,
            title: NSLocalizedString("icloud.conflict.banner.title", comment: ""),
            subtitle: String(
                format: NSLocalizedString("icloud.conflict.banner.body", comment: ""),
                iCloudConflictBannerDate
            ),
            primaryAction: nil,
            onDismiss: {
                withAnimation { iCloudConflictBannerVisible = false }
            }
        )
        .padding(.horizontal, DSSpacing.pageMargin)
        .padding(.bottom, DSSpacing.xs)
        .onTapGesture {
            withAnimation { iCloudConflictBannerVisible = false }
        }
    }

    private var syncBanner: some View {
        DSBanner(
            kind: .info,
            title: "Sync your journal across devices",
            subtitle: "Sign in to back up your notes",
            primaryAction: (label: "Sync", action: { showAuthSheet = true }),
            onDismiss: {
                withAnimation { showSyncBanner = false }
                UserDefaults.standard.set(Date(), forKey: AppSettings.Keys.lastSyncBannerDate)
            }
        )
        .padding(.horizontal, DSSpacing.pageMargin)
        .padding(.bottom, DSSpacing.xs)
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    if value.translation.height < -10 {
                        withAnimation { showSyncBanner = false }
                        UserDefaults.standard.set(Date(), forKey: AppSettings.Keys.lastSyncBannerDate)
                    }
                }
        )
    }

    // MARK: - AI key missing banner (R3 — A2)
    //
    // Shown when either the DeepSeek (Qwen-compatible) compile key or the
    // OpenAI Whisper key is missing in Keychain AND not bundled at build
    // time. Both keys gate user-visible behaviour (daily compile + voice
    // transcription), so a single banner that covers either signal avoids
    // a second-banner sprawl. CTA jumps to the in-app SettingsView (the
    // API Keys section) rather than UIApplication.openSettingsURLString
    // (which would take the user to the system Settings app where there's
    // nothing to configure).

    // MARK: - R9-HIGH A2/A3 — Banner stack guards
    //
    // `bannerCount` counts the always-renders-at-top sections (AI key,
    // sync queue, iCloud conflict). When too many fire at once the
    // composer gets pushed below the fold on iPhone 12 mini, so the
    // OnThisDay top card and WeeklyRecap preview defer to it. Read by
    // both `shouldShowOnThisDayAtTop` and the top WeeklyRecap section
    // guard in `body`.
    private var bannerCount: Int {
        var n = 0
        // R10 (#793): AI key banner now only shows on empty days; align
        // bannerCount so OnThisDay / WeeklyRecap cards don't yield
        // pre-emptively to a banner that won't actually render.
        if shouldShowAIKeyBanner && viewModel.memos.isEmpty { n += 1 }
        if FeatureFlagStore.shared.isEnabled(.offlineQueue)
            && (syncQueue.pendingCount >= 5 || syncQueueWaitedTooLong) { n += 1 }
        if iCloudConflictBannerVisible { n += 1 }
        return n
    }

    /// R9-HIGH A2: single source of truth for whether the top-of-Today
    /// OnThisDay card renders. Used by both the `body` top section and
    /// the `onThisDayFallback(memos:)` inverse guard so the two paths
    /// agree inside the same SwiftUI render pass — no more lazy
    /// `.onAppear` flip that briefly stacked two cards. The `bannerCount`
    /// guard yields to the "system status" banners when ≥ 2 already
    /// occupy the top: in that case the fallback (empty-day) path still
    /// surfaces the card if the day has no memos to push it offscreen.
    private var shouldShowOnThisDayAtTop: Bool {
        FeatureFlagStore.shared.isEnabled(.onThisDay)
            && viewModel.onThisDayEntry != nil
            && bannerCount < 2
    }

    /// True when the banner should appear in this render. Combines:
    /// missing key + onboarded + within session not dismissed + 24h
    /// cooldown elapsed.
    private var shouldShowAIKeyBanner: Bool {
        // R5: feature-flag kill switch — flipping `.aiKeyBanner` off in
        // Settings → Experiments hides the banner entirely without
        // touching the underlying key-detection logic. The flag default-on
        // means upgraders see the banner exactly like before.
        guard FeatureFlagStore.shared.isEnabled(.aiKeyBanner) else { return false }
        guard aiKeyMissing else { return false }
        // justOnboarded ≡ user hasn't finished onboarding yet. The
        // Onboarding ApiKeysPage already handles the key-entry flow, and
        // surfacing this banner over the onboarding chrome would be
        // double-talk.
        let hasOnboarded = UserDefaults.standard.bool(forKey: AppSettings.Keys.hasOnboarded)
        guard hasOnboarded else { return false }
        // Manual dismiss this session always wins.
        guard !aiBannerDismissedSession else { return false }
        // 24h cooldown — store as absolute epoch so a SceneStorage round-
        // trip is enough; no Date(timeIntervalSinceReferenceDate:) drift.
        if aiBannerDismissedUntil > Date().timeIntervalSince1970 { return false }
        return true
    }

    /// Inspect Keychain (+ compile-time fallback) for the two AI keys we
    /// surface in this banner: DeepSeek/Qwen compile and OpenAI Whisper.
    /// OpenWeather is omitted by design — its absence is not a hard
    /// block on the diary loop.
    private func refreshAIKeyMissing() {
        let compileMissing  = Secrets.resolvedDeepSeekApiKey.isEmpty
        let whisperMissing  = Secrets.resolvedOpenAIWhisperApiKey.isEmpty
        let next = compileMissing || whisperMissing
        if next != aiKeyMissing {
            withAnimation(reduceMotion ? nil : Motion.rise) {
                aiKeyMissing = next
            }
        }
    }

    /// The actual banner row. 44pt tall, warm-amber tinted, with a
    /// settings CTA on the right and an x dismiss on the far right.
    /// R3 (#793 comp 4.png): the AI-key surface used to be a 44pt amber-washed
    /// banner with title + CTA pill + dismiss-X. Against the museum reference
    /// that whole strip read as an alert. The comp shows a single thin row of
    /// muted text — "🔑 钥匙就绪后，夜间编译会自动开启 ›" — that taps to open
    /// Settings. No background, no dismiss; the row simply disappears once a
    /// key is present.
    private var aiKeyMissingBanner: some View {
        Button {
            Haptics.soft()
            showSettings = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "key")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(DSColor.amberDeep.opacity(0.85))
                    .accessibilityHidden(true)
                Text(NSLocalizedString(
                    "today.banner.ai_key_missing",
                    value: "钥匙就绪后，夜间编译会自动开启",
                    comment: "Today status line shown when DeepSeek/Whisper key is missing"
                ))
                    .font(DSFonts.serif(size: 13, weight: .regular))
                    .foregroundColor(DSColor.inkSubtle)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DSColor.inkMuted.opacity(0.7))
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString(
            "today.banner.ai_key_missing.cta.a11y",
            value: "前往设置配置 API 密钥",
            comment: "VoiceOver label for the AI key row"
        ))
    }

    // MARK: - Offline Sync Queue Banner (R5)
    //
    // 44pt amber-tinted row mirroring the AI-key banner so the two never
    // visually fight. Left icon spins while `isFlushingNow`, the centre
    // text reports `pendingCount` and (when the oldest pending memo is
    // > 1h old) a red "已等待 N 小时" coda nudges the user to check
    // their network. Tapping the row shows a simple alert.

    /// True when the oldest pending memo has been queued for more than
    /// one hour — used to escalate the banner to a red sub-label. Treats
    /// nil as "no time yet, don't escalate".
    private var syncQueueWaitedTooLong: Bool {
        guard let oldest = syncQueue.oldestPendingDate else { return false }
        return Date().timeIntervalSince(oldest) > 3600
    }

    /// Whole-hour count of how long the oldest memo has been waiting.
    /// Clamped to a minimum of 1 so we never print "已等待 0 小时" —
    /// `syncQueueWaitedTooLong` already gates on > 1h.
    private var syncQueueWaitedHours: Int {
        guard let oldest = syncQueue.oldestPendingDate else { return 0 }
        return max(1, Int(Date().timeIntervalSince(oldest) / 3600))
    }

    /// R6: stricter escalation — when the oldest pending memo is more
    /// than 24h old we surface a louder red sub-label nudging the user
    /// to actually do something (check network, re-auth). 24h is the
    /// threshold beyond which "spotty Wi-Fi" stops being a credible
    /// explanation.
    private var syncQueueWaitedOverDay: Bool {
        guard let oldest = syncQueue.oldestPendingDate else { return false }
        return Date().timeIntervalSince(oldest) > 86_400
    }

    /// Headline copy for the banner. Shifts from neutral "N 条 memo 待同步"
    /// to the active "正在同步 N 条…" while an upload is in flight so
    /// the user can tell the spin actually means progress.
    private var syncQueuePrimaryLabel: String {
        let count = syncQueue.pendingCount
        if syncQueue.isFlushingNow {
            return String(
                format: NSLocalizedString(
                    "today.syncqueue.banner.flushing",
                    value: "正在同步 %d 条…",
                    comment: "Today banner headline while an upload pass is running"
                ),
                count
            )
        }
        return String(
            format: NSLocalizedString(
                "today.syncqueue.banner.pending",
                value: "%d 条 memo 待同步",
                comment: "Today banner headline: N memos waiting for cloud sync"
            ),
            count
        )
    }

    /// Issue #5 (2026-07-03): pipeline-stage banner. Rendered above the
    /// timeline while the AI compile is running. The bar advances on
    /// stage transitions inside `BackgroundCompilationService.compileWithRetry`
    /// (Issue #5's other half). We deliberately avoid an indeterminate
    /// spinner because "spinner in the corner + no other feedback" is the
    /// exact behavior the backlog issue calls out as broken UX.
    private var compileProgressBanner: some View {
        HStack(spacing: 10) {
            // Issue #5 (2026-07-03): iOS 16 target — `symbolEffect(.pulse)`
            // requires iOS 17. Use a manual opacity breath so the icon
            // still reads as "AI is working" without conditionally
            // targeting SDK levels.
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DSColor.amberAccent)
                .opacity(compileService.stage == .idle ? 1.0 : 0.6)
                .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                           value: compileService.stage)

            VStack(alignment: .leading, spacing: 4) {
                Text(compileService.stageLabel)
                    .font(DSType.bodySM)
                    .foregroundColor(DSColor.inkPrimary)
                    .accessibilityIdentifier("today.compile.stage.label")

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(DSColor.surfaceSunken)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(DSColor.amberAccent)
                            .frame(width: max(6, geo.size.width * CGFloat(compileService.stageFraction)))
                            .animation(.easeInOut(duration: 0.4), value: compileService.stageFraction)
                    }
                }
                .frame(height: 4)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(DSColor.surfaceWhite)
        .overlay(
            RoundedRectangle(cornerRadius: DSSpacing.radiusCard)
                .strokeBorder(DSColor.amberRim, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: DSSpacing.radiusCard))
        .padding(.horizontal, DSSpacing.pageMargin)
        .padding(.bottom, DSSpacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("AI 编译进行中：\(compileService.stageLabel)")
    }

    /// Issue #13 (2026-07-03): horizontal chip row for the day's declared
    /// focus lenses. Uses the same amber/soft palette as the Daily page
    /// entity chips so the surface reads as "the AI knows you're paying
    /// attention here" rather than a filter widget.
    /// Issue #15 (2026-07-03): dynamicTypeSize cap so chip row doesn't
    /// blow up past `.accessibility2` on iPhone SE — SE + `.accessibility3`
    /// is where SwiftUI chip rows historically clip content.
    private var todayFocusRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("今日焦点")
                    .font(DSType.mono10)
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundColor(DSColor.inkMuted)
                    .padding(.trailing, 4)
                ForEach(TodayFocus.allCases, id: \.self) { focus in
                    let isSelected = focusStore.focuses.contains(focus)
                    Button {
                        Haptics.soft()
                        focusStore.toggle(focus)
                    } label: {
                        Text(focus.displayName)
                            .font(DSType.bodySM)
                            .foregroundColor(isSelected ? DSColor.surfaceWhite : DSColor.amberDeep)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(isSelected ? DSColor.amberDeep : DSColor.amberSoft)
                            )
                            .overlay(
                                Capsule().strokeBorder(DSColor.amberRim, lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("today.focus.chip.\(focus.rawValue)")
                    .accessibilityLabel("\(focus.displayName) 焦点")
                    .accessibilityValue(isSelected ? "已选中" : "未选中")
                }
            }
            .padding(.horizontal, DSSpacing.pageMargin)
        }
        .dynamicTypeSize(.xSmall ... .accessibility2)
    }

    private var syncQueuePendingBanner: some View {
        Button {
            // R6: open the detail sheet so the user can actually see which
            // memos are stuck. The bare BannerCenter alert worked but
            // hid the data behind one more tap.
            Haptics.tapConfirm()
            showSyncQueueSheet = true
        } label: {
            HStack(spacing: 10) {
                // Spinning sync icon when an upload is actually in
                // flight, static otherwise. Spin faster (0.6s vs 1.0s)
                // while flushing so the change of state is legible at
                // a glance, not just inferable from the icon being in
                // motion at all.
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DSColor.amberAccent)
                    .rotationEffect(.degrees(syncQueue.isFlushingNow ? 360 : 0))
                    .animation(
                        syncQueue.isFlushingNow
                            ? .linear(duration: 0.6).repeatForever(autoreverses: false)
                            : .default,
                        value: syncQueue.isFlushingNow
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(syncQueuePrimaryLabel)
                        .font(DSFonts.inter(size: 13, weight: .medium))
                        .foregroundColor(DSColor.inkPrimary)
                        .lineLimit(1)

                    // 24h escalation takes precedence over the 1h variant
                    // — losing the day is the bigger story.
                    if syncQueueWaitedOverDay {
                        Text(NSLocalizedString(
                            "today.syncqueue.banner.waited_over_day",
                            // R9-LOW A4: rewrite explains *why* the queue is
                            // stuck. The old "超过 24 小时未同步" implies the
                            // app is broken; the new phrasing surfaces the
                            // real cause (network) so users know what to do.
                            value: "网络受限，已等待超过 24 小时",
                            comment: "Today banner sub-label: queue stuck > 24h"
                        ))
                            .font(DSFonts.inter(size: 11, weight: .semibold))
                            .foregroundColor(.red)
                            .lineLimit(1)
                    } else if syncQueueWaitedTooLong {
                        Text(String(
                            format: NSLocalizedString(
                                "today.syncqueue.banner.waited_hours",
                                value: "已等待 %d 小时",
                                comment: "Today banner sub-label: queue stuck for N hours"
                            ),
                            syncQueueWaitedHours
                        ))
                            .font(DSFonts.inter(size: 11, weight: .semibold))
                            .foregroundColor(.red)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, DSSpacing.pageMargin)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(DSColor.amberAccent.opacity(0.14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // VoiceOver hears the full picture (count + wait time) as a
        // single element rather than two unrelated labels.
        .accessibilityElement(children: .combine)
        .sheet(isPresented: $showSyncQueueSheet) {
            syncQueuePendingSheet
        }
    }

    /// Detail sheet listing pending memo IDs (R8: up to 50) and the
    /// oldest-pending timestamp. Each row is a tappable button that posts
    /// `.openMemo` for a future memo-detail router. Until that router
    /// lands the post is harmless — the sheet dismisses and a Sentry
    /// breadcrumb confirms the tap landed.
    private var syncQueuePendingSheet: some View {
        // R8: cap at 50 to avoid SwiftUI List perf cliffs on very large
        // queues. The summary line still reports the true total.
        let pending = Array(syncQueue.pendingMemoIDs).sorted().prefix(50)
        let oldest = syncQueue.oldestPendingDate
        return NavigationView {
            List {
                Section {
                    Text(String(
                        format: NSLocalizedString(
                            "today.syncqueue.sheet.summary",
                            value: "%d 条 memo 等待上传",
                            comment: "Sync queue sheet summary: N memos pending"
                        ),
                        syncQueue.pendingCount
                    ))
                        .font(DSFonts.inter(size: 14, weight: .medium))
                    if let oldest = oldest {
                        Text(String(
                            format: NSLocalizedString(
                                "today.syncqueue.sheet.oldest",
                                value: "最早一条：%@",
                                comment: "Sync queue sheet: oldest pending timestamp"
                            ),
                            DateFormatter.localizedString(
                                from: oldest,
                                dateStyle: .short,
                                timeStyle: .short
                            )
                        ))
                            .font(DSFonts.inter(size: 12, weight: .regular))
                            .foregroundColor(DSColor.inkSecondary)
                    }
                }

                Section(header: Text(NSLocalizedString(
                    "today.syncqueue.sheet.list_header",
                    value: "待同步 memo（最多 50 条）",
                    comment: "Sync queue sheet: section header for the pending list"
                ))) {
                    if pending.isEmpty {
                        // R8: explicit empty state — distinct from the
                        // "queue drained while sheet was open" UX so the
                        // user isn't left looking at a blank section.
                        Text(NSLocalizedString(
                            "today.syncqueue.sheet.empty",
                            value: "无待同步条目",
                            comment: "Sync queue sheet: empty-state body"
                        ))
                            .font(DSFonts.inter(size: 13, weight: .regular))
                            .foregroundColor(DSColor.inkSecondary)
                    } else {
                        ForEach(pending, id: \.self) { id in
                            Button {
                                // Forward to a (future) memo detail
                                // router. Listener TODO — for now the
                                // post is observable via Sentry
                                // breadcrumb so dogfooders can verify
                                // taps reach this code path.
                                NotificationCenter.default.post(
                                    name: .openMemo,
                                    object: nil,
                                    userInfo: ["memoID": id]
                                )
                                SentryReporter.breadcrumb(
                                    category: "syncqueue",
                                    level: .info,
                                    message: "syncQueue.sheet tap memoID=\(id.prefix(8))"
                                )
                                showSyncQueueSheet = false
                            } label: {
                                HStack(spacing: 12) {
                                    // Left: compact ID prefix as a
                                    // disambiguator. We don't have a
                                    // per-memo created timestamp on the
                                    // queue (it's metadata-only), so we
                                    // surface 8 chars of the ID rather
                                    // than claim to know more than we do.
                                    Text(id.prefix(8))
                                        .font(.system(.footnote, design: .monospaced))
                                        .foregroundColor(DSColor.inkSecondary)
                                    Text(NSLocalizedString(
                                        "today.syncqueue.sheet.memo_row",
                                        value: "memo",
                                        comment: "Sync queue sheet: per-row label"
                                    ))
                                        .font(DSFonts.inter(size: 13, weight: .regular))
                                        .foregroundColor(DSColor.inkPrimary)
                                        .lineLimit(1)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.footnote)
                                        .foregroundColor(DSColor.inkSecondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("syncqueue-row-\(id.prefix(8))")
                        }
                    }
                }

                Section {
                    Text(NSLocalizedString(
                        "today.syncqueue.sheet.footnote",
                        value: "等待网络恢复后自动同步。",
                        comment: "Sync queue sheet: footnote explaining auto-retry"
                    ))
                        .font(DSFonts.inter(size: 12, weight: .regular))
                        .foregroundColor(DSColor.inkSecondary)
                }
            }
            .navigationTitle(NSLocalizedString(
                "today.syncqueue.sheet.title",
                value: "待同步队列",
                comment: "Sync queue sheet navigation title"
            ))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString(
                        "today.syncqueue.sheet.close",
                        value: "关闭",
                        comment: "Sync queue sheet: close button"
                    )) {
                        showSyncQueueSheet = false
                    }
                }
            }
        }
    }

    // MARK: - Fallback Content (zero-memo today)

    /// Shown in the timeline when the user is onboarded but today has no memos.
    /// Priority is decided by `viewModel.fallbackContent`; each branch falls
    /// back to existing components instead of inventing a new visual language.
    @ViewBuilder
    private var fallbackContentView: some View {
        switch viewModel.fallbackContent {
        case .yesterdayDailyPage(let page):
            yesterdayDailyPageFallback(page)
        case .onThisDay(let memos):
            onThisDayFallback(memos: memos)
        case .weekRecap(let entries):
            WeeklyRecapSection(entries: entries) { dateString in
                onThisDayDateString = dateString
            }
        case .pureEmpty:
            // R3 (#793 comp 4.png): orbHero now carries the full empty-state
            // expression — warm glow + serif poem ("把今天放下来。" / "我陪你
            //整理。") + AI CTA. The previous EmptyStateView.todayNoSignals
            // line ("暂时没有信号浮现。") read as a second, heavier headline
            // stacked under the poem and broke the calm museum rhythm.
            // Streak kicker still surfaces for users on a multi-day streak —
            // that's earned context, not space-filler.
            VStack(spacing: 8) {
                let streak = sidebarVM.currentStreak
                if streak >= 2 {
                    let kickerText = String(
                        format: NSLocalizedString("today.empty.streak.kicker", comment: ""),
                        streak
                    )
                    Text(kickerText)
                        .font(DSType.mono10)
                        .tracking(1.0)
                        .foregroundColor(DSColor.inkSubtle)
                        .textCase(.uppercase)
                        .dynamicTypeSize(.xSmall ... .accessibility5)
                        .accessibilityLabel(kickerText)
                        .transition(.opacity)
                        .padding(.top, 12)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: - Yesterday Section (shared by fallback and supplement paths)

    @ViewBuilder
    private func yesterdaySection(_ page: DailyPageModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString("today.section.yesterday", comment: ""))
                .font(DSType.mono10)
                .tracking(1.0)
                .foregroundColor(DSColor.inkSubtle)
                .dynamicTypeSize(.xSmall ... .accessibility5)
                .padding(.horizontal, 20)

            DailyPageEntryCard(
                summary: page.summary.isEmpty ? nil : page.summary,
                onTap: {
                    fallbackDailyPageDateString = page.dateString
                }
            )
            .padding(.horizontal, 20)
        }
    }

    // MARK: - History Supplement (memos present — shown at timeline bottom)

    /// History supplement rendered below today's raw memos. Previously this
    /// only showed yesterday's compiled page or the weekly recap; now it owns
    /// the full historical timeline (#276) — this week's other days, last
    /// week, week-before-last, and older months as expandable cards.
    @ViewBuilder
    private var historySupplement: some View {
        if !viewModel.memos.isEmpty && viewModel.loadState == .ready && !viewModel.timelineSections.isEmpty {
            // Quiet breathing room replaces the redundant "EARLIER" rule —
            // the timeline's own SectionHeader (本周/上周) already separates bands.
            Color.clear
                .frame(height: 20)
                .accessibilityLabel(Text(NSLocalizedString("today.section.earlier", comment: "")))
            ForEach(viewModel.timelineSections) { section in
                TimelineSectionView(
                    section: section,
                    onOpenDate: { dateString in timelineNavDateString = dateString },
                    onShareDate: { entry in shareTimelineDay(entry) },
                    onDeleteDate: { entry in deleteTimelineDay(entry) }
                )
            }
        }
    }

    // MARK: - Earlier Divider

    /// Horizontal rule with "EARLIER" label that visually separates today's
    /// memo list from the history supplement section.
    private var earlierDivider: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(DSColor.inkFaint)
                .frame(height: 0.5)
            Text(NSLocalizedString("today.section.earlier", comment: ""))
                .font(DSType.mono10)
                .tracking(1.0)
                .foregroundColor(DSColor.inkSubtle)
                .dynamicTypeSize(.xSmall ... .accessibility5)
                .padding(.horizontal, 8)
            Rectangle()
                .fill(DSColor.inkFaint)
                .frame(height: 0.5)
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func yesterdayDailyPageFallback(_ page: DailyPageModel) -> some View {
        yesterdaySection(page)
    }

    @ViewBuilder
    private func onThisDayFallback(memos: [Memo]) -> some View {
        // R6 — 时光胶囊 kill switch. When the user flips
        // Settings → Experiments → 时光胶囊 off, suppress the card entirely
        // (the index / scheduler stay installed but inert) so a misbehaving
        // candidate selector can be killed without a hot-fix build.
        //
        // R9-HIGH A2: gated on `!shouldShowOnThisDayAtTop` so this
        // fallback path is the inverse of the top section's guard. Both
        // paths read the same computed in the same render pass — no
        // more lazy onAppear flag flip, no more brief double-render.
        // Empty-day users with only a synthesized memo-derived entry
        // still see a card here (because `viewModel.onThisDayEntry` may
        // be nil and the top guard skips). Same goes for the A3
        // banner-overflow path: when banners crowd the top, the top
        // card is suppressed but this fallback still surfaces it.
        if FeatureFlagStore.shared.isEnabled(.onThisDay) && !shouldShowOnThisDayAtTop {
            // Prefer the structured `onThisDayEntry` (carries yearsAgo + filePath);
            // synthesize a lightweight one from memos when the index is cold.
            let entry = viewModel.onThisDayEntry ?? OnThisDayEntry(
                originalDate: memos.first?.created ?? Date(),
                yearsAgo: nil,
                daysAgo: nil,
                preview: memos.first?.body.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                filePath: ""
            )
            OnThisDayCard(
                entry: entry,
                onDismiss: {
                    // R6: persist the dismiss for the rest of the day via
                    // Scheduler so a relaunch within the same local day stays
                    // quiet. The session-only `onThisDayEntry = nil` also
                    // hides the card immediately while the persistence
                    // round-trips.
                    OnThisDayScheduler.shared.markDismissedForToday()
                    viewModel.onThisDayEntry = nil
                },
                onTap: { tapped in
                    handleOnThisDayTap(tapped)
                }
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    /// R6 — tap callback for the OnThisDayCard. Drives the in-Today
    /// `fullScreenCover` (existing `onThisDayDateString` binding) AND posts
    /// `.openArchiveAt` so a deep-link consumer (Archive tab, navigation
    /// model) can pivot to the historical day. The Notification post is
    /// harmless when there's no listener — Archive may not be mounted yet
    /// on a cold tap, in which case the fullScreenCover path handles UX.
    private func handleOnThisDayTap(_ entry: OnThisDayEntry) {
        let dateStr = Self.dateString(from: entry.originalDate)
        // Keep the in-Today fullScreenCover path so the existing UX (open the
        // historical DayDetail without switching tabs) still works.
        onThisDayDateString = dateStr
        // Forward to .openArchiveAt for consumers that want to pivot to
        // Archive instead — R5 backlinks + EntityPageView already use this
        // bus, so OnThisDay rides the same channel.
        NotificationCenter.default.post(
            name: .openArchiveAt,
            object: nil,
            userInfo: ["date": dateStr]
        )
    }

    private static func dateString(from date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f.string(from: date)
    }

    // MARK: - Swipeable Daily Page Card

    /// Daily Page entry card with a left-swipe-to-reveal "重新编译" action.
    /// Mirrors the SwipeableMemoCard interaction: drag the card left, snap
    /// open at -44pt, tap the revealed amber button to recompile, or tap
    /// the card itself to dismiss the open state.
    @ViewBuilder
    private var swipeableDailyPageCard: some View {
        ZStack(alignment: .center) {
            HStack(spacing: 0) {
                Spacer()
                Button {
                    withAnimation(Motion.spring) {
                        dailyPageRevealed = false
                    }
                    viewModel.compile()
                } label: {
                    Text(NSLocalizedString("today.action.recompile", comment: ""))
                        .font(DSType.caption)
                        .foregroundColor(.white)
                        .frame(width: 80)
                        .frame(maxHeight: .infinity)
                        .background(DSColor.accentAmber)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("a11y.recompile", comment: "Recompile daily page"))
            }

            DailyPageEntryCard(
                summary: viewModel.dailyPageSummary,
                onTap: {
                    if dailyPageRevealed {
                        Haptics.soft()
                        withAnimation(Motion.spring) {
                            dailyPageRevealed = false
                        }
                    } else {
                        Haptics.tapConfirm()
                        showDailyPage = true
                    }
                }
            )
            .accessibilityElement(children: .combine)
            .accessibilityHint(NSLocalizedString("today.accessibility.dailypage.hint", comment: ""))
            .accessibilityAction(named: Text(NSLocalizedString("today.action.recompile", comment: ""))) {
                viewModel.compile()
                withAnimation(Motion.spring) {
                    dailyPageRevealed = false
                }
            }
            .offset(x: (dailyPageRevealed ? -80 : 0) + dailyPageDrag + dailyPageHintOffset)
            .onAppear {
                guard !UserDefaults.standard.bool(forKey: AppSettings.Keys.dailyPageSwipeHintShown),
                      !reduceMotion else { return }
                UserDefaults.standard.set(true, forKey: AppSettings.Keys.dailyPageSwipeHintShown)
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(0.6))
                    withAnimation(Motion.spring) { dailyPageHintOffset = -24 }
                    Haptics.soft()
                    try? await Task.sleep(for: .seconds(0.45))
                    withAnimation(Motion.spring) { dailyPageHintOffset = 0 }
                }
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 10)
                    .updating($dailyPageDrag) { value, state, _ in
                        if value.translation.width < 0 {
                            state = value.translation.width
                        }
                    }
                    .onEnded { value in
                        withAnimation(Motion.spring) {
                            dailyPageRevealed = value.translation.width < -44
                        }
                    }
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(NSLocalizedString("a11y.daily_page", comment: "Daily page card"))
        .accessibilityValue(viewModel.dailyPageSummary ?? "")
        .accessibilityHint(NSLocalizedString("a11y.daily_page.hint", comment: "Daily page open hint"))
        .accessibilityAction { showDailyPage = true }
        .accessibilityAction(named: Text(NSLocalizedString("today.action.recompile", comment: ""))) {
            dailyPageRevealed = false
            viewModel.compile()
        }
    }

    // MARK: - Day Orb Hero

    /// Hero region shown at the top of Today on an empty day — designed against
    /// the museum-aesthetic reference (#793 R3): a soft warm-cream glow ellipse
    /// behind a two-line serif poem ("把今天放下来。" / "我陪你整理。"), with a
    /// quiet "让 AI 陪你聊聊今天" CTA at the bottom that opens AskPastView.
    /// The 140pt DayOrbView still anchors the glow's tap-to-focus behavior but
    /// is now visually subordinate to the poem; the orb's halo IS the warm
    /// ellipse the comp shows. The old mono kicker (DATE · TIME · N SIGNALS)
    /// is dropped — empty days don't need metadata, they need an invitation.
    @ViewBuilder
    private var orbHero: some View {
        VStack(spacing: 0) {
            // F2: status badge stays at the very top — it's a "why doesn't
            // compile work?" affordance, not decoration.
            if !aiFeaturesEnabled {
                modeBadge(text: NSLocalizedString("today.badge.ai_off",
                                                  comment: "Today header badge: AI features are turned off"))
                    .padding(.bottom, 18)
            } else if !networkMonitor.isOnline {
                modeBadge(text: NSLocalizedString("today.badge.offline",
                                                  comment: "Today header badge: device is offline"))
                    .padding(.bottom, 18)
            } else {
                // Reserve a similar amount of breathing room so the poem's
                // vertical center is stable whether the badge is shown or not.
                Spacer().frame(height: 6)
            }

            // The warm glow + poem stack. The glow is the orb's own halo —
            // we drop a DayOrbView under the text and let its breathing shadow
            // become the cream ellipse the comp shows. The orb itself is set
            // to a very low base opacity so the *light* shows but the *ball*
            // does not draw attention away from the poem.
            ZStack {
                // Warm amber glow — pure radial gradient instead of the
                // tinted DayOrbView. The previous code passed `orbTint(now)`
                // into the orb's gradient which in deep-night reads as cold
                // gray (reference comp shows cream/amber regardless of time).
                // A hand-rolled RadialGradient keeps the museum warmth fixed.
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: DSColor.amberDeep.opacity(orbBreathing ? 0.32 : 0.22), location: 0.0),
                        .init(color: DSColor.amberDeep.opacity(orbBreathing ? 0.20 : 0.14), location: 0.30),
                        .init(color: DSColor.accentAmber.opacity(orbBreathing ? 0.10 : 0.07), location: 0.55),
                        .init(color: Color.clear, location: 1.0)
                    ]),
                    center: .center,
                    startRadius: 0,
                    endRadius: 180
                )
                .frame(width: 360, height: 320)
                .blur(radius: 28)
                .scaleEffect(reduceMotion ? 1.0 : (orbBreathing ? 1.03 : 0.99))
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 3.6).repeatForever(autoreverses: true),
                    value: orbBreathing
                )
                .accessibilityHidden(true)
                // Invisible tap target — preserves "tap orb to focus composer"
                // behavior the original DayOrbView wired up.
                .contentShape(Ellipse())
                .onTapGesture {
                    Haptics.tapConfirm()
                    if draftText.isEmpty {
                        draftText = orbCapturePrompt(currentTime)
                    }
                    orbFocusToggle.toggle()
                }

                VStack(spacing: 8) {
                    Text(NSLocalizedString("today.empty.poem.title",
                                           comment: "Empty-state poem main line (e.g. 把今天放下来。)"))
                        .font(DSFonts.serif(size: 28, weight: .regular))
                        .foregroundColor(DSColor.inkPrimary)
                        .multilineTextAlignment(.center)
                        .dynamicTypeSize(.xSmall ... .accessibility2)
                        .minimumScaleFactor(0.7)
                    Text(NSLocalizedString("today.empty.poem.subtitle",
                                           comment: "Empty-state poem secondary line (e.g. 我陪你整理。)"))
                        .font(DSFonts.serif(size: 17, weight: .regular))
                        .foregroundColor(DSColor.inkSubtle)
                        .multilineTextAlignment(.center)
                        .dynamicTypeSize(.xSmall ... .accessibility2)
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(height: 280)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(NSLocalizedString("today.empty.poem.a11y",
                                                  comment: "Combined accessibility label for the empty-state poem and orb"))
            .accessibilityHint(NSLocalizedString("today.orb.hint", comment: ""))
            .onLongPressGesture(minimumDuration: 0.5) {
                Haptics.medium()
                guard draftText.isEmpty else { return }
                draftText = orbCapturePrompt(currentTime)
                orbFocusToggle.toggle()
            }

            // CTA: 让 AI 陪你聊聊今天 — quiet amber sparkle + serif text.
            // Issue #804: tap opens TodayCoachView（陪写引导），不是 AskPastView。
            // 用户在空态点这个 CTA 是想被引导记录，不是查历史。
            if aiFeaturesEnabled {
                Button {
                    Haptics.tapConfirm()
                    showTodayCoach = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DSColor.amberDeep)
                        Text(NSLocalizedString("today.empty.ai_cta",
                                               comment: "Empty-state AI chat CTA (e.g. 让 AI 陪你聊聊今天)"))
                            .font(DSFonts.serif(size: 15, weight: .medium))
                            .foregroundStyle(DSColor.amberDeep)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("today-empty-ai-cta")
                .padding(.top, 12)
            }

            // Issue #2 (2026-07-02): "See a sample journal" fallback link.
            // For users who skipped or dismissed the Welcome CTA, the empty
            // Today gives no proof of what the AI will produce. Tapping this
            // seeds 3 sample memos + a paired compiled daily.md (see
            // SampleDataSeeder) and refreshes the timeline. Once seeded, the
            // label flips so the user knows exactly what to open next.
            Button {
                Haptics.tapConfirm()
                SampleDataSeeder.seedIfNeeded()
                // Issue #18: single call site records both the sample seed
                // and the surface it came from — the Welcome CTA emits the
                // same event with `surface:"welcome"`, so the debug board
                // shows a real "empty→sample" funnel.
                AnalyticsService.shared.record(
                    AnalyticsService.Name.sampleSeeded,
                    props: ["surface": "today_empty"]
                )
                sampleSeeded = true
                Task { await viewModel.refresh() }
            } label: {
                Text(NSLocalizedString(
                    sampleSeeded ? "today.empty.sample_active" : "today.empty.try_sample",
                    comment: "Empty-state sample-data affordance"))
                    .font(DSType.mono10)
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundColor(DSColor.inkSubtle)
                    .padding(.top, 6)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("today-empty-try-sample")
            .disabled(sampleSeeded)

        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .onAppear {
            if !reduceMotion {
                orbBreathing = true
            }
        }
        .onChange(of: viewModel.memos.count) { count in
            if count > lastMemoCount && !reduceMotion {
                orbCapturePulse.toggle()
            }
        }
    }

    /// Issue #309 W2: top action bar shown while in multi-select mode.
    /// Layout:
    ///   [Cancel]  N selected  [Share N]
    ///
    /// Share is disabled unless 2 ≤ count ≤ maxItems. The "selected" count
    /// uses an explicit `selected.count` argument rather than reading the
    /// optional state again so the view recomputes when the set changes.
    @ViewBuilder
    private func selectionToolbar(selectedIds selected: Set<UUID>) -> some View {
        let count = selected.count
        let canShare = count >= 2 && count <= CollageSnapshot.maxItems
        HStack(spacing: 12) {
            Button(NSLocalizedString("today.select.cancel", comment: "")) {
                Haptics.soft()
                selectedMemoIds = nil
            }
            .font(DSType.mono10)
            .tracking(1.0)
            .textCase(.uppercase)
            .foregroundColor(DSColor.inkSubtle)

            Spacer()

            Text(count == 0
                 ? NSLocalizedString("today.select.prompt", comment: "")
                 : String(format: NSLocalizedString("today.select.count", comment: ""), count))
                .font(DSType.mono10)
                .tracking(1.5)
                .textCase(.uppercase)
                .foregroundColor(DSColor.inkPrimary)
                .modifier(NumericTextContentTransition(value: Double(count), reduceMotion: reduceMotion))
                .animation(reduceMotion ? nil : Motion.spring, value: count)

            Spacer()

            let shareLabel = count >= 2
                ? String(format: NSLocalizedString("today.select.share", comment: ""), count)
                : NSLocalizedString("today.select.share.min", comment: "")
            Button {
                guard canShare else { return }
                Haptics.tapConfirm()
                let memos = viewModel.memos.filter { selected.contains($0.id) }
                sharePayload = .collage(CollageSnapshot.from(memos))
                // Exit selection mode after triggering — sheet replaces the
                // foreground; keeping the toolbar around would feel orphaned.
                selectedMemoIds = nil
            } label: {
                Text(shareLabel)
                    .font(DSType.mono10)
                    .tracking(1.0)
                    .textCase(.uppercase)
                    .foregroundColor(canShare ? .white : DSColor.inkSubtle)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        canShare ? DSColor.amberDeep : DSColor.glassLo,
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canShare)
            .accessibilityLabel(shareLabel)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // #771: share action bar → glass engine (.control). Engine owns the rim.
        .dpGlass(.control, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func orbGreeting(_ date: Date) -> String {
        NSLocalizedString(TimeOfDay.from(date).greetingKey, comment: "")
    }

    private func todayEmptySubtitle(_ date: Date) -> String {
        let key: String
        switch TimeOfDay.from(date) {
        case .morning:   key = "empty.today.subtitle.morning"
        case .afternoon: key = "empty.today.subtitle.afternoon"
        case .evening:   key = "empty.today.subtitle.evening"
        case .lateNight: key = "empty.today.subtitle.night"
        }
        return NSLocalizedString(key, comment: "")
    }

    private func orbCapturePrompt(_ date: Date) -> String {
        let key: String
        switch TimeOfDay.from(date) {
        case .morning:   key = "today.orb.prompt.morning"
        case .afternoon: key = "today.orb.prompt.afternoon"
        case .evening:   key = "today.orb.prompt.evening"
        case .lateNight: key = "today.orb.prompt.night"
        }
        return NSLocalizedString(key, comment: "")
    }

    /// Returns an integer bucket index (0–3) for the current time-of-day bucket.
    /// Used to key the tint animation so crossfades fire only at bucket boundaries.
    private func orbTintBucket(_ date: Date) -> Int {
        TimeOfDay.from(date).bucketIndex
    }

    /// Derives a continuously-interpolated ambient hue for the orb breathing glow.
    private func orbTint(_ date: Date) -> Color {
        TimeOfDay.continuousTint(at: date)
    }

    private func orbKicker(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        let count = viewModel.signalCount
        let signalKey = count == 1 ? "today.kicker.signal.one" : "today.kicker.signal.other"
        let signal = NSLocalizedString(signalKey, comment: "")
        let dateStr = f.string(from: date).uppercased()
        let timeStr = Self.headerTimeFmt.string(from: date)
        return "\(dateStr) · \(timeStr) · \(count) \(signal)"
    }

    /// Date + time prefix for the split kicker: "29 MAY · 14:30 · "
    private func orbKickerPrefix(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        let dateStr = f.string(from: date).uppercased()
        let timeStr = Self.headerTimeFmt.string(from: date)
        return "\(dateStr) · \(timeStr) · "
    }

    /// Signal-word suffix for the split kicker: " SIGNALS"
    private func orbKickerSuffix() -> String {
        let count = viewModel.signalCount
        let signalKey = count == 1 ? "today.kicker.signal.one" : "today.kicker.signal.other"
        let signal = NSLocalizedString(signalKey, comment: "")
        return " \(signal)"
    }

    // MARK: - InputBarV4 (variant D: Silent Press-to-Talk)
    //
    // Extracted to avoid "expression too complex" errors in body.

    @ViewBuilder
    private var inputBarV4: some View {
        InputBarV4(
            text: $draftText,
            isSubmitting: viewModel.isSubmitting,
            isLocating: viewModel.isLocating,
            pendingLocation: viewModel.pendingLocation,
            locationAuthStatus: LocationService.shared.authorizationStatus,
            isProcessingPhoto: viewModel.isProcessingPhoto,
            pendingAttachments: viewModel.pendingAttachments,
            onFetchLocation: { viewModel.fetchLocation() },
            onSetLocation: { loc in viewModel.setPendingLocation(loc) },
            onClearLocation: { viewModel.clearPendingLocation() },
            onAddPhoto: { items in
                for item in items {
                    viewModel.addPhotoAttachment(item: item)
                }
            },
            onCapturePhoto: { viewModel.startCameraCapture() },
            onRemoveAttachment: { id in viewModel.removePendingAttachment(id: id) },
            onStartVoiceRecording: { viewModel.startVoiceRecording() },
            onOpenWriteSheet: {
                // Debounce: if the sheet is already presented or transitioning
                // in, ignore the second tap. Prior behavior would flip the
                // bool twice in rapid succession, which SwiftUI coalesced into
                // a no-op render on slow first-launches — the reason users
                // reported "the first tap does nothing, I have to tap twice".
                guard !showWriteSheet else { return }
                Haptics.soft()
                showWriteSheet = true
            },
            onPressToTalkSend: { result in
                viewModel.addVoiceAttachment(result: result)
                let body = draftText
                draftText = ""
                viewModel.submitCombinedMemo(body: body)
                showUndoPill(for: body)
                announceMemoSaved()
            },
            onPressToTalkTranscribe: { transcript in
                if draftText.isEmpty {
                    draftText = transcript
                } else {
                    draftText += (draftText.hasSuffix(" ") ? "" : " ") + transcript
                }
            },
            onAddFile: { viewModel.startFilePicker() },
            onSubmit: {
                let body = draftText
                draftText = ""
                viewModel.submitCombinedMemo(body: body)
                showUndoPill(for: body)
                announceMemoSaved()
            },
            onAskAI: {
                // Issue #804: dock sparkle → TodayCoachView（陪写），不是 AskPast。
                Haptics.tapConfirm()
                showTodayCoach = true
            },
            onAddPhotoAsset: nil,
            batchPhotoProgress: viewModel.batchPhotoProgress,
            batchPhotoTotal: viewModel.batchPhotoTotal,
            requestFocusToggle: orbFocusToggle
        )
    }

    // MARK: - WriteSheet Overlay (v8)
    //
    // Bottom-sheet text composer (composer.jsx:183-345). Bound to the same
    // `draftText` the inline composer uses; on save it calls the identical
    // sequence as `inputBarV4.onSubmit` — submitCombinedMemo(body:) + undo pill —
    // so there is a single persistence path, never a second one.

    @ViewBuilder
    private var writeSheetOverlay: some View {
        if showWriteSheet {
            WriteSheetView(
                text: $draftText,
                onSave: {
                    let body = draftText
                    draftText = ""
                    showWriteSheet = false
                    viewModel.submitCombinedMemo(body: body)
                    showUndoPill(for: body)
                    announceMemoSaved()
                },
                onClose: { showWriteSheet = false },
                pendingLocation: viewModel.pendingLocation,
                isLocating: viewModel.isLocating,
                onToggleLocation: {
                    if viewModel.pendingLocation == nil {
                        viewModel.fetchLocation()
                    } else {
                        viewModel.clearPendingLocation()
                    }
                },
                locationAuthStatus: LocationService.shared.authorizationStatus,
                pendingAttachments: viewModel.pendingAttachments,
                onRemoveAttachment: { id in viewModel.removePendingAttachment(id: id) },
                onAddPhoto: { items in
                    for item in items {
                        viewModel.addPhotoAttachment(item: item)
                    }
                },
                onCapturePhoto: { viewModel.startCameraCapture() },
                onPressToTalkSend: { result in
                    viewModel.addVoiceAttachment(result: result)
                    let body = draftText
                    draftText = ""
                    showWriteSheet = false
                    viewModel.submitCombinedMemo(body: body)
                    showUndoPill(for: body)
                    announceMemoSaved()
                },
                onStartVoiceRecording: { viewModel.startVoiceRecording() },
                onPressToTalkTranscribe: { transcript in
                    if draftText.isEmpty {
                        draftText = transcript
                    } else {
                        draftText += (draftText.hasSuffix(" ") ? "" : " ") + transcript
                    }
                },
                onSubmit: {
                    let body = draftText
                    draftText = ""
                    showWriteSheet = false
                    viewModel.submitCombinedMemo(body: body)
                    showUndoPill(for: body)
                    announceMemoSaved()
                }
            )
            .transition(.opacity)
            .zIndex(50)
        }
    }

    // MARK: - Compile Progress Dots

    @ViewBuilder
    private func compileProgressDots(filled: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(index < filled ? DSColor.accentAmber : DSColor.glassStd)
                    .frame(width: 5, height: 5)
                    .animation(Motion.spring, value: filled)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.Empty.compileDockLocked(
            current: filled,
            remaining: max(0, 3 - filled)
        ))
    }

    // MARK: - US-021 Extracted Subviews

    /// Header bar: serif date, export button, and settings gear.
    /// US-005: background fades to frosted glass once the timeline has scrolled > 8pt.
    @ViewBuilder
    private var sidebarSection: some View {
        let isScrolled = isTimelineScrolled
        let hasMemos = !viewModel.memos.isEmpty
        // The header HStack now participates in normal layout (it owns its
        // height), with the glass/separator drawn as a `.background` behind it.
        // Previously the HStack lived inside `.overlay()` on a zero-height
        // ZStack, so it contributed 0pt to the parent VStack and the orbHero
        // below it slid up and overlapped the 56pt hero title. (#590)
        // Museum-aesthetic hero header — always shows the large weekday title
        // (Thursday / 星期四) over a fine MAY 28 · 2 NOTES · ☀ 28° · CITY subline.
        // The compact Orb-chip variant for non-empty days has been removed:
        // it crowded the top bar with metadata and broke the calm rhythm
        // shown in the design comp. Toolbar icons (☰ / share / ⚙) live in
        // a separate row above this hero.
        VStack(alignment: .leading, spacing: 16) {
            // MARK: Top toolbar — sidebar / export / settings only.
            HStack(spacing: 12) {
                Button {
                    nav.openSidebar()
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(DSType.bodySM)
                        .foregroundColor(DSColor.inkMuted)
                        .frame(width: 36, height: 36)
                        .glassSurface(in: Circle())
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("a11y.nav.open", comment: "Sidebar open button"))
                .accessibilityHint(NSLocalizedString("a11y.nav.open.hint", comment: "Opens the sidebar navigation drawer"))
                .accessibilityIdentifier("sidebar-menu-button")

                Spacer()

                // Compact hero (2026-07-04): once the day has memos the big
                // weekday hero collapses into this single-line serif title in
                // the toolbar center — content owns the fold, the date stays
                // one glance away. Keeps the hero's affordances (tap →
                // scroll-to-top, context menu → export / copy).
                if hasMemos {
                    compactHeroTitle
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }

                Spacer()

                // R4 (#793 comp 4.png): the comp's top bar is exactly two
                // chips — ☰ left, ⚙ right. The export-as-markdown button
                // used to appear in the middle once the day had memos, but
                // that made the toolbar drift between 2-chip and 3-chip
                // layouts as the day filled in. The export action stays
                // available via long-pressing the hero title (gesture wired
                // below); the visible chip is removed so the toolbar
                // rhythm is invariant.
                if false {
                    Button {
                        let content = MarkdownExportService.buildExportContent(
                            memos: viewModel.memos, date: Date(),
                            summary: viewModel.dailyPageSummary
                        )
                        let dateString = MarkdownExportService.exportDateString(for: Date())
                        do {
                            let url = try MarkdownExportService.writeExportFile(
                                content: content, dateString: dateString
                            )
                            exportFileURL = url
                            showExportSheet = true
                            Haptics.tapConfirm()
                            bannerCenter.show(AppBannerModel(
                                kind: .success,
                                title: NSLocalizedString("export.success.title", comment: ""),
                                autoDismiss: true
                            ))
                        } catch {
                            Haptics.warn()
                            bannerCenter.show(AppBannerModel(
                                kind: .error,
                                title: NSLocalizedString("export.error.title", comment: ""),
                                autoDismiss: true
                            ))
                            DayPageLogger.shared.error("TodayView: export failed: \(error)")
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(DSType.bodySM)
                            .foregroundColor(DSColor.inkMuted)
                            .frame(width: 36, height: 36)
                            .glassSurface(in: Circle())
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(NSLocalizedString("export.action.title", comment: ""))
                    .accessibilityHint(NSLocalizedString("export.action.hint", comment: ""))
                    .accessibilityIdentifier("export-markdown-button")
                    .onLongPressGesture(minimumDuration: 0.5) {
                        let content = MarkdownExportService.buildExportContent(
                            memos: viewModel.memos, date: Date(),
                            summary: viewModel.dailyPageSummary
                        )
                        UIPasteboard.general.string = content
                        Haptics.medium()
                        Haptics.success()
                        bannerCenter.show(AppBannerModel(
                            kind: .info,
                            title: NSLocalizedString("export.copied.title", comment: ""),
                            autoDismiss: true
                        ))
                    }
                }

                Button {
                    Haptics.soft()
                    if !reduceMotion {
                        withAnimation(Motion.spring) { settingsGearRotation += 90 }
                    }
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(DSType.bodySM)
                        .foregroundColor(DSColor.inkMuted)
                        .frame(width: 36, height: 36)
                        .glassSurface(in: Circle())
                        .clipShape(Circle())
                        .rotationEffect(.degrees(settingsGearRotation))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("a11y.settings", comment: "Settings button"))
                .accessibilityHint(NSLocalizedString("a11y.settings.hint", comment: "Opens app settings"))
                .accessibilityIdentifier("settings-gear-button")
            }

            // MARK: Hero title — weekday + subline, CENTERED.
            // R3 (#793 comp 4.png): the comp puts the hero between the
            // hamburger and the gear, not left-aligned under them. The
            // toolbar row above carries ☰ · ⚙; the hero sits below
            // centered so the eye lands on the date before the dock.
            // Chinese "星期X" at 28pt keeps the calm museum scale; the
            // subline (30 JUN · 深夜) is a small caps caption.
            //
            // 2026-07-04: the big hero now shows ONLY while the day is empty.
            // Once the first memo lands it collapses into `compactHeroTitle`
            // (toolbar center) so the timeline gains ~70pt above the fold.
            if !hasMemos {
            Button {
                hasNewContentAboveFold = false
                Haptics.soft()
                withAnimation(reduceMotion ? nil : Motion.spring) {
                    timelineScrollProxy?.scrollTo("timelineTop", anchor: .top)
                }
            } label: {
                VStack(alignment: .center, spacing: 6) {
                    Text(weekdayName(currentTime))
                        .font(DSFonts.serif(size: 26, weight: .regular))
                        .foregroundColor(DSColor.inkPrimary)
                        .lineLimit(1)
                        .dynamicTypeSize(.xSmall ... .accessibility2)
                        .minimumScaleFactor(0.6)
                    headerSublineView(currentTime)
                        .accessibilityLabel(headerSublineAccessibilityLabel(currentTime))
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("today.header.scroll_to_top", comment: "Scroll to top of timeline"))
            .accessibilityIdentifier("today-hero-title")
            .onLongPressGesture(minimumDuration: 1.5) {
                HapticFeedback.medium()
                if let entry = OnThisDayScheduler.shared.forceRefresh() {
                    viewModel.onThisDayEntry = entry
                } else {
                    HapticFeedback.warning()
                }
            }
            // 2026-07-04: the export context menu used to live here, gated on
            // !memos.isEmpty — but the big hero itself now renders only on
            // EMPTY days, so that menu could never appear. It moved to
            // `compactHeroTitle` (the memo-day surface) as `exportMenuItems`.
            .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 16)
        // Collapse/expand between the big hero (empty day) and the compact
        // toolbar title (memo day) with the shared panel spring so the first
        // memo's arrival reads as one deliberate motion, not a layout pop.
        .animation(reduceMotion ? nil : Motion.spring, value: hasMemos)
        .onReceive(headerTimer) { date in
            currentTime = date
        }
        .onChange(of: viewModel.todayWordCount) { newCount in
            let newIndex = wordMilestones.filter { $0 <= newCount }.count
            if newIndex > lastWordMilestoneIndex {
                // Crossed a new milestone — escalating haptic + amber glow
                let milestoneNumber = newIndex  // 1, 2, or 3
                Haptics.rigid(intensity: 0.3 + 0.25 * CGFloat(milestoneNumber))
                if !reduceMotion {
                    wordMilestoneGlow = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        wordMilestoneGlow = false
                    }
                }
                let milestone = wordMilestones[newIndex - 1]
                UIAccessibility.post(
                    notification: .announcement,
                    argument: String(format: NSLocalizedString("today.wordmilestone.announcement", comment: ""), milestone)
                )
            }
            lastWordMilestoneIndex = newIndex
        }
        .frame(maxWidth: .infinity)
        // US-005: frosted glass + separator fade in behind the header once the
        // timeline scrolls > 8pt. Drawn as a background so it never affects the
        // header's intrinsic height (the cause of the old overlap bug). (#590)
        .background(alignment: .bottom) {
            ZStack(alignment: .bottom) {
                if isScrolled {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Rectangle()
                                .fill(DSColor.bgWarm.opacity(0.78))
                        )
                    Rectangle()
                        .fill(DSColor.borderSubtle)
                        .frame(height: 0.5)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isScrolled)
        }
    }

    /// Single-line hero shown once the day has memos: "星期六 · 7月4日",
    /// centered in the toolbar row between ☰ and ⚙. Replaces the 70pt big
    /// hero so captured content owns the fold while the date stays one
    /// glance away. Carries the hero's affordances forward: tap scrolls the
    /// timeline to top; long-press context menu exposes export / copy.
    private var compactHeroTitle: some View {
        Button {
            hasNewContentAboveFold = false
            Haptics.soft()
            withAnimation(reduceMotion ? nil : Motion.spring) {
                timelineScrollProxy?.scrollTo("timelineTop", anchor: .top)
            }
        } label: {
            Text("\(weekdayName(currentTime)) · \(Self.headerDateFmt.string(from: currentTime))")
                .font(DSFonts.serif(size: 15, weight: .regular))
                .foregroundColor(DSColor.inkPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(height: 36)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString("today.header.scroll_to_top", comment: "Scroll to top of timeline"))
        .accessibilityIdentifier("today-hero-title-compact")
        .contextMenu { exportMenuItems }
    }

    /// Export / copy actions for the day's memos — formerly the big hero's
    /// context menu. Lives on `compactHeroTitle` because that surface only
    /// renders when memos exist (the old `!memos.isEmpty` gate is structural
    /// now, not conditional).
    @ViewBuilder
    private var exportMenuItems: some View {
        Button {
            let content = MarkdownExportService.buildExportContent(
                memos: viewModel.memos, date: Date(),
                summary: viewModel.dailyPageSummary
            )
            let dateString = MarkdownExportService.exportDateString(for: Date())
            do {
                let url = try MarkdownExportService.writeExportFile(
                    content: content, dateString: dateString
                )
                exportFileURL = url
                showExportSheet = true
                Haptics.tapConfirm()
            } catch {
                Haptics.warn()
                DayPageLogger.shared.error("TodayView: export failed: \(error)")
            }
        } label: {
            Label(NSLocalizedString("export.action.title", comment: ""),
                  systemImage: "square.and.arrow.up")
        }
        Button {
            let content = MarkdownExportService.buildExportContent(
                memos: viewModel.memos, date: Date(),
                summary: viewModel.dailyPageSummary
            )
            UIPasteboard.general.string = content
            Haptics.success()
            bannerCenter.show(AppBannerModel(
                kind: .info,
                title: NSLocalizedString("export.copied.title", comment: ""),
                autoDismiss: true
            ))
        } label: {
            Label(NSLocalizedString("export.copied.title", comment: ""),
                  systemImage: "doc.on.doc")
        }
    }

    /// Scrollable timeline: daily page card, skeleton, memo cards, history supplement.
    @ViewBuilder
    private var timelineSection: some View {
        ScrollViewReader { proxy in
        ScrollView {
            // US-005: Offset tracker — reads the scroll position relative to the
            // named coordinate space so the header bar can go glassy on scroll.
            GeometryReader { geo in
                Color.clear
                    .preference(
                        key: ScrollOffsetPreferenceKey.self,
                        value: geo.frame(in: .named("todayScroll")).minY
                    )
            }
            .frame(height: 0)

            LazyVStack(spacing: 10) {
                // Invisible anchor: scrollTo("timelineTop") brings the list to the very top.
                Color.clear.frame(height: 0).id("timelineTop")

                // Museum-aesthetic "AI · 今日一句" — restrained one-liner pinned
                // at the very top once the day has a compiled summary.
                if let summary = viewModel.dailyPageSummary,
                   !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    AISummaryCard(summary: summary, onTap: { Haptics.tapConfirm(); showDailyPage = true })
                        .padding(.horizontal, 20)
                        .padding(.bottom, 4)
                        .scaleEffect(summaryHintPulse ? 1.03 : 1)
                        .shadow(color: DSColor.accentAmber.opacity(summaryHintPulse ? 0.4 : 0), radius: summaryHintPulse ? 10 : 0)
                        .animation(reduceMotion ? nil : Motion.spring, value: summaryHintPulse)
                        .transition(.opacity)
                        .onAppear {
                            guard !UserDefaults.standard.bool(forKey: AppSettings.Keys.summaryCopyHintShown),
                                  !reduceMotion else { return }
                            UserDefaults.standard.set(true, forKey: AppSettings.Keys.summaryCopyHintShown)
                            Task { @MainActor in
                                try? await Task.sleep(for: .seconds(0.8))
                                Haptics.soft()
                                withAnimation(Motion.spring) { summaryHintPulse = true }
                                try? await Task.sleep(for: .seconds(0.5))
                                withAnimation(Motion.spring) { summaryHintPulse = false }
                            }
                        }
                        .onLongPressGesture(minimumDuration: 0.4) {
                            UIPasteboard.general.string = summary
                            Haptics.tapConfirm()
                            bannerCenter.show(AppBannerModel(
                                kind: .info,
                                title: NSLocalizedString("today.summary.copied", comment: ""),
                                autoDismiss: true
                            ))
                        }
                        .accessibilityAction(named: Text("Copy summary")) {
                            UIPasteboard.general.string = summary
                            Haptics.tapConfirm()
                            bannerCenter.show(AppBannerModel(
                                kind: .info,
                                title: NSLocalizedString("today.summary.copied", comment: ""),
                                autoDismiss: true
                            ))
                        }
                }

                if viewModel.isDailyPageCompiled {
                    swipeableDailyPageCard
                        .padding(.horizontal, 20)
                        .shadow(
                            color: DSColor.accentAmber.opacity(compileRevealGlow ? 0.5 : 0),
                            radius: compileRevealGlow ? 20 : 0
                        )
                        .scaleEffect(reduceMotion ? 1 : (compileRevealGlow ? 1.0 : 0.97))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.7), value: compileRevealGlow)
                        .transition(.scale(scale: 0.95).combined(with: .opacity))
                        .animation(reduceMotion ? nil : Motion.spring, value: viewModel.isDailyPageCompiled)
                }

                if viewModel.loadState == .loading && viewModel.memos.isEmpty {
                    MemoListSkeleton(count: skeletonCardCount)
                        .padding(.horizontal, 20)
                        .transition(.opacity)
                }

                if viewModel.memos.isEmpty && viewModel.loadState == .ready {
                    let hasOnboarded = UserDefaults.standard.bool(forKey: AppSettings.Keys.hasOnboarded)
                    if !hasOnboarded {
                        EmptyStateView.todayBlank(ctaAction: { orbFocusToggle.toggle() }, subtitleOverride: todayEmptySubtitle(currentTime))
                            .padding(.top, 48)
                            .padding(.horizontal, 20)
                    } else {
                        fallbackContentView
                            .padding(.top, 24)
                    }
                } else {
                    ForEach(Array(viewModel.memos.enumerated()), id: \.element.id) { idx, memo in
                        TimelineRow(
                            memo: memo,
                            isLast: idx == viewModel.memos.count - 1,
                            onDelete: {
                                undoText = nil
                                undoTask?.cancel()
                                viewModel.deleteMemo(memo)
                            },
                            onPin: {
                                if memo.pinnedAt != nil {
                                    viewModel.unpinMemo(memo)
                                } else {
                                    viewModel.pinMemo(memo)
                                }
                            },
                            onRetranscribe: { m, att in viewModel.retranscribe(memo: m, attachment: att) },
                            onShare: {
                                sharePayload = SharePayload.auto(from: memo)
                            },
                            onShareAsQuote: {
                                let df = DateFormatter()
                                df.dateFormat = "yyyy-MM-dd"
                                var attrib = df.string(from: memo.created)
                                if let loc = memo.location?.name, !loc.isEmpty {
                                    attrib += " · " + loc
                                }
                                sharePayload = .quote(QuoteSnapshot(
                                    text: memo.body,
                                    attribution: attrib
                                ))
                            },
                            onEnterSelectionMode: {
                                Haptics.tapConfirm()
                                if !reduceMotion { Haptics.soft() }
                                selectedMemoIds = [memo.id]
                            },
                            isSelectionMode: isInSelectionMode,
                            isSelected: selectedMemoIds?.contains(memo.id) ?? false,
                            onToggleSelection: {
                                guard var set = selectedMemoIds else { return }
                                if set.contains(memo.id) {
                                    set.remove(memo.id)
                                } else if set.count < CollageSnapshot.maxItems {
                                    set.insert(memo.id)
                                } else {
                                    Haptics.warn()
                                    return
                                }
                                selectedMemoIds = set
                                if !reduceMotion {
                                    if set.count == 2 {
                                        // Crossed shareable threshold — signal 'now you can share'
                                        Haptics.rigid(intensity: 0.4)
                                    } else {
                                        Haptics.soft()
                                    }
                                }
                            },
                            onOpen: {
                                // Same confirm tick the timeline rows play on
                                // open, so tap-into-detail feels identical
                                // across today's cards and historical rows.
                                Haptics.tapConfirm()
                                openedMemoID = memo.id
                            }
                        )
                        .offset(x: idx == 0 ? memoCardHintOffset : 0)
                        // iOS 18+ hero zoom: this card is the source frame the
                        // detail page grows out of (and shrinks back into).
                        .modifier(CardZoomSource(
                            id: memo.id, namespace: detailZoomNamespace
                        ))
                        .onAppear {
                            guard idx == 0,
                                  !UserDefaults.standard.bool(forKey: AppSettings.Keys.memoSwipeHintShown),
                                  !reduceMotion,
                                  !isInSelectionMode else { return }
                            UserDefaults.standard.set(true, forKey: AppSettings.Keys.memoSwipeHintShown)
                            Task { @MainActor in
                                try? await Task.sleep(for: .seconds(0.6))
                                withAnimation(Motion.spring) { memoCardHintOffset = -28 }
                                Haptics.soft()
                                try? await Task.sleep(for: .seconds(0.45))
                                withAnimation(Motion.spring) { memoCardHintOffset = 28 }
                                try? await Task.sleep(for: .seconds(0.35))
                                withAnimation(Motion.spring) { memoCardHintOffset = 0 }
                            }
                        }
                        .padding(.horizontal, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }

                // R12: "再记 N 条解锁今日成稿" 卡片已移除。编译不再有 3 条门槛——
                // 每天 0 点自动编译前一天，手动编译按钮在 composeSection 中始终可用。

                historySupplement

                if viewModel.loadState == .loading && !viewModel.memos.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView().tint(DSColor.inkSubtle)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }

                if let error = viewModel.errorMessage {
                    Text(error)
                        .bodySMStyle()
                        .foregroundColor(DSColor.error)
                        .padding(.horizontal, 20)
                }

                // Reserve room for the floating Undo pill (bottom: 96) +
                // the input bar above it so the last timeline card never sits
                // beneath chrome.
                Spacer(minLength: 140)
            }
            .padding(.top, 12)
            .shadow(
                color: DSColor.accentAmber.opacity(refreshGlow ? 0.45 : 0),
                radius: refreshGlow ? 18 : 0
            )
            .animation(reduceMotion ? nil : .easeOut(duration: 0.6), value: refreshGlow)
        }
        .refreshable {
            await viewModel.refresh()
            Haptics.success()
            if !reduceMotion {
                refreshGlow = true
                Task {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    refreshGlow = false
                }
            }
        }
        .overlay(
            LinearGradient(
                colors: [Color.clear, DSColor.bgWarm],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 40)
            .allowsHitTesting(false),
            alignment: .bottom
        )
        .coordinateSpace(name: "todayScroll")
        .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
            // Store the raw value only — DO NOT read this from any body path;
            // see the property-doc for the perf rationale.
            timelineScrollOffset = value
            // Derive threshold-bucketed state so the surrounding view body
            // invalidates O(1) times per scroll instead of O(60Hz).
            let scrolled = value < -8
            if scrolled != isTimelineScrolled { isTimelineScrolled = scrolled }
            let showTop = value < -240
            if showTop != showScrollToTopButton { showScrollToTopButton = showTop }
            // Quantize the ring progress (0…20) — floor(clamp(-value - 240, 0, 1200) / 60).
            let clamped = max(0, min(1200, -value - 240))
            let bucket = Int(clamped / 60)
            if bucket != scrollProgressBucket { scrollProgressBucket = bucket }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { timelineScrollProxy = proxy }
        } // end ScrollViewReader
    }

    /// Compose area: compile button + input bar.
    ///
    /// 编译不再有"记满 3 条才解锁"的门槛——每天用户时区 0 点会自动编译前一天
    /// （BackgroundCompilationService），手动编译入口在此始终可用：只要当天有
    /// memo 且尚未编译，就直接显示编译按钮，无论几条。
    @ViewBuilder
    private var composeSection: some View {
        Group {
            // Museum-aesthetic redesign (#793): the persistent "编译今日"
            // CTA used to live here on every day with memos and added a
            // mid-screen amber pill plus a "夜深了…" hint that broke the
            // calm capture surface. With background compilation now
            // running automatically at the user's local 02:00 (and the
            // per-memo "compile" affordance still on the day-summary
            // card), the floating CTA is redundant. We keep this section
            // ONLY as a recovery surface — i.e. when a manual compile or
            // background pass produced an error the user has to retry.
            // R4 (#793 comp 4.png): the "配置 AI 引擎" / "为今天画上句号"
            // capsule duplicated the role of the calmer header status row
            // ("钥匙就绪后…") when a key was missing. We now hide the entire
            // footer once the key is absent — the header row already carries
            // the call to Settings, and the footer reappears only for real
            // recovery cases (mid-compile or a non-key error the user must
            // see). Keeps the bottom area clean so the dock keeps its
            // floating-island read against the warm canvas.
            let aiKeyMissing = Secrets.resolvedDeepSeekApiKey.isEmpty
            if !viewModel.isDailyPageCompiled
                && !viewModel.memos.isEmpty
                && (viewModel.isCompiling || viewModel.submitError != nil)
                && !aiKeyMissing {
                HStack {
                    Spacer()
                    CompileFooterButton(
                        memoCount: viewModel.memos.count,
                        isCompiling: aiKeyMissing ? false : viewModel.isCompiling,
                        isVisible: true,
                        stage: compilationService.stage,
                        errorMessage: aiKeyMissing ? nil : viewModel.submitError,
                        onTap: {
                            if aiKeyMissing {
                                showSettings = true
                            } else {
                                viewModel.compile()
                            }
                        },
                        onRetry: {
                            if aiKeyMissing {
                                showSettings = true
                            } else {
                                viewModel.compile()
                            }
                        },
                        aiKeyMissing: aiKeyMissing
                    )
                    .shadow(
                        color: DSColor.accentAmber.opacity(unlockGlow ? 0.5 : 0),
                        radius: unlockGlow ? 18 : 0
                    )
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.6), value: unlockGlow)
                    Spacer()
                }
                .padding(.bottom, 4)
            }
        }
        .animation(Motion.spring, value: viewModel.memos.count)
        .onChange(of: viewModel.memos.count) { count in
            if count >= 3 && !viewModel.isDailyPageCompiled && !didCelebrateUnlock {
                didCelebrateUnlock = true
                Haptics.success()
                if !reduceMotion {
                    unlockGlow = true
                    Task {
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        unlockGlow = false
                    }
                }
            } else if (1...2).contains(count) && !viewModel.isDailyPageCompiled && count > lastMemoCount {
                // Escalating tick on 1st memo (intensity 0.55) and 2nd (intensity 0.80)
                Haptics.rigid(intensity: 0.3 + 0.25 * Double(count))
            } else if count < 3 {
                didCelebrateUnlock = false
            }
            // Celebrate streak milestone when today's first memo is added.
            if lastMemoCount == 0 && count == 1 {
                Task { @MainActor in
                    await sidebarVM.refreshRecentDaysAsync()
                    celebrateStreakIfNeeded()
                }
            }
            // Scroll to top on additions only, not deletions.
            // When the user is scrolled far into history (past the button threshold),
            // badge the scroll-to-top button instead of jumping them away from context.
            if count > lastMemoCount {
                if showScrollToTopButton {
                    hasNewContentAboveFold = true
                    Haptics.soft()
                } else if let proxy = timelineScrollProxy {
                    withAnimation(reduceMotion ? nil : Motion.spring) {
                        proxy.scrollTo("timelineTop", anchor: .top)
                    }
                }
            }
            lastMemoCount = count
            if viewModel.loadState == .ready && count > 0 {
                skeletonCardCount = count
            }
        }
        .onChange(of: viewModel.isDailyPageCompiled) { compiled in
            if compiled && !didCelebrateCompile {
                didCelebrateCompile = true
                Haptics.success()
                if !reduceMotion {
                    compileRevealGlow = true
                    Task {
                        try? await Task.sleep(nanoseconds: 700_000_000)
                        compileRevealGlow = false
                    }
                }
            } else if !compiled {
                didCelebrateCompile = false
            }
        }
        .onChange(of: viewModel.todayWordCount) { count in
            if viewModel.memos.isEmpty {
                lastWordMilestone = 0
                return
            }
            let milestones = [100, 250, 500]
            let crossed = milestones.filter { count >= $0 }.max() ?? 0
            guard crossed > lastWordMilestone else { return }
            lastWordMilestone = crossed
            Haptics.tapConfirm()
            let announcement = String(format: NSLocalizedString("today.milestone.words", comment: ""), crossed)
            UIAccessibility.post(notification: .announcement, argument: announcement)
            withAnimation(reduceMotion ? nil : Motion.rise) {
                wordMilestoneToast = crossed
            }
            milestoneToastTask?.cancel()
            milestoneToastTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(2.5))
                withAnimation(reduceMotion ? nil : Motion.rise) {
                    wordMilestoneToast = nil
                }
            }
        }
        .onChange(of: viewModel.memos.isEmpty) { isEmpty in
            if isEmpty { lastWordMilestone = 0 }
        }

        inputBarV4
            // While WriteSheet is presented (overlay layer, not a true UISheet),
            // hide the dock beneath. Not just disable hit-testing — leaving the
            // dock visible looks like "two input bars overlapping" (one in the
            // sheet, one behind the scrim) which users reported as jarring.
            // Fading + shifting it off-screen is cheaper than mounting/dismounting.
            .opacity(showWriteSheet ? 0 : 1)
            .offset(y: showWriteSheet ? 40 : 0)
            .animation(reduceMotion ? nil : Motion.rise, value: showWriteSheet)
            .allowsHitTesting(!showWriteSheet)
    }

    // MARK: - Helpers

    // MARK: - Streak Milestone Celebration

    private static let streakMilestones: [Int] = [3, 7, 14, 30, 100, 365]

    private func milestoneEncouragement(for n: Int) -> String {
        switch n {
        case 3:   return NSLocalizedString("today.streak.milestone.subtitle.3",   comment: "")
        case 7:   return NSLocalizedString("today.streak.milestone.subtitle.7",   comment: "")
        case 14:  return NSLocalizedString("today.streak.milestone.subtitle.14",  comment: "")
        case 30:  return NSLocalizedString("today.streak.milestone.subtitle.30",  comment: "")
        case 100: return NSLocalizedString("today.streak.milestone.subtitle.100", comment: "")
        case 365: return NSLocalizedString("today.streak.milestone.subtitle.365", comment: "")
        default:  return NSLocalizedString("today.streak.milestone.subtitle.365", comment: "")
        }
    }

    private func shownMilestones() -> Set<Int> {
        let raw = UserDefaults.standard.string(forKey: AppSettings.Keys.streakMilestonesShown) ?? ""
        return Set(raw.split(separator: ",").compactMap { Int($0) })
    }

    private func markMilestoneShown(_ n: Int) {
        var shown = shownMilestones()
        shown.insert(n)
        UserDefaults.standard.set(shown.map(String.init).joined(separator: ","),
                                  forKey: AppSettings.Keys.streakMilestonesShown)
    }

    private func celebrateStreakIfNeeded() {
        let streak = sidebarVM.currentStreak
        guard let milestone = Self.streakMilestones.first(where: { $0 == streak }) else { return }
        guard !shownMilestones().contains(milestone) else { return }

        markMilestoneShown(milestone)
        Haptics.success()
        if !reduceMotion {
            orbCapturePulse.toggle()
            refreshGlow = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                refreshGlow = false
            }
        }
        let title = String(format: NSLocalizedString("today.streak.milestone.title", comment: ""), milestone)
        bannerCenter.show(AppBannerModel(
            kind: .info,
            title: title,
            subtitle: milestoneEncouragement(for: milestone),
            autoDismiss: true
        ))
    }

    // US-009: Show undo pill for 5 seconds after submitting a memo.
    private func showUndoPill(for text: String) {
        guard !text.isEmpty else { return }
        // Clear delete undo pill so the two never stack
        viewModel.lastDeletedMemo = nil
        undoTask?.cancel()
        undoText = text
        undoTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            undoText = nil
        }
    }

    private func announceMemoSaved() {
        Haptics.success()
        UIAccessibility.post(notification: .announcement,
                             argument: NSLocalizedString("today.memo.saved", comment: ""))
    }

    // US-006: Clear draft when it's more than 30 days old.
    private func clearDraftIfExpired() {
        guard !draftText.isEmpty, draftDate > 0 else { return }
        let age = Date().timeIntervalSince1970 - draftDate
        if age > 30 * 24 * 3600 {
            draftText = ""
            draftDate = 0
            // R4-B2: keep the UserDefaults backup mirror aligned with the
            // SceneStorage truth — otherwise a stale 31-day-old draft would
            // be resurrected by .onAppear on the next cold launch.
            UserDefaults.standard.removeObject(forKey: draftBackupKey)
        }
    }

    private func showDraftRestoredBannerIfNeeded() {
        guard !draftRestoredBannerShown, !draftText.isEmpty else { return }
        draftRestoredBannerShown = true
        bannerCenter.show(AppBannerModel(
            kind: .info,
            title: "恢复了未发送的草稿",
            autoDismiss: true
        ))
    }

    private func updateVoiceQueueBanner(count: Int) {
        if count > 0 {
            bannerCenter.show(AppBannerModel(
                kind: .info,
                title: "你有 \(count) 条语音待转写",
                autoDismiss: false
            ))
        } else if bannerCenter.currentBanner?.title.contains("语音待转写") == true {
            bannerCenter.dismiss()
        }
    }

    // Weekday "Thursday / 星期四" — follows the user's current locale so
    // Chinese users see 星期四 and English users see Thursday on the hero.
    private static let weekdayFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.timeZone = TimeZone.current
        f.setLocalizedDateFormatFromTemplate("EEEE")
        return f
    }()

    // "MAY 28" / "5月28日" subline — also locale-aware.
    private static let headerDateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.timeZone = TimeZone.current
        f.setLocalizedDateFormatFromTemplate("MMM d")
        return f
    }()

    private static let headerTimeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    private func weekdayName(_ date: Date) -> String {
        Self.weekdayFmt.string(from: date)
    }

    private func headerSubline(_ date: Date) -> String {
        let count = viewModel.memos.count
        let dateStr = Self.headerDateFmt.string(from: date)

        // Notes segment (empty-state shows time instead of count).
        var parts: [String]
        if count == 0 {
            parts = [dateStr, Self.headerTimeFmt.string(from: date)]
        } else {
            let notesKey = count == 1 ? "today.subline.notes.one" : "today.subline.notes.other"
            let notesStr = String(format: NSLocalizedString(notesKey, comment: ""), count)
            parts = [dateStr, notesStr]
            let words = viewModel.todayWordCount
            if words > 0 {
                let wordsKey = words == 1 ? "today.subline.words.one" : "today.subline.words.other"
                parts.append(String(format: NSLocalizedString(wordsKey, comment: ""), words))
            }
        }

        // Museum-aesthetic subline: append today's weather + place when known.
        // Sourced from existing memos — no extra network/location fetch (M1 is UI-only).
        // e.g. "MAY 28 · 2 NOTES · 340 WORDS · 28° · VIENTIANE"
        if let weather = todayWeatherShort() {
            parts.append(weather)
        }
        if let place = todayPlaceShort() {
            parts.append(place)
        }
        parts.append(todayTimeZoneShort())
        return parts.joined(separator: "  ·  ")
    }

    /// Renders the header subline as a single concise mono row.
    ///
    /// R4 (#793 comp 4.png): the previous implementation appended every
    /// available metadatum (date · notes · words · weather · place · TZ),
    /// which on a writing-active day stretched the subline across the whole
    /// screen and broke the calm rhythm the comp establishes. The comp shows
    /// just "30 JUN · 深夜" — two beats: when and what feels like.
    ///
    /// New surface = "date · timeOfDay". Counts/weather/place live one tap
    /// away in the header long-press, or implicitly in the timeline cards.
    /// The word-count milestone glow becomes a one-shot ripple on the
    /// hero scale handled elsewhere, so the subline stays quiet on writes.
    @ViewBuilder
    private func headerSublineView(_ date: Date) -> some View {
        let dateStr = Self.headerDateFmt.string(from: date)
        let timeOfDay = headerTimeOfDay(date)
        let separator = "  ·  "
        Text((dateStr + separator + timeOfDay).uppercased())
            .font(DSType.mono10)
            .foregroundColor(DSColor.inkSubtle)
            .tracking(1.0)
            .dynamicTypeSize(.xSmall ... .accessibility5)
            .minimumScaleFactor(0.75)
    }

    /// Maps an hour to one of four poetic time-of-day buckets used by the
    /// header subline ("黎明 / 上午 / 下午 / 深夜").
    private func headerTimeOfDay(_ date: Date) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        let key: String
        switch hour {
        case 5..<11:  key = "today.subline.time.morning"
        case 11..<17: key = "today.subline.time.afternoon"
        case 17..<22: key = "today.subline.time.evening"
        default:      key = "today.subline.time.night"
        }
        return NSLocalizedString(key, comment: "Header subline time-of-day bucket")
    }

    /// Comma-separated version of the header subline for VoiceOver.
    /// e.g. "May 28, 2 notes, 340 words, 28°, Vientiane"
    private func headerSublineAccessibilityLabel(_ date: Date) -> String {
        let count = viewModel.memos.count
        let dateStr = Self.headerDateFmt.string(from: date)
        var parts: [String]
        if count == 0 {
            parts = [dateStr, Self.headerTimeFmt.string(from: date)]
        } else {
            let notesKey = count == 1 ? "today.subline.notes.one" : "today.subline.notes.other"
            let notesStr = String(format: NSLocalizedString(notesKey, comment: ""), count)
            parts = [dateStr, notesStr]
            let words = viewModel.todayWordCount
            if words > 0 {
                let wordsKey = words == 1 ? "today.subline.words.one" : "today.subline.words.other"
                parts.append(String(format: NSLocalizedString(wordsKey, comment: ""), words))
            }
        }
        if let weather = todayWeatherAccessibility() { parts.append(weather) }
        if let place = todayPlaceShort() { parts.append(place) }
        parts.append(todayTimeZoneShort())
        return parts.joined(separator: ", ")
    }

    /// Condition glyphs emitted by WeatherService.glyph(forConditionCode:icon:).
    private static let conditionGlyphs: [String] = ["⛈", "🌦", "🌧", "❄️", "🌫", "🌙", "☀️", "☁️", "🌤"]

    /// Maps a condition glyph to a VoiceOver-friendly word.
    private static let glyphAccessibilityLabel: [String: String] = [
        "☀️": NSLocalizedString("weather.glyph.sunny",   comment: ""),
        "☁️": NSLocalizedString("weather.glyph.cloudy",  comment: ""),
        "🌧": NSLocalizedString("weather.glyph.rainy",   comment: ""),
        "❄️": NSLocalizedString("weather.glyph.snowy",   comment: ""),
        "⛈": NSLocalizedString("weather.glyph.stormy",  comment: ""),
        "🌦": NSLocalizedString("weather.glyph.showery", comment: ""),
        "🌫": NSLocalizedString("weather.glyph.foggy",   comment: ""),
        "🌙": NSLocalizedString("weather.glyph.night",   comment: ""),
        "🌤": NSLocalizedString("weather.glyph.partlycloudy", comment: ""),
    ]

    /// Today's weather, taken from the most recent memo that carries a weather string.
    /// Returns "<glyph> <temp>" (e.g. "☀️ 28°") when a condition glyph is present,
    /// or just "<temp>" when none is found. Returns nil when no weather is available.
    private func todayWeatherShort() -> String? {
        for memo in viewModel.memos {  // memos is already newest-first
            if let w = memo.weather?.trimmingCharacters(in: .whitespaces), !w.isEmpty {
                // Detect whether the string leads with a known condition glyph.
                let foundGlyph = Self.conditionGlyphs.first(where: { w.hasPrefix($0) })
                // Strip any leading glyph + thin-space before extracting the temperature.
                let withoutGlyph = foundGlyph.map { w.dropFirst($0.count).trimmingCharacters(in: .whitespaces) } ?? w
                // Keep only the first token (before "·" or ",") — the temperature.
                let temp = withoutGlyph.split(omittingEmptySubsequences: true,
                                              whereSeparator: { $0 == "·" || $0 == "," })
                                       .first
                                       .map { $0.trimmingCharacters(in: .whitespaces) }
                                       ?? withoutGlyph
                guard !temp.isEmpty else { continue }
                if let glyph = foundGlyph {
                    return "\(glyph) \(temp)"
                }
                return temp
            }
        }
        return nil
    }

    /// Like `todayWeatherShort()` but substitutes glyphs with spoken words for VoiceOver.
    private func todayWeatherAccessibility() -> String? {
        guard let short = todayWeatherShort() else { return nil }
        for (glyph, label) in Self.glyphAccessibilityLabel {
            if short.hasPrefix(glyph) {
                return short.replacingOccurrences(of: glyph, with: label).trimmingCharacters(in: .whitespaces)
            }
        }
        return short
    }

    /// Today's place name, taken from the most recent memo carrying a location.
    private func todayPlaceShort() -> String? {
        for memo in viewModel.memos {  // memos is already newest-first
            if let name = memo.location?.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
                return name
            }
        }
        return nil
    }

    private func todayTimeZoneShort() -> String {
        TimeZoneBadge.gmtOffset(for: .current, at: currentTime)
    }

    // MARK: - Timeline row actions

    /// Share a timeline day via the system share sheet. The payload is the
    /// compiled summary if present, otherwise a placeholder pointing at the
    /// day's date — never empty, so the share sheet has something to display.
    private func shareTimelineDay(_ entry: TimelineDayEntry) {
        let text: String
        if let summary = entry.summary, !summary.isEmpty {
            text = "\(entry.dateString)\n\n\(summary)"
        } else {
            text = "\(entry.dateString)\n\n\(entry.memoCount) memos"
        }
        timelineShareText = TimelineShareText(text: text)
    }

    /// Permanently delete a timeline day: removes the raw file, the compiled
    /// daily page, and drops the pin if any. Notifies TimelineIndex via the
    /// `.rawStorageDidWrite` notification path so the timeline re-renders.
    private func deleteTimelineDay(_ entry: TimelineDayEntry) {
        let dateString = entry.dateString
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone.current
        guard let date = fmt.date(from: dateString) else { return }

        Task.detached(priority: .userInitiated) {
            try? RawStorage.rewrite([], for: date)        // posts rawStorageDidWrite
            let dailyURL = VaultInitializer.vaultURL
                .appendingPathComponent("wiki/daily/\(dateString).md")
            try? FileManager.default.removeItem(at: dailyURL)
            await MainActor.run {
                TimelinePinService.shared.unpin(dateString)
                Haptics.warn()
            }
        }
    }

    // Issue #814: Weekly Recap preview helpers removed — Archive's entry
    // card (ArchiveView.weeklyRecapEntryCard) is the single This Week surface.
}

// MARK: - OnThisDayNavTarget

private struct OnThisDayNavTarget: Identifiable {
    let dateString: String
    var id: String { dateString }
}

// MARK: - TimelineShareText

/// Identifiable wrapper around a plain-text share payload so it can drive
/// `.sheet(item:)`. Each tap on "Share" gets a fresh UUID so consecutive
/// shares of the same day still re-trigger the sheet.
struct TimelineShareText: Identifiable {
    let id = UUID()
    let text: String
}

// MARK: - CompilationFailedBanner

/// Red banner shown when background compilation failed after all retries.
/// Delegates to the shared DSBanner so the visual language matches every
/// other banner in the app (syncBanner, LocationDraftCard header, etc.).
struct CompilationFailedBanner: View {
    let message: String
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        DSBanner(
            kind: .error,
            title: message,
            primaryAction: (label: "重试", action: onRetry),
            onDismiss: onDismiss
        )
        .padding(.horizontal, DSSpacing.pageMargin)
        .padding(.bottom, DSSpacing.xs)
    }
}

// MARK: - LocationDraftCard

/// Card shown at the top of Today View listing passively-detected visits pending user action.
struct LocationDraftCard: View {
    let drafts: [VisitDraft]
    let onConfirm: (VisitDraft) -> Void
    let onIgnore: (VisitDraft) -> Void
    let onConfirmAll: () -> Void
    let onIgnoreAll: () -> Void

    var body: some View {
        locationDraftContent
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
    }

    // MARK: - Location Draft Content

    private var locationDraftContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            draftHeader
            Divider().background(DSColor.inkFaint)
            draftRows
        }
        // #771: location-draft panel → glass engine (.panel). The wet-glass
        // top highlight is kept as the bespoke outer shell; the engine supplies
        // the material + perimeter rim.
        .dpGlass(.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(LinearGradient(colors: [DSColor.glassEdge, Color.clear], startPoint: .top, endPoint: .center), lineWidth: 0.6)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Color(hex: "2D1E0A").opacity(0.04), radius: 1, x: 0, y: 1)
        .shadow(color: Color(hex: "2D1E0A").opacity(0.08), radius: 24, x: 0, y: 8)
    }

    // MARK: - Draft Header

    private var draftHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "location.fill")
                .font(DSType.label)
                .foregroundColor(DSColor.amberAccent)
            Text("检测到位置到达")
                .font(DSType.caption)
                .foregroundColor(DSColor.inkPrimary)
            Spacer()
            Button("全部忽略") { onIgnoreAll() }
                .font(DSType.caption)
                .foregroundColor(DSColor.inkMuted)
                .accessibilityLabel("忽略所有位置记录")
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            Button("全部确认") { onConfirmAll() }
                .font(DSType.caption)
                .foregroundColor(DSColor.amberAccent)
                .accessibilityLabel("确认所有位置记录")
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    // MARK: - Draft Rows

    private var draftRows: some View {
        ForEach(Array(drafts.enumerated()), id: \.element.id) { idx, draft in
            VStack(spacing: 0) {
                LocationDraftRow(
                    draft: draft,
                    onConfirm: { onConfirm(draft) },
                    onIgnore: { onIgnore(draft) }
                )
                if idx < drafts.count - 1 {
                    Divider()
                        .background(DSColor.inkFaint)
                        .padding(.leading, 16)
                }
            }
        }
    }
}

// MARK: - LocationDraftRow

private struct LocationDraftRow: View {
    let draft: VisitDraft
    let onConfirm: () -> Void
    let onIgnore: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "mappin.circle.fill")
                .font(DSType.headlineCaps)
                .foregroundColor(DSColor.amberAccent)

            VStack(alignment: .leading, spacing: 2) {
                Text(draft.placeName ?? "未知地点")
                    .font(DSType.caption)
                    .foregroundColor(DSColor.inkPrimary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(formatTime(draft.arrivalDate))
                        .font(DSType.mono10)
                        .foregroundColor(DSColor.inkSubtle)
                        .textCase(.uppercase)
                    if let dur = durationText {
                        Text("·")
                            .font(DSType.mono10)
                            .foregroundColor(DSColor.inkSubtle)
                        Text(dur)
                            .font(DSType.mono10)
                            .foregroundColor(DSColor.inkSubtle)
                    }
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    onIgnore()
                } label: {
                    Image(systemName: "xmark")
                        .font(DSType.label)
                        .foregroundColor(DSColor.inkMuted)
                        .frame(width: 30, height: 30)
                        // #771: ignore-location button → glass engine (.control).
                        .dpGlass(.control, in: Circle())
                        .clipShape(Circle())
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .accessibilityLabel("忽略此位置")

                Button {
                    onConfirm()
                } label: {
                    Image(systemName: "checkmark")
                        .font(DSType.label)
                        .foregroundColor(.white)
                        .frame(width: 30, height: 30)
                        .background(DSColor.amberAccent)
                        .clipShape(Circle())
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .accessibilityLabel("确认此位置")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f.string(from: date)
    }

    private var durationText: String? {
        guard let dep = draft.departureDate else { return "仍在此处" }
        let secs = dep.timeIntervalSince(draft.arrivalDate)
        guard secs > 0 else { return nil }
        let mins = Int(secs / 60)
        if mins < 60 { return "停留 \(mins) 分钟" }
        let h = mins / 60; let m = mins % 60
        return m == 0 ? "停留 \(h) 小时" : "停留 \(h) 小时 \(m) 分钟"
    }
}

// MARK: - CompilationProgressBar

/// Thin progress strip shown at the top of TodayView while AI compilation runs.
struct CompilationProgressBar: View {
    let stage: CompilationStage

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var progress: Double {
        switch stage {
        case .extracting: return 0.25
        case .compiling:  return 0.60
        case .formatting: return 0.85
        case .done:       return 1.00
        }
    }

    private var label: String {
        switch stage {
        case .extracting: return "读取记录…"
        case .compiling:  return "AI 编译中…"
        case .formatting: return "整理格式…"
        case .done:       return "完成"
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(DSColor.glassStd)
                        .frame(height: 3)
                    Capsule()
                        .fill(DSColor.accentAmber)
                        .frame(width: geo.size.width * progress, height: 3)
                        .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.8), value: progress)
                }
            }
            .frame(height: 3)

            Text(label)
                .font(DSType.mono10)
                .foregroundColor(DSColor.inkSubtle)
                .textCase(.uppercase)
                .tracking(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }
}

// MARK: - TimelineRow

/// V4: Direct card stack — no left timeline column. Cards float edge-to-edge
/// over the ambient background, letting the glass surface provide depth.
struct TimelineRow: View {
    let memo: Memo
    let isLast: Bool
    var onDelete: (() -> Void)? = nil
    var onPin: (() -> Void)? = nil
    var onRetranscribe: ((Memo, Memo.Attachment) -> Void)? = nil
    /// Issue #302: long-press → "分享为卡片"
    var onShare: (() -> Void)? = nil
    /// Issue #302: long-press → "分享为引用"
    var onShareAsQuote: (() -> Void)? = nil
    /// Issue #309 W2: long-press → "多选". Enters selection mode and
    /// seeds the selection with the long-pressed memo. nil hides the menu
    /// item (e.g. when already in selection mode).
    var onEnterSelectionMode: (() -> Void)? = nil
    /// Issue #309 W2: selection mode props. When isSelectionMode is true,
    /// the card renders with a selection indicator overlay and a tap
    /// toggles membership instead of navigating to the detail view.
    var isSelectionMode: Bool = false
    var isSelected: Bool = false
    var onToggleSelection: (() -> Void)? = nil
    /// Tap on the card body → open detail. Driven programmatically by the
    /// parent (the swipe card no longer uses a NavigationLink).
    var onOpen: (() -> Void)? = nil

    /// Drives the right-swipe MORE confirmation dialog (pin / delete / …).
    @State private var showMoreActions = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // 2026-07-04: the long-press menu is applied conditionally — in
        // selection mode a long press must do NOTHING (no menu, no preview
        // lift), so we branch on the flag instead of emptying the items.
        // This is also where the old double-contextMenu bug died: the card
        // (SwipeableMemoCard) used to carry its own share/pin/delete menu
        // that shadowed this one; both sets now merge here, over a real
        // card preview.
        if isSelectionMode {
            cardStack
        } else {
            cardStack
                // Long-press lift snapshot must share the card's 14pt
                // continuous silhouette — without this the system clips the
                // lift highlight to a square rect, flashing hard corners
                // around a rounded card for the first frames of the pick-up.
                .contentShape(
                    .contextMenuPreview,
                    RoundedRectangle(
                        cornerRadius: SwipePhysics.cardCornerRadius,
                        style: .continuous
                    )
                )
                .contextMenu {
                    mergedMenuItems
                } preview: {
                    // Full-bleed card snapshot lifted out of the timeline —
                    // reuses MemoCardView so the preview is the card, not a
                    // cropped screenshot of the row.
                    MemoCardView(memo: memo)
                        .frame(width: UIScreen.main.bounds.width - 40)
                }
        }
    }

    /// The card + selection chrome + MORE dialog, shared by both branches
    /// of `body`.
    private var cardStack: some View {
        ZStack(alignment: .topTrailing) {
            // In selection mode the inner NavigationLink must be disabled
            // (otherwise a tap routes to detail). We pass isSelectionMode
            // down so SwipeableMemoCard can mute its swipe gesture too —
            // both behaviors live on a single flag at the card root.
            SwipeableMemoCard(
                memo: memo,
                onDelete: onDelete,
                onPin: onPin,
                onShare: onShare,            // left-swipe SHARE → share-as-card
                onMore: { showMoreActions = true }, // right-swipe MORE → dialog
                // Card-body tap: in selection mode toggle membership, else open
                // detail. Both flow through the card's UIKit tap recognizer so
                // they never fight the swipe gesture's self-hit-testing host.
                onOpen: {
                    if isSelectionMode {
                        Haptics.soft()
                        onToggleSelection?()
                    } else {
                        onOpen?()
                    }
                },
                onRetranscribe: onRetranscribe,
                isSelectionMode: isSelectionMode
            )
            .frame(maxWidth: .infinity)
            // Dimmer when in selection mode but not selected — pulls focus
            // toward the picked memos without hiding the others completely.
            .opacity(isSelectionMode && !isSelected ? 0.55 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isSelected)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isSelectionMode)

            // Selection circle indicator, top-trailing.
            if isSelectionMode {
                selectionIndicator
                    .padding(.top, 14)
                    .padding(.trailing, 18)
                    .transition(.opacity)
            }
        }
        // Right-swipe MORE → fuller action set (pin / quote / delete) kept
        // out of the card's resting chrome per the content-first redesign.
        .confirmationDialog(
            NSLocalizedString("memo.swipe.more", comment: "more dialog title"),
            isPresented: $showMoreActions,
            titleVisibility: .hidden
        ) {
            moreActionsButtons
        }
    }

    /// Single merged long-press menu: pin + both share forms + multi-select,
    /// then delete isolated behind a divider. Mirrors every swipe-revealed
    /// action so the menu alone is a complete control surface.
    @ViewBuilder
    private var mergedMenuItems: some View {
        if let onPin {
            Button {
                Haptics.tapConfirm()
                onPin()
            } label: {
                let pinned = memo.pinnedAt != nil
                Label(
                    pinned
                        ? NSLocalizedString("memo.swipe.unpin", comment: "contextMenu: unpin memo")
                        : NSLocalizedString("memo.swipe.pin",   comment: "contextMenu: pin memo"),
                    systemImage: pinned ? "pin.slash" : "pin"
                )
            }
        }
        if let onShare {
            Button {
                onShare()
            } label: {
                Label(NSLocalizedString("memo.menu.shareCard", comment: "contextMenu: share memo as card"),
                      systemImage: "square.and.arrow.up.on.square")
            }
        }
        if let onShareAsQuote {
            Button {
                onShareAsQuote()
            } label: {
                Label(NSLocalizedString("memo.menu.shareQuote", comment: "contextMenu: share memo as quote"),
                      systemImage: "quote.opening")
            }
        }
        // Copy lived on a contextMenu INSIDE MemoCardView, which the swipe
        // gesture's overlay shadowed — it could never be summoned. The merged
        // menu is the single reachable long-press surface, so Copy belongs
        // here. Voice memos with an empty body copy their transcript instead.
        if !copyableText.isEmpty {
            Button {
                UIPasteboard.general.string = copyableText
                Haptics.tapConfirm()
            } label: {
                Label(NSLocalizedString("memo.menu.copyText", comment: "contextMenu: copy memo text"),
                      systemImage: "doc.on.doc")
            }
        }
        if let onEnterSelectionMode {
            Button {
                onEnterSelectionMode()
            } label: {
                Label(NSLocalizedString("memo.menu.multiselect", comment: "contextMenu: enter multi-select mode"),
                      systemImage: "checkmark.circle")
            }
        }
        if let onDelete {
            Divider()
            Button(role: .destructive) {
                Haptics.warningNotification()
                onDelete()
            } label: {
                Label(NSLocalizedString("memo.swipe.delete", comment: "contextMenu: delete memo"),
                      systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var moreActionsButtons: some View {
        if let onPin {
            Button(memo.pinnedAt != nil
                ? NSLocalizedString("memo.swipe.unpin", comment: "more dialog: unpin memo")
                : NSLocalizedString("memo.swipe.pin", comment: "more dialog: pin memo")) { onPin() }
        }
        if let onShareAsQuote {
            Button(NSLocalizedString("memo.menu.shareQuote", comment: "more dialog: share as quote")) { onShareAsQuote() }
        }
        if let onEnterSelectionMode {
            Button(NSLocalizedString("memo.menu.multiselect", comment: "more dialog: multi-select")) { onEnterSelectionMode() }
        }
        if let onDelete {
            Button(NSLocalizedString("memo.swipe.delete", comment: "more dialog: delete memo"), role: .destructive) { onDelete() }
        }
        Button(NSLocalizedString("memo.menu.cancel", comment: "more dialog: cancel"), role: .cancel) { }
    }

    /// Text the long-press Copy action puts on the pasteboard: the visible
    /// body, or — for voice memos whose body is empty — the transcript.
    private var copyableText: String {
        let body = memo.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { return body }
        return memo.attachments
            .first(where: { $0.kind == "audio" })?
            .transcript?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var selectionIndicator: some View {
        ZStack {
            Circle()
                .fill(isSelected ? DSColor.amberDeep : Color.white.opacity(0.9))
                .frame(width: 26, height: 26)
                .shadow(color: Color.black.opacity(0.15), radius: 3, x: 0, y: 1)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(DSType.caption)
                    .foregroundColor(.white)
            } else {
                Circle()
                    .strokeBorder(DSColor.inkSubtle.opacity(0.4), lineWidth: 1.5)
                    .frame(width: 26, height: 26)
            }
        }
        .accessibilityLabel(isSelected ? "已选中" : "未选中")
    }
}

// US-005: PreferenceKey used to propagate the ScrollView offset up to TodayView.
private struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// ViewModifier to wrap .numericText(value:) which requires iOS 17+
private struct NumericTextContentTransition: ViewModifier {
    let value: Double
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content
                .contentTransition(reduceMotion ? .identity : .numericText(value: value))
        } else {
            content
                .contentTransition(.identity)
        }
    }
}

// MARK: - Card → Detail zoom transition (iOS 18+)
//
// The App Store / Photos-style hero: tapping a memo card zooms the detail
// page out of the card frame and the back-swipe shrinks it back in. Both
// halves must share one `Namespace` (owned by TodayView) and matching ids.
// On iOS 16–17 both modifiers are inert and navigation keeps the standard
// push — no behavioral change below the availability floor.

/// Marks a timeline card as the zoom source for `memo.id`.
struct CardZoomSource: ViewModifier {
    let id: UUID
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
    }
}

/// Applies the zoom navigation transition to the pushed detail page.
struct CardZoomDestination: ViewModifier {
    let id: UUID
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            content
        }
    }
}
