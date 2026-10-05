import SwiftUI
import DayPageServices
import DayPageStorage

// MARK: - AppTab

enum AppTab: Equatable {
    case today
    case archive
    case feedback
    case graph
}

// MARK: - Navigation value types
//
// Hashable wrappers pushed onto a NavigationStack via `navigationDestination`.
// Centralised here (rather than a new file) so every host stack registers the
// SAME destination types, replacing the old per-view `.sheet` + `@State
// selectedEntitySlug` recursion that stacked modals with no shared back stack
// and no interactive edge-pop. A single `navigationDestination(for:
// EntityRef.self)` per stack supports UNBOUNDED recursion: an entity page that
// pushes another entity just appends another EntityRef and the same registered
// destination resolves it.

/// Identifies an entity wiki page (place / person / theme) for push navigation.
/// `type` is the vault folder ("places" | "people" | "themes"), `slug` the file
/// stem. `sourceDateString` is presentational only (a breadcrumb hint) and is
/// EXCLUDED from Hashable/Equatable so the identity of the destination is just
/// (type, slug) — the breadcrumb it was opened from doesn't change WHICH entity
/// page this is. (Note: NavigationPath.append does NOT dedupe by Hashable, so
/// pushing the same EntityRef twice DOES stack two pages; identity here is for
/// destination-builder matching, not push suppression.)
struct EntityRef: Hashable {
    let type: String
    let slug: String
    var sourceDateString: String? = nil

    static func == (lhs: EntityRef, rhs: EntityRef) -> Bool {
        lhs.type == rhs.type && lhs.slug == rhs.slug
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(type)
        hasher.combine(slug)
    }
}

/// Identifies a compiled Daily Page (vault/wiki/daily/YYYY-MM-DD.md) for push
/// navigation. Distinct from `DayNavTarget` (which pushes the fuller
/// `DayDetailView`): a `DailyRef` pushes `DailyPageView` directly — the page
/// reached when tapping a date from inside an entity page.
struct DailyRef: Hashable {
    let dateString: String
}

enum MemoDetailSource: Hashable {
    case today
    case daily
    case raw
    case archive

    var backLabel: String {
        switch self {
        case .today:
            return NSLocalizedString(
                "memo.detail.nav.back", value: "Today",
                comment: "Detail view — back-to-today button label"
            )
        case .daily:
            return NSLocalizedString(
                "memo.detail.nav.back.daily", value: "Daily",
                comment: "Detail view — back label when pushed from a daily page"
            )
        case .raw:
            return NSLocalizedString(
                "daydetail.tab.raw", value: "Raw Memos",
                comment: "Detail view — return to the owning raw memo day"
            )
        case .archive:
            return NSLocalizedString(
                "archive.title", value: "Archive",
                comment: "Detail view — return from a selected search memo"
            )
        }
    }
}

/// The single memo-detail route used by every entry point.  It carries stable
/// identity and the validated canonical owning raw day FILE KEY
/// (`YYYY-MM-DD`), never a mutable list snapshot and never a `Date` that a
/// later preferred-time-zone change could reinterpret into a neighbouring
/// file.  The destination resolves the current memo through
/// `MemoRecordStore`'s canonical `dayString:` paths; `usesZoomTransition` is
/// presentation-only and does not change record identity.
struct MemoDetailRef: Hashable {
    let id: UUID
    /// Canonical owning raw day file key, validated at construction.
    let dayString: String
    let source: MemoDetailSource
    var usesZoomTransition = false

    /// Canonical initializer. The owning-day key is validated independently
    /// of the current preferred zone and fails closed on invalid input.
    init?(id: UUID, dayString: String, source: MemoDetailSource, usesZoomTransition: Bool = false) {
        guard RawStorage.isValidDayString(dayString) else { return nil }
        self.id = id
        self.dayString = dayString
        self.source = source
        self.usesZoomTransition = usesZoomTransition
    }

    /// Legacy Date-based initializer kept for existing callers/tests.
    /// Converts the Date to its canonical owning-day key ONCE, at construction
    /// — the ref never re-derives a day from a stored Date afterwards.
    init(id: UUID, day: Date, source: MemoDetailSource, usesZoomTransition: Bool = false) {
        self.id = id
        self.dayString = RawStorage.dayString(for: day)
        self.source = source
        self.usesZoomTransition = usesZoomTransition
    }

    static func == (lhs: MemoDetailRef, rhs: MemoDetailRef) -> Bool {
        lhs.id == rhs.id && lhs.dayString == rhs.dayString && lhs.source == rhs.source
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(dayString)
        hasher.combine(source)
    }
}

/// Pushes WeeklyRecapDetailView onto the Archive path. W1 fix: this page used to
/// push via a closure `NavigationLink { WeeklyRecapDetailView… }`, which mixed an
/// eager link push with the path-driven entity/day pushes on the same
/// path-bound stack — so edge-back opened the sidebar (path reported empty), the
/// pop gesture was never re-armed, and entity-chip pushes from inside it could
/// desync the stack. Routing it through the path unifies all Archive pushes.
struct WeeklyRecapRef: Hashable {
    let referenceDate: Date
}

