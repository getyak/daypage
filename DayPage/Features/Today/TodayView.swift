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
    /// Reminder vNext (2026-07-15): 统一调度器 —— Today 胶囊条/编辑 sheet/AI
    /// 对话调度共用的单一数据源。
    @StateObject private var reminderService = CaptureReminderService.shared
    /// 非 nil = 打开提醒编辑 sheet；`reminder == nil` 表示新建。
    @State private var reminderSheetTarget: ReminderSheetTarget? = nil
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

    /// The historical day to push onto the NavigationStack as a `DayDetailView`.
    /// All three former entry points — On This Day card, zero-memo fallback
    /// "yesterday" page, and timeline tap/long-press — now set this single
    /// item (previously three separate `String?` bindings driving three
    /// `fullScreenCover`s). Pushing instead of covering gives the day a system
    /// back button + interactive edge-swipe-to-pop and a zoom transition.
    @State private var historicalDay: DayNavTarget? = nil

    /// Plain-text payload for the system share sheet when the user shares a
    /// timeline day. Identifiable wrapper because `.sheet(item:)` needs an id.
    @State private var timelineShareText: TimelineShareText? = nil

    /// Whether to show the Settings sheet.
    @State private var showSettings: Bool = false

    // R9-HIGH A2: `onThisDayShownAtTop` @State removed. The top vs fallback
    // OnThisDay card decision is now driven by the `shouldShowOnThisDayAtTop`
    // computed property, which both call sites read in the same render pass
    // — eliminating the lazy-onAppear race that briefly rendered two cards.

    /// Current time for the header timestamp (refreshed every minute).
    @State private var currentTime: Date = Date()

    /// Whether the daily page card is swiped open to reveal the recompile action.
    @State private var dailyPageRevealed: Bool = false
    /// Whether the recompile action chip behind the Daily Page card is
    /// mounted visibly. The card surface is 85%-translucent glass, so the
    /// amber chip must stay at opacity 0 while the card is at rest —
    /// otherwise it bleeds through the blur as an orange smear and its
    /// square corners peek past the card's rounded ones.
    @State private var dailyPageActionVisible: Bool = false

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
    /// #821: true while a whole-dock press-to-talk session is recording.
    /// Drives the timeline spotlight scrim behind the in-place capsule.
    @State private var isDockVoiceActive: Bool = false

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

    /// Canvas vNext: quantized hero-recede progress (0…8) across the first
    /// 160pt of scroll. The empty-day orbHero reads this to fade/scale away
    /// as the finger travels. Bucketed for the same reason as
    /// `scrollProgressBucket` — the view body must never re-render per
    /// scroll frame (input-smoothness lesson).
    @State private var heroFadeBucket: Int = 0

    /// 今日焦点 disclosure state — false = single ghost line, true = chips row.
    @State private var focusExpanded: Bool = false

    /// 0.0–1.0 hero recede progress recovered from the bucket.
    private var heroFadeProgress: CGFloat {
        CGFloat(heroFadeBucket) / 8.0
    }

    private var isInSelectionMode: Bool { selectedMemoIds != nil }

    /// Progress of the scroll-to-top ring: 0 at 240pt (button appears), 1 after
    /// 1200pt more. Reads the quantized bucket (0…20) so the ring's stroke
    /// re-renders at most 21 times across the travel rather than each frame.
    private var scrollProgress: CGFloat {
        CGFloat(scrollProgressBucket) / 20.0
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

                    // MARK: Status Slot — single status banner (banner collapse)
                    //
                    // The top region used to stack up to ~7 independent
                    // status banners (AI key, compile progress banner,
                    // sync queue, compile progress bar, compile failed,
                    // sync prompt, iCloud conflict), each with its own
                    // show-condition scattered through this VStack. Against
                    // the calm-capture minimalism that stack read as an
                    // alert wall, and on iPhone 12 mini it pushed the
                    // composer below the fold. Now `activeStatusSlot` picks
                    // the single highest-priority status surface and ONLY
                    // that banner renders here — the banner views and their
                    // tap/dismiss behaviors are unchanged; only the layout
                    // conditions moved into the slot computation (see
                    // `TodayStatusSlot` / `activeStatusSlot`). The slot sits
                    // above every content section (focus chips / OnThisDay /
                    // orbHero / timeline) because status rows are sticky
                    // "system status" surfaces that must always own the
                    // very top. Non-status content (OnThisDayCard,
                    // LocationDraftCard, todayFocusRow, orbHero,
                    // selectionToolbar) is NOT part of the slot.
                    statusSlotSection

                    // Canvas vNext (2026-07-14): the focus chips, OnThisDay
                    // card and orbHero used to be pinned HERE — outside the
                    // timeline ScrollView. On an empty day that froze ~65% of
                    // the screen around the hero and squeezed the only
                    // scrollable region (yesterday + history) into a ~180pt
                    // strip at the bottom. All three moved INTO the timeline's
                    // LazyVStack so the whole page reads as one continuous
                    // canvas: swipe up anywhere and the poem slides away,
                    // history fills the screen. Only the status slot stays
                    // sticky — system status must always own the very top.

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
                        // #821 spotlight scrim: while a press-to-talk session
                        // owns the dock, the timeline recedes behind a warm
                        // dim so the in-place recording capsule is the single
                        // lit object on the page. Never intercepts touches —
                        // the recording finger is still down on the dock.
                        .overlay {
                            if isDockVoiceActive {
                                DSTokens.Colors.recordingBg.opacity(0.22)
                                    .allowsHitTesting(false)
                                    .transition(.opacity)
                            }
                        }
                        .animation(Motion.fade, value: isDockVoiceActive)

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
                .dsAnimation(Motion.rise, value: undoText != nil)
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
                .dsAnimation(Motion.rise, value: viewModel.lastDeletedMemo != nil)
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
                                            .font(DSFonts.inter(size: 12, weight: .semibold, relativeTo: .caption))
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
                                    withAnimation(Motion.respectReduceMotion(Motion.rise)) { viewModel.submitError = nil }
                                }
                                .gesture(
                                    DragGesture(minimumDistance: 20)
                                        .onEnded { value in
                                            if value.translation.height < -10 || abs(value.translation.width) > 40 {
                                                Haptics.soft()
                                                withAnimation(Motion.respectReduceMotion(Motion.rise)) { viewModel.submitError = nil }
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
                    .dsAnimation(Motion.rise, value: viewModel.submitError)
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
            // US-030 note: the left-edge open-sidebar swipe lives ONLY in
            // RootView's edge strip (1:1 finger tracking). A fire-on-release
            // duplicate here competed in gesture arbitration with that
            // interactive version and could win, making the drawer pop open
            // with a canned animation instead of following the finger.
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
                // Clearing (send / confirmed discard) must NOT wait out the
                // debounce: a process kill inside the 0.8s window leaves the
                // stale mirror behind, and the next cold launch resurrects a
                // draft the user explicitly destroyed or already sent. An
                // empty write is a single event, so flush it synchronously.
                if snapshot.isEmpty {
                    draftDate = 0
                    UserDefaults.standard.removeObject(forKey: draftBackupKey)
                    return
                }
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
                // 「记录提醒」的「文字」action 传空串 → 只聚焦输入框、光标就绪,
                // 让用户到点点一下就能直接打字(复用既有 orbFocusToggle 聚焦轨道)。
                if text.isEmpty {
                    orbFocusToggle.toggle()
                }
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
                // Signature "ink settling" haptic for the compile moment —
                // fired here (same as the manual-compile path in
                // TodayViewModel) so the texture leads before the banner's
                // stock generator appears.
                SignatureHaptics.compileSuccess()
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
                let dateStr = DateFormatters.isoDate.string(from: Date())
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
            // Reminder vNext: 提醒编辑/新建 sheet。滴答式时间自定义收在这里，
            // Today 面上只留胶囊条；自然语言路径走 Coach/问过去对话。
            .sheet(item: $reminderSheetTarget) { target in
                ReminderEditSheet(service: reminderService, editing: target.reminder)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
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
                // Focused writing helper — medium detent + grab handle, so it
                // sits as a light panel over Today instead of a full-screen
                // modal, matching the self-drawn WriteSheet / recording sheets.
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
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
            // Historical-day navigation → DayDetailView, PUSHED onto this
            // NavigationStack (not a fullScreenCover). Issue #814 already routed
            // every "look at a past day" entry — On This Day card, zero-memo
            // fallback, timeline tap — through DayDetailView; this unifies their
            // *presentation* too: one `navigationDestination(item:)` instead of
            // three covers. Push gives the day a system back button + interactive
            // edge-swipe-to-pop, and (iOS 18+) a zoom transition out of the
            // tapped source via `.matchedTransitionSource` at each call site.
            // isPresented-based (iOS 16+) rather than item: (iOS 17+) so the
            // push compiles against the 17.0 deployment target without an
            // availability gate. The bound day is read inside the builder.
            .navigationDestination(
                isPresented: Binding(
                    get: { historicalDay != nil },
                    set: { if !$0 { historicalDay = nil } }
                )
            ) {
                if let target = historicalDay {
                    DayDetailView(dateString: target.dateString)
                        .modifier(CardZoomDestination(
                            id: target.dateString, namespace: detailZoomNamespace
                        ))
                }
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
            // 60pt clears Today's floating header row (menu / date / search)
            // so a live banner never blocks navigation (FINDING-014).
            .bannerOverlay(topInset: 60)
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
                .foregroundColor(DSColor.inkMuted)
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

    /// Museum-language sign-in prompt: one quiet mono line instead of the
    /// old two-line DSBanner card. Backup is plumbing — it may whisper from
    /// the status slot, but it must never outrank the day's own content
    /// (same voice as `modeBadge`: dot + mono uppercase + glass capsule).
    private var syncBanner: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(DSColor.accentOnBg.opacity(0.55))
                .frame(width: 5, height: 5)
            Text(NSLocalizedString("today.sync.prompt", value: "SYNC ACROSS DEVICES", comment: "One-line sign-in prompt on Today"))
                .font(DSType.mono10)
                .tracking(1.2)
                .foregroundColor(DSColor.inkMuted)
                .lineLimit(1)
            Spacer(minLength: 12)
            Button {
                showAuthSheet = true
            } label: {
                Text(NSLocalizedString("today.sync.action", value: "SIGN IN", comment: "Sign-in action on the sync prompt"))
                    .font(DSType.mono10)
                    .tracking(1.2)
                    .foregroundColor(DSColor.accentOnBg)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                dismissSyncBanner()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DSColor.inkMuted)
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.Banner.closeA11y)
        }
        .padding(.leading, 14)
        .background(Capsule().fill(DSColor.glassLo))
        .overlay(Capsule().strokeBorder(DSColor.glassRim, lineWidth: 0.5))
        .padding(.horizontal, DSSpacing.pageMargin)
        .padding(.bottom, DSSpacing.xs)
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    if value.translation.height < -10 {
                        dismissSyncBanner()
                    }
                }
        )
    }

    private func dismissSyncBanner() {
        withAnimation { showSyncBanner = false }
        UserDefaults.standard.set(Date(), forKey: AppSettings.Keys.lastSyncBannerDate)
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

    // MARK: - Status Slot (banner collapse)
    //
    // Enumerates every "system status" banner that used to render as an
    // independent conditional row at the top of the VStack. At most ONE
    // of these is visible at a time, chosen by strict priority (cases
    // are declared highest → lowest). Every banner stays REACHABLE: its
    // original show-condition still gates it inside `activeStatusSlot`;
    // it just waits its turn instead of stacking.
    private enum TodayStatusSlot: Equatable {
        /// Background compile failed after all retries (DSBanner .error).
        case compilationFailed
        /// R4-MEDIUM #38 — iCloud conflict auto-merge acknowledgement
        /// (DSBanner .warning). Self-dismisses after 3s (see the
        /// `.vaultConflictResolved` onReceive), so it never starves the
        /// slots below for long.
        case iCloudConflict
        /// R5 offline queue — only when something is actually stuck
        /// (>= 5 pending OR oldest waited > 1h), per #793 museum redesign.
        case offlineSyncQueue
        /// In-flight AI compile. Merges the two old progress surfaces:
        /// the rich stage banner (label + fraction bar, Issue #5) wins
        /// when BackgroundCompilationService reports a stage; the thin
        /// CompilationProgressBar covers foreground-only compiles where
        /// only `viewModel.isCompiling` is set.
        case compilationProgress
        /// "Sync your journal across devices" sign-in prompt.
        case syncPrompt
        // Canvas vNext (2026-07-14): the `.aiKeyMissing` info row left the
        // slot — a missing key only blocks the NIGHTLY compile, so it
        // doesn't earn a sticky page-top surface. It now renders as a quiet
        // footnote inside `orbHero` (empty days) and keeps the amber dot on
        // the settings gear for memo days.

        /// Error/conflict occupants push non-status cards (OnThisDay)
        /// out of the top region; info/progress occupants coexist.
        var isBlocking: Bool {
            switch self {
            case .compilationFailed, .iCloudConflict: return true
            default: return false
            }
        }
    }

    /// Single source of truth for which status banner occupies the slot.
    /// Each branch is the banner's ORIGINAL show-condition, moved here
    /// verbatim from the layout; first match (highest priority) wins.
    private var activeStatusSlot: TodayStatusSlot? {
        if viewModel.compilationFailedError != nil { return .compilationFailed }
        if iCloudConflictBannerVisible { return .iCloudConflict }
        if FeatureFlagStore.shared.isEnabled(.offlineQueue)
            && (syncQueue.pendingCount >= 5 || syncQueueWaitedTooLong) {
            return .offlineSyncQueue
        }
        if compileService.stage != .idle || viewModel.isCompiling { return .compilationProgress }
        if showSyncBanner { return .syncPrompt }
        return nil
    }

    /// Renders the single active status banner. The banner views
    /// themselves (and their tap/dismiss behaviors) are untouched — this
    /// is purely the slot switch. `Motion.bannerSlide` on the slot value
    /// makes an outgoing occupant slide away while the incoming one
    /// slides in, never stacked (nil under reduce-motion, matching the
    /// file's existing pattern).
    @ViewBuilder
    private var statusSlotSection: some View {
        Group {
            switch activeStatusSlot {
            case .compilationFailed:
                if let failureMsg = viewModel.compilationFailedError {
                    CompilationFailedBanner(message: failureMsg) {
                        viewModel.compilationFailedError = nil
                        viewModel.compile()
                    } onDismiss: {
                        viewModel.compilationFailedError = nil
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            case .iCloudConflict:
                iCloudConflictBanner
                    .transition(.opacity.combined(with: .move(edge: .top)))
            case .offlineSyncQueue:
                syncQueuePendingBanner
                    .transition(.opacity.combined(with: .move(edge: .top)))
            case .compilationProgress:
                // Prefer the richer Issue #5 stage banner whenever the
                // background service exposes a stage; fall back to the
                // thin bar for foreground-only compiles.
                if compileService.stage != .idle {
                    compileProgressBanner
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    CompilationProgressBar(stage: compilationService.stage)
                        .transition(.opacity)
                }
            case .syncPrompt:
                syncBanner
                    .transition(.opacity.combined(with: .move(edge: .top)))
            case nil:
                EmptyView()
            }
        }
        .animation(reduceMotion ? nil : Motion.bannerSlide, value: activeStatusSlot)
    }

    // MARK: - R9-HIGH A2/A3 — Banner stack guards (post-slot)
    //
    // With the single status slot, `bannerCount` is now 0 or 1. Kept as
    // a named property because the iPhone 12 mini composer-visibility
    // rationale still applies: the slot row plus a top card is the most
    // the region may occupy before the composer risks the fold.
    private var bannerCount: Int {
        activeStatusSlot == nil ? 0 : 1
    }

    /// R9-HIGH A2: single source of truth for whether the top-of-Today
    /// OnThisDay card renders. Used by both the `body` top section and
    /// the `onThisDayFallback(memos:)` inverse guard so the two paths
    /// agree inside the same SwiftUI render pass — no more lazy
    /// `.onAppear` flip that briefly stacked two cards.
    ///
    /// Slot-era guard: the card yields only when the status slot holds a
    /// blocking (error/conflict) occupant — an urgent banner should own
    /// the top alone, and on iPhone 12 mini banner + card + hero would
    /// push the composer below the fold. A low-priority info occupant
    /// (AI key, sync prompt, progress) coexists with the card; in the
    /// yield case the fallback (empty-day) path still surfaces the card
    /// if the day has no memos to push it offscreen.
    private var shouldShowOnThisDayAtTop: Bool {
        FeatureFlagStore.shared.isEnabled(.onThisDay)
            && viewModel.onThisDayEntry != nil
            && !(activeStatusSlot?.isBlocking ?? false)
    }

    /// Canvas vNext: true once the user has ANY compiled/recorded past —
    /// yesterday's page or any timeline day. Gates the sample-journal link
    /// (proof-of-value for brand-new users only).
    private var hasAnyHistory: Bool {
        viewModel.yesterdayDailyPageModel != nil || !viewModel.timelineSections.isEmpty
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
                    .font(DSFonts.serif(size: 13, weight: .regular, relativeTo: .footnote))
                    .foregroundColor(DSColor.inkMuted)
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
                    count == 1
                        ? "today.syncqueue.banner.flushing.one"
                        : "today.syncqueue.banner.flushing",
                    value: "正在同步 %d 条…",
                    comment: "Today banner headline while an upload pass is running"
                ),
                count
            )
        }
        return String(
            format: NSLocalizedString(
                count == 1
                    ? "today.syncqueue.banner.pending.one"
                    : "today.syncqueue.banner.pending",
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
                .dsAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true),
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
                            .dsAnimation(.easeInOut(duration: 0.4), value: compileService.stageFraction)
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
            RoundedRectangle(cornerRadius: DSRadius.md)
                .strokeBorder(DSColor.amberRim, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.md))
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
                Text(NSLocalizedString("today.focus.label", comment: "Today focus chip-row label"))
                    .font(DSType.mono10)
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundColor(DSColor.inkMuted)
                    .padding(.trailing, 4)
                focusChips
            }
            .padding(.horizontal, DSSpacing.pageMargin)
        }
        .dynamicTypeSize(.xSmall ... .accessibility2)
    }

    /// Bare chip buttons, shared by the legacy always-on row (flag off) and
    /// the expanded state of `focusDisclosureRow`.
    private var focusChips: some View {
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

    /// Canvas vNext progressive disclosure for 今日焦点. Three states:
    ///   - collapsed, nothing chosen  → ghost line "今日焦点 ›"
    ///   - collapsed, lenses chosen   → summary "今日焦点 · 工作 · 学习"
    ///   - expanded                   → the chip row, sans redundant label
    /// The data layer (TodayFocusStore → compile prompt) is untouched; this
    /// only changes when the chips earn pixels. Flag-off restores the legacy
    /// always-expanded row.
    @ViewBuilder
    private var focusDisclosureRow: some View {
        if FeatureFlagStore.shared.isEnabled(.todayFocusCollapsed) {
            VStack(spacing: 8) {
                Button {
                    Haptics.soft()
                    withAnimation(reduceMotion ? nil : Motion.spring) {
                        focusExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(focusSummaryLabel)
                            .font(DSType.mono10)
                            .tracking(1.2)
                            .textCase(.uppercase)
                            .foregroundColor(DSColor.inkMuted)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(DSColor.inkMuted.opacity(0.7))
                            .rotationEffect(.degrees(focusExpanded ? 90 : 0))
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("today.focus.label", comment: ""))
                .accessibilityValue(focusExpanded
                    ? NSLocalizedString("today.focus.a11y.expanded", comment: "Focus row expanded")
                    : NSLocalizedString("today.focus.a11y.collapsed", comment: "Focus row collapsed"))
                .accessibilityIdentifier("today.focus.disclosure")

                if focusExpanded {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            focusChips
                        }
                        .padding(.horizontal, DSSpacing.pageMargin)
                    }
                    .dynamicTypeSize(.xSmall ... .accessibility2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        } else {
            todayFocusRow
        }
    }

    /// Reminder vNext: 即将触发的提醒胶囊条。FeatureFlag.captureReminder 关
    /// 时整条不挂载（kill switch 与调度器一致）。点胶囊 → 编辑；点「＋」→
    /// 新建。数据源是统一调度器，AI 排的提醒也会出现在这里。
    @ViewBuilder
    private var reminderStrip: some View {
        if FeatureFlagStore.shared.isEnabled(.captureReminder) {
            ReminderCapsuleStrip(
                service: reminderService,
                now: currentTime,
                onEdit: { reminder in
                    reminderSheetTarget = ReminderSheetTarget(reminder: reminder)
                },
                onAdd: {
                    reminderSheetTarget = ReminderSheetTarget(reminder: nil)
                }
            )
        }
    }

    /// Ghost-line text: bare label when nothing is chosen, "· 工作 · 学习"
    /// coda once lenses are selected so the collapsed state still tells the
    /// user what tonight's compile will lean into.
    private var focusSummaryLabel: String {
        let base = NSLocalizedString("today.focus.label", comment: "")
        let chosen = TodayFocus.allCases.filter { focusStore.focuses.contains($0) }
        guard !chosen.isEmpty else { return base }
        return base + " · " + chosen.map(\.displayName).joined(separator: " · ")
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
                    .dsAnimation(
                        syncQueue.isFlushingNow
                            ? .linear(duration: 0.6).repeatForever(autoreverses: false)
                            : .default,
                        value: syncQueue.isFlushingNow
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(syncQueuePrimaryLabel)
                        .font(DSFonts.inter(size: 13, weight: .medium, relativeTo: .footnote))
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
                            .font(DSFonts.inter(size: 11, weight: .semibold, relativeTo: .caption))
                            .foregroundColor(DSColor.statusError)
                            .lineLimit(1)
                    } else if syncQueueWaitedTooLong {
                        // Per-count key pair, same pattern as FINDING-010
                        // ("1 RESULTS") — avoids shipping "Waiting 1 hours".
                        Text(String(
                            format: NSLocalizedString(
                                syncQueueWaitedHours == 1
                                    ? "today.syncqueue.banner.waited_hours.one"
                                    : "today.syncqueue.banner.waited_hours",
                                value: "已等待 %d 小时",
                                comment: "Today banner sub-label: queue stuck for N hours"
                            ),
                            syncQueueWaitedHours
                        ))
                            .font(DSFonts.inter(size: 11, weight: .semibold, relativeTo: .caption))
                            .foregroundColor(DSColor.statusError)
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
                        .font(DSFonts.inter(size: 14, weight: .medium, relativeTo: .subheadline))
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
                            .font(DSFonts.inter(size: 12, weight: .regular, relativeTo: .caption))
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
                            .font(DSFonts.inter(size: 13, weight: .regular, relativeTo: .footnote))
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
                                        .font(DSFonts.inter(size: 13, weight: .regular, relativeTo: .footnote))
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
                        .font(DSFonts.inter(size: 12, weight: .regular, relativeTo: .caption))
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
            // Canvas vNext: with the history timeline now rendering on empty
            // days too, the recap would duplicate 本周 — only keep it for the
            // (unusual) case where compiled pages exist but the timeline is
            // empty.
            if viewModel.timelineSections.isEmpty {
                WeeklyRecapSection(entries: entries) { dateString in
                    historicalDay = DayNavTarget(dateString: dateString)
                }
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
                        .foregroundColor(DSColor.inkMuted)
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
            // Mono kicker stays English per the archive-label convention
            // (FINDING-010); the date coda anchors WHICH yesterday this is.
            let dateCoda = Self.yesterdayLabelDate(page.dateString)
            Text(dateCoda.isEmpty
                 ? NSLocalizedString("today.section.yesterday", comment: "")
                 : "\(NSLocalizedString("today.section.yesterday", comment: "")) · \(dateCoda)")
                .font(DSType.mono10)
                .tracking(1.0)
                .foregroundColor(DSColor.inkMuted)
                .dynamicTypeSize(.xSmall ... .accessibility5)
                .padding(.horizontal, 20)

            DailyPageEntryCard(
                summary: page.summary.isEmpty ? nil : page.summary,
                ribbonText: NSLocalizedString(
                    "today.card.compiled.yesterday",
                    comment: "Yesterday card ribbon: the page is compiled"),
                metaText: page.memoCount > 0
                    ? String(format: NSLocalizedString(
                        "today.card.meta.memos",
                        comment: "Yesterday card meta: N raw memos"), page.memoCount)
                    : nil,
                onTap: {
                    historicalDay = DayNavTarget(dateString: page.dateString)
                }
            )
            .modifier(CardZoomSource(id: page.dateString, namespace: detailZoomNamespace))
            .padding(.horizontal, 20)
        }
    }

    /// "2026-07-13" → "JUL 13" for the yesterday kicker. en_US_POSIX keeps
    /// the mono label inside the archive-label (English small-caps) system.
    private static func yesterdayLabelDate(_ dateString: String) -> String {
        let parse = DateFormatter()
        parse.dateFormat = "yyyy-MM-dd"
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.timeZone = AppSettings.currentTimeZone()
        guard let date = parse.date(from: dateString) else { return "" }
        let out = DateFormatter()
        out.dateFormat = "MMM d"
        out.locale = Locale(identifier: "en_US_POSIX")
        out.timeZone = AppSettings.currentTimeZone()
        return out.string(from: date).uppercased()
    }

    // MARK: - History Supplement (memos present — shown at timeline bottom)

    /// History supplement rendered below today's raw memos. Previously this
    /// only showed yesterday's compiled page or the weekly recap; now it owns
    /// the full historical timeline (#276) — this week's other days, last
    /// week, week-before-last, and older months as expandable cards.
    ///
    /// Canvas vNext: also renders on EMPTY days. An empty today used to give
    /// the scroll region a single yesterday card and nothing else — "滑了也
    /// 白滑". Now swiping up on an empty day reads the whole past. Yesterday
    /// is de-duplicated via `supplementSections` when the fallback already
    /// shows its hero card above.
    @ViewBuilder
    private var historySupplement: some View {
        if viewModel.loadState == .ready && !supplementSections.isEmpty {
            // Quiet breathing room replaces the redundant "EARLIER" rule —
            // the timeline's own SectionHeader (本周/上周) already separates bands.
            // 12 here + the SectionHeader's own 20 top padding lands the
            // page's section rhythm on a single 32pt beat.
            Color.clear
                .frame(height: 12)
                .accessibilityLabel(Text(NSLocalizedString("today.section.earlier", comment: "")))
            ForEach(supplementSections) { section in
                TimelineSectionView(
                    section: section,
                    zoomNamespace: detailZoomNamespace,
                    onOpenDate: { dateString in
                        historicalDay = DayNavTarget(dateString: dateString)
                    },
                    onShareDate: { entry in shareTimelineDay(entry) },
                    onDeleteDate: { entry in deleteTimelineDay(entry) }
                )
            }
        }
    }

    @ViewBuilder
    private func yesterdayDailyPageFallback(_ page: DailyPageModel) -> some View {
        yesterdaySection(page)
    }

    /// Timeline sections feeding `historySupplement`. On an empty day whose
    /// fallback already shows yesterday's hero card, yesterday's entry is
    /// filtered out of its time band so the day never appears twice.
    private var supplementSections: [TimelineSection] {
        let sections = viewModel.timelineSections
        guard viewModel.memos.isEmpty,
              case .yesterdayDailyPage(let page) = viewModel.fallbackContent else {
            return sections
        }
        return sections.compactMap { section in
            let days = section.days.filter { $0.dateString != page.dateString }
            guard !days.isEmpty else { return nil }
            return days.count == section.days.count
                ? section
                : TimelineSection(kind: section.kind, days: days)
        }
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

    /// R6 — tap callback for the OnThisDayCard. Pushes the historical day onto
    /// the Today NavigationStack (via the `historicalDay` item) AND posts
    /// `.openArchiveAt` so a deep-link consumer (Archive tab, navigation
    /// model) can pivot to the historical day. The Notification post is
    /// harmless when there's no listener — Archive may not be mounted yet
    /// on a cold tap, in which case the in-Today push path handles UX.
    private func handleOnThisDayTap(_ entry: OnThisDayEntry) {
        let dateStr = Self.dateString(from: entry.originalDate)
        // Keep the in-Today push path so the existing UX (open the historical
        // DayDetail without switching tabs) still works.
        historicalDay = DayNavTarget(dateString: dateStr)
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
        DateFormatters.isoDate.string(from: date)
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
                    withAnimation(Motion.respectReduceMotion(Motion.spring)) {
                        dailyPageRevealed = false
                    }
                    hideDailyPageActionSoon()
                    viewModel.compile()
                } label: {
                    Text(NSLocalizedString("today.action.recompile", comment: ""))
                        .font(DSType.caption)
                        .foregroundColor(.white)
                        .frame(width: 72)
                        .frame(maxHeight: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(DSColor.accentAmber)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("a11y.recompile", comment: "Recompile daily page"))
            }
            // Invisible until a swipe (or the one-time hint) actually starts:
            // the glass card above is translucent, so a permanently-mounted
            // amber panel bleeds through at rest (#audit — orange smear +
            // exposed square corners on the compiled card).
            .opacity(dailyPageActionVisible ? 1 : 0)

            DailyPageEntryCard(
                summary: viewModel.dailyPageSummary,
                onTap: {
                    if dailyPageRevealed {
                        Haptics.soft()
                        withAnimation(Motion.respectReduceMotion(Motion.spring)) {
                            dailyPageRevealed = false
                        }
                        hideDailyPageActionSoon()
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
                withAnimation(Motion.respectReduceMotion(Motion.spring)) {
                    dailyPageRevealed = false
                }
                hideDailyPageActionSoon()
            }
            .offset(x: (dailyPageRevealed ? -80 : 0) + dailyPageDrag + dailyPageHintOffset)
            .onAppear {
                guard !UserDefaults.standard.bool(forKey: AppSettings.Keys.dailyPageSwipeHintShown),
                      !reduceMotion else { return }
                UserDefaults.standard.set(true, forKey: AppSettings.Keys.dailyPageSwipeHintShown)
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(0.6))
                    dailyPageActionVisible = true
                    withAnimation(Motion.spring) { dailyPageHintOffset = -24 }
                    Haptics.soft()
                    try? await Task.sleep(for: .seconds(0.45))
                    withAnimation(Motion.spring) { dailyPageHintOffset = 0 }
                    hideDailyPageActionSoon()
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
                        withAnimation(Motion.respectReduceMotion(Motion.spring)) {
                            dailyPageRevealed = value.translation.width < -44
                        }
                        if !dailyPageRevealed {
                            hideDailyPageActionSoon()
                        }
                    }
            )
            .onChange(of: dailyPageDrag) { drag in
                if drag < 0 { dailyPageActionVisible = true }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(NSLocalizedString("a11y.daily_page", comment: "Daily page card"))
        .accessibilityValue(viewModel.dailyPageSummary ?? "")
        .accessibilityHint(NSLocalizedString("a11y.daily_page.hint", comment: "Daily page open hint"))
        .accessibilityAction { showDailyPage = true }
        .accessibilityAction(named: Text(NSLocalizedString("today.action.recompile", comment: ""))) {
            dailyPageRevealed = false
            hideDailyPageActionSoon()
            viewModel.compile()
        }
    }

    /// Fades the recompile chip out shortly after the card snaps shut —
    /// the delay lets the spring cover the chip's footprint first so the
    /// dismissal never flashes a cream hole where amber used to be.
    private func hideDailyPageActionSoon() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.35))
            guard !dailyPageRevealed, dailyPageDrag == 0 else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                dailyPageActionVisible = false
            }
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
                    // Focus only — never write the time-of-day prompt into
                    // draftText: it saved verbatim into the memo body ("今天
                    // 最终落在哪里了？morning at…"). Same rationale as the
                    // dock's removed "记下此刻" hint (InputBarV4): guidance
                    // belongs in placeholder chrome, not in user content.
                    orbFocusToggle.toggle()
                }

                VStack(spacing: 8) {
                    Text(NSLocalizedString("today.empty.poem.title",
                                           comment: "Empty-state poem main line (e.g. 把今天放下来。)"))
                        .font(DSFonts.serif(size: 28, weight: .regular, relativeTo: .title))
                        .foregroundColor(DSColor.inkPrimary)
                        .multilineTextAlignment(.center)
                        .dynamicTypeSize(.xSmall ... .accessibility2)
                        .minimumScaleFactor(0.7)
                    Text(NSLocalizedString("today.empty.poem.subtitle",
                                           comment: "Empty-state poem secondary line (e.g. 我陪你整理。)"))
                        .font(DSFonts.serif(size: 17, weight: .regular, relativeTo: .headline))
                        .foregroundColor(DSColor.inkMuted)
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
                // Focus only — see the tap handler above for why the prompt
                // must not be written into draftText.
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
                            .font(DSFonts.serif(size: 15, weight: .medium, relativeTo: .subheadline))
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

            // Canvas vNext: AI-key footnote. Demoted from the sticky status
            // slot — a missing key only affects the nightly compile, so it
            // rides along with the hero and scrolls away with it.
            if shouldShowAIKeyBanner {
                aiKeyMissingBanner
                    .padding(.top, 2)
            }

            // Issue #2 (2026-07-02): "See a sample journal" fallback link.
            // For users who skipped or dismissed the Welcome CTA, the empty
            // Today gives no proof of what the AI will produce. Tapping this
            // seeds 3 sample memos + a paired compiled daily.md (see
            // SampleDataSeeder) and refreshes the timeline. Once seeded, the
            // label flips so the user knows exactly what to open next.
            //
            // Canvas vNext: zero-history users ONLY. Anyone with a compiled
            // yesterday or any timeline history already has real proof —
            // for them this link is pure noise.
            if !hasAnyHistory {
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
                        .foregroundColor(DSColor.inkMuted)
                        .padding(.top, 6)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("today-empty-try-sample")
                .disabled(sampleSeeded)
            }

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
            .foregroundColor(DSColor.inkMuted)

            Spacer()

            Text(count == 0
                 ? NSLocalizedString("today.select.prompt", comment: "")
                 : String(format: NSLocalizedString("today.select.count", comment: ""), count))
                .font(DSType.mono10)
                .tracking(1.5)
                .textCase(.uppercase)
                .foregroundColor(DSColor.inkPrimary)
                .modifier(TodayNumericTextTransition(value: Double(count), reduceMotion: reduceMotion))
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

    /// Derives a continuously-interpolated ambient hue for the orb breathing glow.
    private func orbTint(_ date: Date) -> Color {
        TimeOfDay.continuousTint(at: date)
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
            requestFocusToggle: orbFocusToggle,
            onRecordingActiveChange: { active in
                isDockVoiceActive = active
            }
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
                onDiscard: {
                    // Explicit, confirmed discard — the ONLY path that
                    // destroys the draft. Plain close keeps everything.
                    draftText = ""
                    viewModel.clearPendingAttachments()
                },
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
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(DSColor.inkMuted)
                        .frame(width: 36, height: 36)
                        .glassSurface(in: Circle())
                        .clipShape(Circle())
                }
                .buttonStyle(.dsIconChip)
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

                // R4 (#793 comp 4.png): the top bar is exactly two chips —
                // ☰ left, 🔍 right. No middle export chip: it made the
                // toolbar drift between 2- and 3-chip layouts as the day
                // filled in. Export lives in the hero title's context menu
                // (`exportMenuItems`), keeping the toolbar rhythm invariant.

                // Settings moved into the sidebar bottom section — the
                // toolbar's trailing slot now opens global search, riding
                // the same `pendingSearchQuery` rail the sidebar row and
                // the `daypage://search?q=` URL scheme already use.
                Button {
                    Haptics.soft()
                    nav.selectedTab = .archive
                    nav.pendingSearchQuery = ""
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(DSColor.inkMuted)
                        .frame(width: 36, height: 36)
                        .glassSurface(in: Circle())
                        .clipShape(Circle())
                }
                .buttonStyle(.dsIconChip)
                .accessibilityLabel(NSLocalizedString("today.toolbar.search", comment: "Global search button"))
                .accessibilityHint(NSLocalizedString("today.toolbar.search.hint", comment: "Opens global search"))
                .accessibilityIdentifier("today-search-button")
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
                        .font(DSFonts.serif(size: 26, weight: .regular, relativeTo: .title))
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
        // toolbar title (memo day): both branches carry explicit transitions
        // (big hero → .opacity + .move(.top), compact title → .opacity +
        // .scale) and every memo mutation in TodayViewModel runs inside
        // withAnimation, so the swap still reads as one deliberate motion
        // WITHOUT a container-level `.animation(value: hasMemos)` that
        // would re-animate this entire header subtree (Axiom perf rule).
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
            // Canvas vNext: date only, muted. On a day with content the
            // calendar is chrome, not content — the weekday dropped out and
            // the ink stepped back so the timeline owns the reader's eye.
            Text(Self.headerDateFmt.string(from: currentTime))
                .font(DSFonts.serif(size: 14, weight: .regular, relativeTo: .subheadline))
                .foregroundColor(DSColor.inkMuted)
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

                // MARK: On This Day Card (R8-CRITICAL → Canvas vNext)
                //
                // 时光胶囊在所有日子都可出现（只要 OnThisDayScheduler 注入了
                // entry）。Canvas vNext 把它从固定顶栏移进滚动画布：它是内容，
                // 不是系统状态——读完即可划走，不再永久占用首屏。
                //
                // R9-HIGH A2/A3 语义保留：`shouldShowOnThisDayAtTop` 与
                // fallback 路径在同一 render pass 内互斥；error/conflict slot
                // 占用时让位（guard 在 computed 里）。
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
                        // Canvas vNext: the hero now scrolls WITH the page and
                        // quietly recedes as the finger travels — opacity/scale
                        // driven by the same bucketed offset the header glass
                        // uses (never the raw 60Hz value; see the
                        // `timelineScrollOffset` property doc).
                        orbHero
                            .opacity(reduceMotion ? 1 : 1 - 0.85 * heroFadeProgress)
                            .scaleEffect(reduceMotion ? 1 : 1 - 0.05 * heroFadeProgress, anchor: .top)

                        // 今日焦点 — collapsed to a single ghost line; expands
                        // on tap, summarizes once lenses are chosen.
                        focusDisclosureRow
                            .padding(.top, 2)

                        // Reminder vNext: 即将触发的提醒胶囊 + 快捷新建。
                        // 空态放在焦点行之下 —— 与 chrome 同级，不与诗抢戏。
                        reminderStrip
                            .padding(.top, 6)

                        fallbackContentView
                            .padding(.top, 18)
                    }
                } else {
                    // Reminder vNext: memo 日的胶囊条 —— 一行薄 chrome，
                    // 在今日信号之上给 AI/手动排的提醒一个可见落点，随画布滚走。
                    reminderStrip
                        .padding(.bottom, 2)

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
                        // 美术馆入场 (iOS 17+): subtle scroll-in settle on the
                        // row container OUTSIDE SwipeableMemoCard, so it never
                        // fights the card's UIKit pan / offset gesture.
                        .modifier(ScrollEntranceModifier())
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
        .modifier(TodayScrollOffsetWatcher(onChange: { value in
            handleScrollOffset(value)
        }))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { timelineScrollProxy = proxy }
        } // end ScrollViewReader
    }

    /// Single consumer for the timeline's scroll offset, regardless of which
    /// mechanism delivered it (see `TodayScrollOffsetWatcher`). Convention:
    /// 0 at rest, NEGATIVE as the user scrolls up — the historical
    /// PreferenceKey minY convention every threshold below was written for.
    ///
    /// Only threshold-bucketed state is stored so the view body invalidates
    /// O(1) times per scroll instead of O(60Hz) — the raw value goes into
    /// `timelineScrollOffset`, which no body path may read (see property doc).
    private func handleScrollOffset(_ value: CGFloat) {
        timelineScrollOffset = value
        let scrolled = value < -8
        if scrolled != isTimelineScrolled { isTimelineScrolled = scrolled }
        let showTop = value < -240
        if showTop != showScrollToTopButton { showScrollToTopButton = showTop }
        // Quantize the ring progress (0…20) — floor(clamp(-value - 240, 0, 1200) / 60).
        let clamped = max(0, min(1200, -value - 240))
        let bucket = Int(clamped / 60)
        if bucket != scrollProgressBucket { scrollProgressBucket = bucket }
        // Canvas vNext: hero recede over the first 160pt, 8 buckets.
        let hero = Int(max(0, min(160, -value)) / 20)
        if hero != heroFadeBucket { heroFadeBucket = hero }
    }

    /// Compose area: compile button + input bar.
    ///
    /// 编译不再有"记满 3 条才解锁"的门槛——每天用户时区 0 点会自动编译前一天
    /// （BackgroundCompilationService），手动编译入口在此始终可用：只要当天有
    /// memo 且尚未编译，就直接显示编译按钮，无论几条。
    @ViewBuilder
    private var composeSection: some View {
        let aiKeyMissing = Secrets.resolvedDeepSeekApiKey.isEmpty
        // Axiom perf (motion overhaul): this footer used to animate on
        // `viewModel.memos.count`, which re-sprang the whole subtree on
        // EVERY capture. Animate on the exact Bool that actually toggles
        // the recovery footer's visibility instead.
        let showsRecoveryFooter = !viewModel.isDailyPageCompiled
            && !viewModel.memos.isEmpty
            && (viewModel.isCompiling || viewModel.submitError != nil)
            && !aiKeyMissing
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
            if showsRecoveryFooter {
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
        .animation(reduceMotion ? nil : Motion.spring, value: showsRecoveryFooter)
        .onChange(of: viewModel.memos.count) { count in
            if count >= 3 && !viewModel.isDailyPageCompiled && !didCelebrateUnlock {
                didCelebrateUnlock = true
                SignatureHaptics.compileSuccess()
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
                SignatureHaptics.compileSuccess()
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

    private func weekdayName(_ date: Date) -> String {
        Self.weekdayFmt.string(from: date)
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
            .foregroundColor(DSColor.inkMuted)
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
            parts = [dateStr, DateFormatters.timeHHmm.string(from: date)]
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
        guard let date = DateFormatters.isoDate.date(from: dateString) else { return }

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
