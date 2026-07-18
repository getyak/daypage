import SwiftUI
import DayPageServices

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

/// Pushes a MemoDetailView with the card-zoom hero transition. A distinct type
/// from a bare `Memo.ID` (UUID) push so Today can register both: `UUID` for
/// plain memo pushes (DailyPage chips) and `ZoomedMemoRef` for the card-body tap
/// that animates out of the tapped card. W1 unifies this onto the path (it was
/// an `isPresented`-driven push, which collapsed two levels when combined with
/// the path-driven entity pushes on the same stack).
struct ZoomedMemoRef: Hashable {
    let id: UUID
}

/// Pushes a MemoDetailView from inside an embedded DailyPageView, looked up in
/// the daily page's OWN `memoVM`. A distinct wrapper (not bare `Memo.ID`/UUID)
/// is REQUIRED: an embedded DailyPage registers its memo destination on the host
/// stack, and if it used bare UUID it would collide with TodayView's
/// `navigationDestination(for: UUID.self)` — SwiftUI resolves duplicate
/// same-type destinations to the one nearest the root, so the host's builder
/// (wrong memos array) would service the tap and the memo would appear missing.
struct DailyMemoRef: Hashable {
    let id: UUID
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

    init() {}

    private static func initialTab() -> AppTab {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-selectedTab"),
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