// MARK: - AppNavigationModel

@MainActor
final class AppNavigationModel: ObservableObject {

    @Published var selectedTab: AppTab = AppNavigationModel.initialTab()
    @Published var isSidebarOpen: Bool = false
    @Published var isFeedbackPanelOpen: Bool = false

    // MARK: - Per-tab navigation paths (W1)
    //
    // Each drill-down tab owns a NavigationPath so entity/daily/memo pushes are
    // programmatic and heterogeneous (EntityRef | DailyRef | Memo.ID | …). A
    // view buried in Markdown (an entity ink deep in prose) can push simply by
    // calling `push(_:in:)` — no local `.sheet` state, no modal nesting. The
    // same registered `navigationDestination` resolves an unbounded recursive
    // chain (entity → entity → daily → entity …), each link just appending.
    //
    // Graph keeps its `.sheet` (per the migration decision) and has no path.
    @Published var todayPath = NavigationPath()
    @Published var archivePath = NavigationPath()

    /// Push a Hashable value onto the given tab's stack. (The system back button
    /// and interactive edge-pop handle popping, so no explicit pop helper is
    /// needed — SwiftUI mutates the bound path directly.)
    func push<V: Hashable>(_ value: V, in tab: AppTab) {
        switch tab {
        case .today:   todayPath.append(value)
        case .archive: archivePath.append(value)
        default: break
        }
    }

    /// True when the currently-selected tab has a detail page pushed — meaning a
    /// left-edge swipe should pop that page (system gesture), NOT open the
    /// sidebar. RootView's edge strip reads this to step aside.
    ///
    /// WHY the edge strip needs it: RootView's left-edge strip opens the sidebar
    /// and sits above every child stack in the root ZStack, so its SwiftUI
    /// DragGesture beats the child stack's UIKit `interactivePopGestureRecognizer`
    /// for the same 20pt edge. The strip must yield when the active tab can pop.
    ///
    /// Purely path-driven since W1 unified every push onto a NavigationPath —
    /// the tab's path being non-empty IS "a detail page is on top".
    var activeStackCanPop: Bool {
        switch selectedTab {
        case .today:   return !todayPath.isEmpty
        case .archive: return !archivePath.isEmpty
        default:       return false
        }
    }

    /// Deep-link target for ArchiveView. When set, ArchiveView opens its
    /// DayDetailView for this date the next time it observes the change.
    /// Cleared by ArchiveView once consumed so re-tapping the same row in the
    /// sidebar still triggers the navigation.
    @Published var pendingArchiveDate: String? = nil

    /// Bumped to a new UUID by system-level entry points (URL scheme,
    /// AppIntent, Widget, ControlWidget, Siri) that want to immediately
    /// open the voice recorder on Today. TodayView observes the change and
    /// flips its `isShowingVoiceRecorder` flag. We use a UUID instead of a
    /// bool so repeated triggers from the same widget tap re-fire.
    @Published var pendingRecordingTrigger: UUID? = nil

    /// Pre-filled draft text delivered via `daypage://memo/new?text=…`.
    /// TodayView consumes this once and resets it to nil.
    @Published var pendingDraftText: String? = nil

    /// Pre-filled search query delivered via `daypage://search?q=…` (e.g. from
    /// `AskTodayIntent`). ArchiveView observes this, presents SearchView with
    /// the query pre-populated, and clears it so re-tapping the same shortcut
    /// re-fires the navigation.
    @Published var pendingSearchQuery: String? = nil

    /// Pre-filled question delivered via `daypage://ask?q=…` (from `AskTodayIntent`).
    /// RootView observes this, presents the "和过去对话" chat sheet seeded with the
    /// question, and clears it so re-firing the same shortcut re-opens the sheet.
    /// This is the D1 entry point (research doc §3 D1); kept separate from
    /// `pendingSearchQuery` so the Shortcuts surface can route to either the
    /// keyword search (Archive) or the memory-chat agent without ambiguity.
    @Published var pendingAskQuery: String? = nil

    /// vNext:调度中心(ScheduleHubView)的呈现开关。放在 nav(全局稳定层)而非
    /// SidebarView 的 @State —— 侧边栏点「调度」要先 closeSidebar,抽屉随即被
    /// offset 离屏 + accessibilityHidden,若 sheet 状态挂在 SidebarView 上,它的
    /// @State 在动画中不可靠(实测延迟置 true 也被丢),sheet 不呈现。改由稳定的
    /// RootView 挂 .sheet 驱动,和 pendingAskQuery 从侧边栏可靠打开是同款模式。
    @Published var showScheduleHub: Bool = false

    /// Item-driven Apple System Actions surface. Siri, Spotlight, widgets,
    /// deep links and in-app entry points all set this same value so approval
    /// and editing cannot diverge between entry paths.
    @Published var systemActionPresentation: SystemActionPresentation?

    init() {
        #if DEBUG
        // Direct pre-mount route for screenshot/E2E runs. `simctl openurl`
        // presents an OS confirmation alert and cannot exercise the in-app
        // destination unattended, while this uses Archive's normal pending
        // date consumer and NavigationStack push.
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-qaArchiveDate"),
           args.indices.contains(index + 1) {
            let date = args[index + 1]
            if date.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
                selectedTab = .archive
                pendingArchiveDate = date
            }
        }
        #endif
    }

    private static func initialTab() -> AppTab {
        initialTab(arguments: ProcessInfo.processInfo.arguments)
    }

    /// Pure launch-routing helper so the pre-mount QA path stays covered by
    /// unit tests instead of relying on a screenshot to reveal lifecycle races.
    static func initialTab(arguments args: [String]) -> AppTab {
        #if DEBUG
        // QA screenshots need the destination selected before persistent tab
        // hosts mount. Switching in RootView.onAppear made Archive appear while
        // its first `isActive` lifecycle value remained false, so its month
        // scan never ran and populated fixtures looked empty.
        let index = args.firstIndex(of: "-qaSelectedTab")
            ?? args.firstIndex(of: "-selectedTab")
        #else
        let index = args.firstIndex(of: "-selectedTab")
        #endif
        guard let index,
              args.indices.contains(index + 1) else {
            return .today
        }

        switch args[index + 1].lowercased() {
        case "archive": return .archive
        case "graph": return .graph
        default: return .today
        }
    }

    // Drawer settle uses Motion.panel (spring) instead of Motion.slide
    // (timing curve): springs merge & retarget when interrupted, so a
    // mid-flight reversal (finger catches the drawer) keeps its velocity
    // instead of hard-cutting. Haptics fire only on actual state changes so
    // programmatic re-closes (e.g. navigate while already closed) stay silent.
    func openSidebar() {
        guard !isSidebarOpen else { return }
        Haptics.soft()
        withAnimation(Motion.respectReduceMotion(Motion.panel)) {
            isSidebarOpen = true
        }
    }

    func closeSidebar(haptic: Bool = true) {
        guard isSidebarOpen else { return }
        if haptic { Haptics.soft() }
        withAnimation(Motion.respectReduceMotion(Motion.panel)) {
            isSidebarOpen = false
        }
    }

    func navigate(to tab: AppTab) {
        if selectedTab != tab {
            Haptics.selection()
            selectedTab = tab
        }
        // Drawer close is implied by the tab selection tick — a second
        // impact here would read as a double-buzz.
        closeSidebar(haptic: false)
    }

    /// Switch to Archive and ask ArchiveView to open the DayDetailView for the
    /// given `YYYY-MM-DD` once it appears.
    func openArchive(at dateString: String) {
        pendingArchiveDate = dateString
        selectedTab = .archive
        closeSidebar()
    }

    /// Issue #7 QA (2026-07-03): switch to Archive without pushing a specific
    /// day — lets `daypage://archive` land on the Vault Overview strip.
    func openArchiveOverview() {
        pendingArchiveDate = nil
        selectedTab = .archive
        closeSidebar()
    }

    func openFeedbackPanel() {
        closeSidebar(haptic: false)
        guard !isFeedbackPanelOpen else { return }
        Haptics.soft()
        withAnimation(Motion.respectReduceMotion(Motion.panel)) {
            isFeedbackPanelOpen = true
        }
    }

    func closeFeedbackPanel() {
        guard isFeedbackPanelOpen else { return }
        Haptics.soft()
        withAnimation(Motion.respectReduceMotion(Motion.panel)) {
            isFeedbackPanelOpen = false
        }
    }
}

// MARK: - Shared entity/daily destinations (W1)

/// Registers the `EntityRef` and `DailyRef` push destinations on a host stack.
/// Attach once per NavigationStack (Today / Archive / and inside DailyPage's own
/// modal stack). Because one registration resolves every value of that type,
/// pushing an entity from inside an entity page (recursive) needs no extra
/// wiring — the append lands on the same destination.
///
/// Both pushed pages run in their PUSHED form: no inner NavigationStack, no
/// custom back button — they inherit the host's system back + interactive
/// edge-pop (the whole point of the sheet→push migration).
private struct EntityDailyDestinations: ViewModifier {
    func body(content: Content) -> some View {
        content
            .navigationDestination(for: EntityRef.self) { ref in
                EntityPageView(
                    entityType: ref.type,
                    entitySlug: ref.slug,
                    sourceDateString: ref.sourceDateString,
                    // MUST be true here: pushed onto the host stack, so
                    // EntityPageView must take its no-inner-NavigationStack
                    // branch. Omitting it defaults to the sheet branch, which
                    // nests a NavigationStack inside this destination → black
                    // render + dead gestures (the classic nested-stack bug).
                    isPushed: true
                )
                .restoresInteractivePop()
            }
            .navigationDestination(for: DailyRef.self) { ref in
                DailyPageView(dateString: ref.dateString, isEmbedded: true)
                    .restoresInteractivePop()
            }
    }
}

extension View {
    /// Register the shared entity + daily push destinations on this stack.
    func entityDailyDestinations() -> some View {
        modifier(EntityDailyDestinations())
    }
}
