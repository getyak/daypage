import SwiftUI
import DayPageModels
import DayPageStorage
import DayPageServices

// MARK: - ArchiveMode

enum ArchiveMode {
    case calendar
    case list
}

// MARK: - MonthlySummaryFilter

enum MonthlySummaryFilter: String, CaseIterable {
    case all = "all"
    case hasLocation = "hasLocation"
    case hasPhoto = "hasPhoto"

    var localizedLabel: String {
        switch self {
        case .all:         return L10n.Archive.filterAll
        case .hasLocation: return L10n.Archive.filterHasLocation
        case .hasPhoto:    return L10n.Archive.filterHasPhoto
        }
    }
}

// MARK: - DayStats

/// 存档中单日统计信息。
struct DayStats: Sendable {
    let dateString: String
    let memoCount: Int
    let photoCount: Int
    let voiceSeconds: Int
    let uniqueLocations: Int
    let isDailyPageCompiled: Bool
    let dailySummary: String?

    var voiceMinutes: Int { voiceSeconds / 60 }
    var densityLevel: DensityLevel {
        switch memoCount {
        case 0:    return .empty
        case 1...3: return .low
        case 4...7: return .medium
        default:   return .high
        }
    }

    enum DensityLevel {
        case empty, low, medium, high

        var fillColor: Color {
            // Unified onto the heat-map ramp (the carefully-tuned warm hex
            // stops the sidebar already uses) so the SAME busy day reads the
            // same colour in the sidebar heat-map and the archive calendar.
            // Was the parallel `densityNone/Low/Mid/High` single-hue-opacity
            // ramp — two ramps meant one busy day rendered two different browns.
            switch self {
            case .empty:  return DSColor.heatmapEmpty
            case .low:    return DSColor.heatmapLow
            case .medium: return DSColor.heatmapMid
            case .high:   return DSColor.heatmapHigh
            }
        }

        var textColor: Color {
            switch self {
            // `.medium` now fills with `heatmapMid` (#C9A677 in light) — a light
            // tan, NOT the old saturated `densityMid` amber. Near-white `onAmber`
            // over that tan drops to ~2:1, below AA, so `.medium` joins the
            // dark-ink group; only `.high` (heatmapHigh #5D3000 deep-brown) is
            // dark enough to carry the near-white foreground.
            case .empty, .low, .medium: return DSColor.inkPrimary
            case .high: return DSColor.onAmber
            }
        }

        var label: String {
            switch self {
            case .empty: return L10n.Archive.densityEmpty
            case .low: return L10n.Archive.densityLow
            case .medium: return L10n.Archive.densityMedium
            case .high: return L10n.Archive.densityHigh
            }
        }

        /// Right-corner dot color — amber accent on today cell, text color otherwise.
        func dotColor(isToday: Bool) -> Color {
            // Today cell fill is amber-accent; use onAmber so the dot stays
            // legible without hardcoded white.
            isToday ? DSColor.onAmber : textColor
        }
    }
}

/// Immutable input for one background scan; no global Vault lookup during I/O.
struct ArchiveMonthRequest: Sendable {
    let vaultRoot: URL
    let year: Int
    let month: Int
    let calendar: Calendar
}

/// All Archive surfaces are derived from the same root and scan.
struct ArchiveMonthSnapshot: Sendable {
    let dayStats: [String: DayStats]
    let rawDates: Set<String>
    let dailyDates: Set<String>
    let dayTeasers: [String: String]
}

// MARK: - ArchiveViewModel

@MainActor
final class ArchiveViewModel: ObservableObject {

    @Published var currentYear: Int
    @Published var currentMonth: Int
    @Published var dayStats: [String: DayStats] = [:] {  // keyed by "yyyy-MM-dd"
        // Rebuild the derived list-mode collections once per dayStats change,
        // instead of recomputing filter+sort+regroup on every SwiftUI body pass.
        // `sortedDays`/`groupedByMonth` were computed vars read inside the
        // LazyVStack AND re-read on every scroll frame (scroll-offset preference)
        // AND re-run on every unrelated @Published mutation (e.g. isLoading) —
        // the source of the acknowledged "1-2s first-scroll freeze".
        didSet { rebuildDerivedDays() }
    }

    /// Cached, list-mode day collections derived from `dayStats`. Recomputed
    /// only in `rebuildDerivedDays()` (via `dayStats.didSet`).
    @Published private(set) var sortedDays: [DayStats] = []
    @Published private(set) var groupedByMonth: [(monthKey: String, days: [DayStats])] = []

    private func rebuildDerivedDays() {
        let sorted = dayStats.values
            .filter { $0.memoCount > 0 || $0.isDailyPageCompiled }
            .sorted { $0.dateString > $1.dateString }
        sortedDays = sorted

        var groups: [String: [DayStats]] = [:]
        for stats in sorted {
            let monthKey = String(stats.dateString.prefix(7))
            groups[monthKey, default: []].append(stats)
        }
        groupedByMonth = groups
            .map { (monthKey: $0.key, days: $0.value) }
            .sorted { $0.monthKey > $1.monthKey }
    }
    @Published var isLoading: Bool = false

    @Published private(set) var rawDates: Set<String> = []
    @Published private(set) var dailyDates: Set<String> = []
    @Published private(set) var dayTeasers: [String: String] = [:]

    // Kept readable internally so tests can await a retired request explicitly.
    private(set) var loadMonthTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var isActive = false
    private var vaultIsDirty = true
    private let vaultRootProvider: () -> URL
    private let calendarProvider: () -> Calendar
    private let loader: @Sendable (ArchiveMonthRequest) async throws -> ArchiveMonthSnapshot

    private struct CacheKey: Hashable {
        let root: URL
        let year: Int
        let month: Int
        let calendar: Calendar
    }
    private var monthCache: [CacheKey: ArchiveMonthSnapshot] = [:]
    private var publishedKey: CacheKey?

    init(
        vaultRootProvider: @escaping () -> URL = { VaultInitializer.vaultURL },
        calendarProvider: @escaping () -> Calendar = {
            var calendar = Calendar.current
            calendar.timeZone = StorageSettings.currentTimeZone()
            return calendar
        },
        loader: @escaping @Sendable (ArchiveMonthRequest) async throws -> ArchiveMonthSnapshot = {
            try await ArchiveVaultScan.load($0)
        }
    ) {
        self.vaultRootProvider = vaultRootProvider
        self.calendarProvider = calendarProvider
        self.loader = loader
        let calendar = calendarProvider()
        let now = calendar.dateComponents([.year, .month], from: Date())
        currentYear = now.year ?? calendar.component(.year, from: Date())
        currentMonth = now.month ?? calendar.component(.month, from: Date())
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            // A persistent tab may have missed changes while hidden.
            invalidateVault()
        } else {
            retireCurrentLoad()
            vaultIsDirty = true
            isLoading = false
        }
    }

    func invalidateVault() {
        vaultIsDirty = true
        monthCache.removeAll()
        if isActive { loadMonth() }
    }

    func waitForCurrentLoad() async {
        await loadMonthTask?.value
    }

    private func retireCurrentLoad() {
        generation &+= 1
        loadMonthTask?.cancel()
        loadMonthTask = nil
    }

    private func publish(_ snapshot: ArchiveMonthSnapshot, for key: CacheKey) {
        publishedKey = key
        rawDates = snapshot.rawDates
        dailyDates = snapshot.dailyDates
        dayTeasers = snapshot.dayTeasers
        dayStats = snapshot.dayStats
    }

    var currentMonthTitle: String {
        let calendar = calendarProvider()
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMMM yyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        var comps = DateComponents()
        comps.year = currentYear
        comps.month = currentMonth
        comps.day = 1
        guard let date = calendar.date(from: comps) else { return "" }
        return formatter.string(from: date).uppercased()
    }

    func goToPreviousMonth() {
        var comps = DateComponents()
        comps.year = currentYear
        comps.month = currentMonth - 1
        comps.day = 1
        if let date = calendarProvider().date(from: comps) {
            let c = calendarProvider().dateComponents([.year, .month], from: date)
            currentYear = c.year ?? currentYear
            currentMonth = c.month ?? currentMonth
        }
        loadMonth()
    }

    func goToNextMonth() {
        var comps = DateComponents()
        comps.year = currentYear
        comps.month = currentMonth + 1
        comps.day = 1
        if let date = calendarProvider().date(from: comps) {
            let c = calendarProvider().dateComponents([.year, .month], from: date)
            currentYear = c.year ?? currentYear
            currentMonth = c.month ?? currentMonth
        }
        loadMonth()
    }

    func loadMonth() {
        // Retire even when serving cache: a cancelled loader may still return.
        retireCurrentLoad()
        guard isActive else {
            vaultIsDirty = true
            return
        }
        let request = ArchiveMonthRequest(
            vaultRoot: vaultRootProvider().standardizedFileURL,
            year: currentYear,
            month: currentMonth,
            calendar: calendarProvider()
        )
        let key = CacheKey(root: request.vaultRoot, year: request.year,
                           month: request.month, calendar: request.calendar)
        let token = generation
        if publishedKey != key {
            // Last-good data belongs to its root/month/calendar. A failed new
            // context must not leave the previous context under its new title.
            publishedKey = nil
            rawDates = []
            dailyDates = []
            dayTeasers = [:]
            dayStats = [:]
        }
        if !vaultIsDirty, let cached = monthCache[key] {
            publish(cached, for: key)
            isLoading = false
            return
        }
        isLoading = true
        let loader = loader
        loadMonthTask = Task { [weak self] in
            let result: Result<ArchiveMonthSnapshot, Error>
            do { result = .success(try await loader(request)) }
            catch { result = .failure(error) }
            // This check and every mutation share one MainActor turn. A late
            // request cannot publish, cache, or finish a newer request's spinner.
            guard let self, !Task.isCancelled,
                  self.isActive, self.generation == token,
                  self.currentYear == request.year, self.currentMonth == request.month else { return }
            guard self.vaultRootProvider().standardizedFileURL == request.vaultRoot,
                  self.calendarProvider() == request.calendar else {
                // Only the current generation may follow a context change that
                // arrived without an explicit invalidation; don't strand loading.
                self.loadMonth()
                return
            }
            if case .success(let snapshot) = result {
                self.monthCache[key] = snapshot
                self.vaultIsDirty = false
                self.publish(snapshot, for: key)
            }
            // Same-context failures retain last-good data and are never cached.
            self.isLoading = false
        }
    }

    // MARK: Monthly Aggregates

    var totalEntries: Int { dayStats.values.reduce(0) { $0 + $1.memoCount } }

    var totalPhotos: Int { dayStats.values.reduce(0) { $0 + $1.photoCount } }
    var totalVoiceMinutes: Int { dayStats.values.reduce(0) { $0 + $1.voiceMinutes } }
    var totalLocations: Int { dayStats.values.reduce(0) { $0 + $1.uniqueLocations } }

    /// Number of days this month with at least one memo or a compiled page —
    /// the "how many days did I actually log?" metric. Mirrors `sortedDays`'s
    /// filter so the digest strip count always matches the rows below it.
    var activeDayCount: Int {
        dayStats.values.filter { $0.memoCount > 0 || $0.isDailyPageCompiled }.count
    }

    // MARK: Calendar Helpers

    func daysInCurrentMonth() -> [Int?] {
        let total = numberOfDays(year: currentYear, month: currentMonth)
        let firstWeekday = firstWeekdayOfMonth(year: currentYear, month: currentMonth)
        // 周一开头：偏移量（周一=0, 周二=1..周日=6）
        let offset = (firstWeekday + 5) % 7   // 将周日=1..周六=7 转换为周一=0..周日=6
        var cells: [Int?] = Array(repeating: nil, count: offset)
        cells += (1...total).map { Optional($0) }
        // 填充至 7 的倍数
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }

    func dateString(day: Int) -> String {
        String(format: "%04d-%02d-%02d", currentYear, currentMonth, day)
    }

    var isCurrentMonthAndYear: Bool {
        let now = calendarProvider().dateComponents([.year, .month], from: Date())
        return now.year == currentYear && now.month == currentMonth
    }

    var isViewingCurrentMonth: Bool { isCurrentMonthAndYear }

    func goToCurrentMonth() {
        let now = calendarProvider().dateComponents([.year, .month], from: Date())
        currentYear = now.year ?? currentYear
        currentMonth = now.month ?? currentMonth
        loadMonth()
    }

    /// Jump directly to an arbitrary year/month (driven by the YearMonthPicker).
    /// No-ops when the target equals the current month so the picker doesn't
    /// trigger a redundant reload + transition.
    func goToMonth(year: Int, month: Int) {
        guard year != currentYear || month != currentMonth else { return }
        currentYear = year
        currentMonth = month
        loadMonth()
    }

    var today: Int {
        calendarProvider().component(.day, from: Date())
    }

    // MARK: Sorted Days / Grouped By Month
    //
    // These are now cached stored properties (see `sortedDays` /
    // `groupedByMonth` @Published declarations above, rebuilt in
    // `rebuildDerivedDays()` via `dayStats.didSet`). They were computed vars —
    // filter+sort, then bucket-by-"yyyy-MM"+sort — read inside the LazyVStack
    // and re-evaluated on every scroll frame and every unrelated @Published
    // change, which is what caused the 1-2s first-scroll freeze (Issue #13).

    // MARK: Monthly Filter

    func filteredDays(filter: MonthlySummaryFilter) -> [DayStats] {
        switch filter {
        case .all:
            return sortedDays
        case .hasLocation:
            return sortedDays.filter { $0.uniqueLocations > 0 }
        case .hasPhoto:
            return sortedDays.filter { $0.photoCount > 0 }
        }
    }

    // MARK: Export

    func generateMarkdownExport(filter: MonthlySummaryFilter) -> String {
        let days = filteredDays(filter: filter)
        var lines: [String] = []
        lines.append("# " + String(format: NSLocalizedString("archive.export.md.title", comment: "Markdown export H1: %@ = month title"), currentMonthTitle))
        lines.append("")
        lines.append(String(format: NSLocalizedString("archive.export.md.entries", comment: "Markdown export bullet: total entry count"), totalEntries))
        lines.append(String(format: NSLocalizedString("archive.export.md.photos", comment: "Markdown export bullet: photo count"), totalPhotos))
        lines.append(String(format: NSLocalizedString("archive.export.md.voice", comment: "Markdown export bullet: voice minutes"), totalVoiceMinutes))
        lines.append(String(format: NSLocalizedString("archive.export.md.locations", comment: "Markdown export bullet: location count"), totalLocations))
        lines.append("")
        if filter != .all {
            lines.append(String(format: NSLocalizedString("archive.export.md.filter", comment: "Markdown export blockquote: active filter name"), filter.localizedLabel))
            lines.append("")
        }
        lines.append("---")
        lines.append("")
        for stats in days {
            lines.append("## \(stats.dateString)")
            if let summary = stats.dailySummary, !summary.isEmpty {
                lines.append("")
                lines.append(summary)
            }
            lines.append("")
            lines.append(String(
                format: NSLocalizedString("archive.export.md.dayline", comment: "Markdown export per-day stats: memos, photos, voice minutes, locations"),
                stats.memoCount, stats.photoCount, stats.voiceMinutes, stats.uniqueLocations
            ))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Private Helpers

    private func numberOfDays(year: Int, month: Int) -> Int {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        guard let date = calendarProvider().date(from: comps),
              let range = calendarProvider().range(of: .day, in: .month, for: date) else { return 30 }
        return range.count
    }

    private func firstWeekdayOfMonth(year: Int, month: Int) -> Int {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = 1
        guard let date = calendarProvider().date(from: comps) else { return 1 }
        return calendarProvider().component(.weekday, from: date)
    }
}

// MARK: - ArchiveView

struct ArchiveView: View {

    let isActive: Bool

    @EnvironmentObject private var nav: AppNavigationModel
    @StateObject private var viewModel = ArchiveViewModel()
    @State private var mode: ArchiveMode = .calendar
    /// The historical day pushed onto Archive's NavigationStack as a
    /// DayDetailView. Replaces the former `selectedDateString` + `showDayDetail`
    /// bool that drove a `fullScreenCover`; pushing gives the day a system back
    /// button + interactive edge-swipe-to-pop and a zoom hero (iOS 18+) out of
    /// the tapped calendar cell / list row. W1: now pushed via
    /// `nav.push(DayNavTarget…)` onto `archivePath` (path-unified with entity/
    /// daily pushes) instead of a local `@State selectedDay` + isPresented.
    /// Shared zoom namespace so the tapped calendar cell / list row is the
    /// `matchedTransitionSource` for the pushed DayDetailView.
    @Namespace private var dayZoomNamespace
    @State private var showSearch: Bool = false
    /// Pre-filled query passed into SearchView when opened via deep link
    /// (`daypage://search?q=…` from `AskTodayIntent`). Cleared after consume
    /// so re-triggering the same shortcut re-fires the navigation.
    @State private var searchInitialQuery: String? = nil
    @State private var summaryFilter: MonthlySummaryFilter = .all
    private struct ExportedFile: Identifiable {
        let id = UUID()
        let url: URL
    }
    @State private var exportedFile: ExportedFile?
    @State private var monthNavDirection: Edge = .leading
    @State private var todayPulse: Bool = false
    @State private var hasActivated: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    // MARK: - List mode scroll-to-top
    @State private var shouldShowListScrollToTop: Bool = false
    @State private var listScrollProxy: ScrollViewProxy? = nil

    /// Issue #302: monthly summary → share-card sheet.
    @State private var sharePayload: SharePayload? = nil
    @Environment(\.colorScheme) private var colorScheme

    /// Controls the year/month jump picker overlay (opened by tapping the
    /// Archive header's month title).
    @State private var showMonthPicker: Bool = false

    /// "yyyy-MM" set of months that hold at least one entry, derived from the
    /// pre-scanned raw/daily date sets. Drives the activity dots in the picker
    /// at zero extra disk cost.
    private var monthsWithEntries: Set<String> {
        var months = Set<String>()
        for dateStr in viewModel.rawDates.union(viewModel.dailyDates) where dateStr.count == 10 {
            months.insert(String(dateStr.prefix(7)))  // "yyyy-MM-dd" → "yyyy-MM"
        }
        return months
    }

    var body: some View {
        NavigationStack(path: $nav.archivePath) {
            ZStack {
                AmbientBackground().ignoresSafeArea()
                VStack(spacing: 0) {
                    archiveHeader

                    ScrollViewReader { proxy in
                    ScrollView {
                        GeometryReader { geo in
                            Color.clear
                                .preference(
                                    key: ArchiveListScrollOffsetKey.self,
                                    value: mode == .list
                                        ? geo.frame(in: .named("archiveListScroll")).minY
                                        : 0
                                )
                        }
                        .frame(height: 0)

                        VStack(spacing: 0) {
                            // #827 IA convergence: the whole-vault overview
                            // strip moved to SearchView's starter state —
                            // in Archive it was a third stats voice
                            // shouting over the month summary (FINDING-008
                            // was exactly this scope collision). Calendar
                            // mode now reads: month nav → calendar (legend
                            // in its footer) → single month summary.
                            monthNavigationRow
                                .padding(.horizontal, DSSpacing.xl)
                                .padding(.vertical, DSSpacing.lg)

                            if viewModel.isLoading {
                                HStack {
                                    Spacer()
                                    VStack(spacing: DSSpacing.sm) {
                                        ProgressView()
                                            .tint(DSColor.accentOnBg)
                                        Text(NSLocalizedString("archive.loading_month", comment: ""))
                                            .font(DSType.mono9)
                                            .foregroundColor(DSColor.inkMuted)
                                            .tracking(1.0)
                                            .textCase(.uppercase)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 48)
                                .transition(.opacity)
                            } else if mode == .calendar {
                                calendarGrid
                                    .padding(.horizontal, DSSpacing.md)
                                    .id("\(viewModel.currentYear)-\(viewModel.currentMonth)")
                                    .transition(
                                        .asymmetric(
                                            insertion: .move(edge: monthNavDirection).combined(with: .opacity),
                                            removal: .move(edge: monthNavDirection == .trailing ? .leading : .trailing).combined(with: .opacity)
                                        )
                                    )
                                    .gesture(
                                        DragGesture(minimumDistance: DSGesture.pagerMinimumDistance)
                                            .onEnded { value in
                                                let w = value.translation.width
                                                let h = value.translation.height
                                                guard abs(w) > abs(h) * DSGesture.horizontalDominance,
                                                      abs(w) > DSGesture.monthSwipeCommitDistance else { return }
                                                if w < 0 {
                                                    monthNavDirection = .trailing
                                                    withAnimation(Motion.spring) { viewModel.goToNextMonth() }
                                                } else {
                                                    monthNavDirection = .leading
                                                    withAnimation(Motion.spring) { viewModel.goToPreviousMonth() }
                                                }
                                                Haptics.rigid(intensity: 0.4)
                                                UIAccessibility.post(notification: .announcement, argument: viewModel.currentMonthTitle)
                                            }
                                    )

                                if viewModel.totalEntries == 0 {
                                    // #827: an all-empty month used to render
                                    // as a mute grid of gray cells with no
                                    // explanation — the only screen in the
                                    // app without an empty state.
                                    emptyMonthHint
                                        .padding(.horizontal, DSSpacing.xl)
                                        .padding(.top, 32)
                                        .padding(.bottom, 40)
                                } else {
                                    monthlySummary
                                        .padding(.horizontal, DSSpacing.xl)
                                        .padding(.top, 32)
                                        .padding(.bottom, 40)
                                }
                            } else {
                                listContent
                                    .padding(.horizontal, DSSpacing.xl)
                                    .padding(.bottom, 40)
                            }
                        }
                    }
                    .coordinateSpace(name: "archiveListScroll")
                    .onPreferenceChange(ArchiveListScrollOffsetKey.self) { value in
                        let shouldShow = value < -240
                        if shouldShow != shouldShowListScrollToTop {
                            shouldShowListScrollToTop = shouldShow
                        }
                    }
                    .onAppear { listScrollProxy = proxy }
                    .overlay(alignment: .bottomTrailing) {
                        if mode == .list && shouldShowListScrollToTop && !viewModel.sortedDays.isEmpty {
                            Button {
                                Haptics.soft()
                                withAnimation(reduceMotion ? nil : Motion.spring) {
                                    listScrollProxy?.scrollTo("archiveListTop", anchor: .top)
                                }
                            } label: {
                                Image(systemName: "chevron.up")
                                    .font(DSType.bodySM)
                                    .foregroundColor(DSColor.inkMuted)
                                    .frame(width: 28, height: 28)
                                    // #771: scroll-to-top button → glass engine (.control).
                                    .dpGlass(.control, in: Circle())
                                    .clipShape(Circle())
                            }
                            .padding(.trailing, DSSpacing.xl)
                            .padding(.bottom, DSSpacing.xl)
                            .transition(.opacity.combined(with: .scale(scale: 0.8)))
                            .accessibilityLabel(NSLocalizedString("archive.scroll_to_top", comment: "Scroll to top of archive list"))
                            .accessibilityIdentifier("archive-scroll-to-top-button")
                        }
                    }
                    .animation(reduceMotion ? nil : Motion.rise, value: mode == .list && shouldShowListScrollToTop)
                    } // end ScrollViewReader
                }
            }
            .navigationBarHidden(true)
            // US-030 note: the left-edge open-sidebar swipe lives ONLY in
            // RootView's edge strip (1:1 finger tracking) — see TodayView for
            // why the fire-on-release duplicate was removed.
            .onChange(of: nav.pendingArchiveDate) { _ in
                consumePendingArchiveDate()
            }
            .onChange(of: nav.pendingSearchQuery) { _ in
                consumePendingSearchQuery()
            }
            // W1 unification: DayDetail is now a PATH push (`DayNavTarget` on
            // `nav.archivePath`), not `isPresented`. Mixing an isPresented push
            // with the path-driven EntityRef/DailyRef pushes on the same stack
            // made a single back-gesture collapse two levels (DayDetail skipped,
            // straight to Archive). One push mechanism = correct per-level pop.
            .navigationDestination(for: DayNavTarget.self) { target in
                DayDetailView(dateString: target.dateString)
                    .modifier(ArchiveDayZoomDestination(
                        id: target.dateString, namespace: dayZoomNamespace
                    ))
                    // W0: Archive's stack also hides its nav bar (:670), so the
                    // pushed day needs the pop gesture re-armed.
                    .restoresInteractivePop()
            }
            // W1: shared entity + daily push destinations on Archive's stack.
            .entityDailyDestinations()
            .navigationDestination(for: MemoDetailRef.self) { ref in
                MemoDetailHost(reference: ref)
                    .restoresInteractivePop()
            }
            // W1 fix: WeeklyRecap now pushes via the path too (was a closure
            // NavigationLink). Re-arm the pop gesture like every other pushed
            // page on this bar-hidden stack.
            .navigationDestination(for: WeeklyRecapRef.self) { ref in
                WeeklyRecapDetailView(referenceDate: ref.referenceDate)
                    .restoresInteractivePop()
            }
            // The edge-strip `activeStackCanPop` signal is now driven purely by
            // `archivePath` being non-empty (see AppNavigationModel) — no manual
            // per-tab flag needed once every push runs through the path.
            .sheet(isPresented: $showSearch) {
                SearchView(
                    onSelect: { dateStr in
                        // Close the search sheet, then push the day once it has
                        // dismissed. A push while the sheet is still animating
                        // out gets swallowed, so defer by one runloop hop — much
                        // shorter than the old 0.25s cover-vs-sheet workaround.
                        showSearch = false
                        DispatchQueue.main.async {
                            nav.push(DayNavTarget(dateString: dateStr), in: .archive)
                        }
                    },
                    initialQuery: searchInitialQuery,
                    onSelectMemo: { memoID, dateString in
                        // Search already knows the owning raw day key — carry
                        // it through instead of re-deriving a Date under the
                        // mutable preferred zone.
                        guard let ref = MemoDetailRef(
                            id: memoID, dayString: dateString, source: .archive
                        ) else { return }
                        showSearch = false
                        DispatchQueue.main.async {
                            nav.push(ref, in: .archive)
                        }
                    }
                )
            }
            // Year/month jump picker — custom overlay (scrim + card) so it
            // floats lightly over the calendar with the app's Motion curves.
            .overlay {
                if showMonthPicker {
                    YearMonthPicker(
                        selectedYear: viewModel.currentYear,
                        selectedMonth: viewModel.currentMonth,
                        monthsWithEntries: monthsWithEntries,
                        onSelect: { year, month in
                            let isBackward = (year, month) < (viewModel.currentYear, viewModel.currentMonth)
                            monthNavDirection = isBackward ? .leading : .trailing
                            withAnimation(reduceMotion ? nil : Motion.spring) {
                                viewModel.goToMonth(year: year, month: month)
                            }
                            withAnimation(reduceMotion ? nil : Motion.fade) { showMonthPicker = false }
                            UIAccessibility.post(notification: .announcement, argument: viewModel.currentMonthTitle)
                        },
                        onClose: {
                            withAnimation(reduceMotion ? nil : Motion.fade) { showMonthPicker = false }
                        }
                    )
                    .transition(.opacity)
                    .zIndex(60)
                }
            }
        }
        .task(id: isActive) {
            viewModel.setActive(isActive)
            if isActive { activateIfNeeded() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .rawStorageDidWrite).receive(on: RunLoop.main)) { _ in
            viewModel.invalidateVault()
        }
        .onReceive(NotificationCenter.default.publisher(for: .vaultConflictResolved).receive(on: RunLoop.main)) { _ in
            viewModel.invalidateVault()
        }
        .onReceive(NotificationCenter.default.publisher(for: .compileSucceededForeground).receive(on: RunLoop.main)) { _ in
            viewModel.invalidateVault()
        }
        .onReceive(NotificationCenter.default.publisher(for: .compilationDidEnd).receive(on: RunLoop.main)) { _ in
            viewModel.invalidateVault()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { viewModel.invalidateVault() }
        }
    }

    // MARK: - Navigation Helper

    /// Persistent tab hosts keep Archive alive to preserve navigation and
    /// month state. Data activation belongs to the outer task; this helper
    /// only consumes navigation and runs one-time presentation effects.
    private func activateIfNeeded() {
        guard isActive else { return }
        consumePendingArchiveDate()
        consumePendingSearchQuery()
        guard !hasActivated else { return }
        hasActivated = true
        #if DEBUG
        // Reach the real Archive-owned search sheet in screenshot/E2E runs
        // without synthesising a fragile coordinate tap. An optional seeded
        // query exercises the exact same SearchView debounce and index path.
        let qaArgs = ProcessInfo.processInfo.arguments
        if qaArgs.contains("-qaOpenSearch") {
            if let index = qaArgs.firstIndex(of: "-qaSearchQuery"),
               qaArgs.indices.contains(index + 1) {
                searchInitialQuery = qaArgs[index + 1]
            }
            DispatchQueue.main.async { showSearch = true }
        }
        #endif
        guard !reduceMotion else { return }
        withAnimation(Motion.breathing) { todayPulse = true }
    }

    /// 每个日历单元格均可点击（US-006）。DayDetailView 自身处理
    /// `.empty` / `.error` / `.rawOnly` / `.compiled` 等状态 — 参见 US-002。
    private func handleDateTap(dateStr: String) {
        Haptics.soft()
        nav.push(DayNavTarget(dateString: dateStr), in: .archive)
    }

    /// Consume any pending deep-link from the sidebar's Recent row. Cleared
    /// after consumption so re-tapping the same row in the drawer still
    /// triggers a new presentation.
    private func consumePendingArchiveDate() {
        guard isActive, let dateStr = nav.pendingArchiveDate else { return }
        nav.pendingArchiveDate = nil
        // Defer the push so SwiftUI commits the tab switch first; pushing during
        // the same runloop as the tab change can race and skip the animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            nav.push(DayNavTarget(dateString: dateStr), in: .archive)
        }
    }

    /// Consume a pending search query delivered via `daypage://search?q=…`
    /// (e.g. from `AskTodayIntent`). Mirrors `consumePendingArchiveDate` —
    /// clears the nav state immediately, then presents SearchView on the
    /// next runloop so the tab-switch animation commits first.
    private func consumePendingSearchQuery() {
        guard isActive, let q = nav.pendingSearchQuery else { return }
        nav.pendingSearchQuery = nil
        searchInitialQuery = q
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            showSearch = true
        }
    }

    // MARK: - Archive Header

    private var archiveHeader: some View {
        HStack(alignment: .center, spacing: DSSpacing.md) {
            // "Archive" title — opens the sidebar (tap), keeping the
            // primary navigation affordance the rest of the app uses.
            // (W1: the mono month subtitle moved down to the month row as a
            // serif headline — the header kept two voices for one job.)
            Button {
                nav.openSidebar()
            } label: {
                Text(NSLocalizedString("archive.title", comment: "Archive page title"))
                    .font(DSType.serifDisplay28)
                    .foregroundColor(DSColor.inkPrimary)
            }
            .buttonStyle(.plain)
            // Label = what it IS ("Archive" — the page identity the user sees),
            // hint = what it DOES (opens the sidebar). The old label override
            // erased the page title from the a11y tree entirely: VoiceOver
            // heard "Open sidebar" with no page context, and UI tests lost
            // their only "which page am I on" anchor.
            .accessibilityLabel(NSLocalizedString("archive.title", comment: "Archive page title"))
            .accessibilityHint(NSLocalizedString("a11y.nav.open.hint", comment: "Opens the sidebar navigation drawer"))
            .accessibilityIdentifier("sidebar-menu-button")
            .accessibilityAddTraits(.isHeader)

            Spacer()

            // CAL / LIST view-mode toggle — page-level chrome, so it lives in
            // the header instead of floating mid-content.
            HStack(spacing: 2) {
                toggleButton("CAL", isSelected: mode == .calendar) { mode = .calendar }
                toggleButton("LIST", isSelected: mode == .list) { mode = .list }
            }
            .padding(3)
            // #771: CAL/LIST view-mode toggle → glass engine (.pill).
            .dpGlass(.pill, in: Capsule())
            .clipShape(Capsule())

            Button(action: { showSearch = true }) {
                Image(systemName: "magnifyingglass")
                    .font(DSType.bodyMD)
                    .foregroundColor(DSColor.inkMuted)
                    .frame(width: 36, height: 36)
                    // #771: search button → glass engine (.control).
                    .dpGlass(.control, in: Circle())
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("archive.a11y.search.label", comment: "A11y label: search button in archive header"))
            .accessibilityHint(NSLocalizedString("archive.a11y.search.hint", comment: "A11y hint: search button in archive header"))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .padding(.horizontal, DSSpacing.xl)
        .padding(.top, DSSpacing.lg)
        .padding(.bottom, DSSpacing.md)
        // Page title + CAL/LIST + search are persistent navigation chrome.
        // Capping this one row prevents AX4–AX5 from turning the three-letter
        // mode labels into vertical stacks that displace the search action.
        .dynamicTypeSize(.xSmall ... .large)
    }

    // MARK: - Month Navigation Row

    /// Issue #7 (2026-07-03): whole-vault overview strip above the month
    /// navigation. Two mono stat pillars ("N 条记录 · N 天" style) + a
    /// hairline. Reads TimelineIndex synchronously — the index is already
    /// warmed by DayPageApp at launch, so this is O(1) once ready. Before
    /// warm-up we show em-dashes rather than "0" so the user can tell
    /// "index is still loading" from "vault is really empty".
    /// #827: quiet empty state for an all-empty month — replaces the month
    /// summary (a grid of zeros would be noise, not information).
    private var emptyMonthHint: some View {
        VStack(spacing: DSSpacing.sm) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 22, weight: .light))
                .foregroundColor(DSColor.inkFaint)
            Text(NSLocalizedString("archive.month.empty", comment: "Empty month hint"))
                .font(DSType.bodySM)
                .foregroundColor(DSColor.inkMuted)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// Localized "July 2026" headline for the month row (the export/a11y
    /// string keeps using the archival en_US_POSIX `currentMonthTitle`).
    private var localizedMonthTitle: String {
        var comps = DateComponents()
        comps.year = viewModel.currentYear
        comps.month = viewModel.currentMonth
        comps.day = 1
        guard let date = Calendar.current.date(from: comps) else { return viewModel.currentMonthTitle }
        return Self.monthHeaderFormatter.string(from: date)
    }

    /// One quiet mono line under the headline: "N days · M entries", plus an
    /// inline "back to this month" affordance when browsing history — always
    /// present, so its appearance never reflows the row (the old floating
    /// TODAY capsule made the whole bar jump).
    private var monthMetaLine: some View {
        let days = viewModel.activeDayCount
        let entries = viewModel.totalEntries
        // Narrative line → per-count plural keys ("1 day · 2 entries"); a
        // single "%d days" format would ship the very "1 days" bug this
        // branch fixes elsewhere.
        let dayPart = String(format: NSLocalizedString(
            days == 1 ? "archive.month.meta.days.one" : "archive.month.meta.days",
            comment: "Month meta line day part"), days)
        let entryPart = String(format: NSLocalizedString(
            entries == 1 ? "archive.month.meta.entries.one" : "archive.month.meta.entries",
            comment: "Month meta line entry part"), entries)
        return HStack(spacing: DSSpacing.sm) {
            Text("\(dayPart) · \(entryPart)")
            .font(DSType.mono10)
            .tracking(0.8)
            .foregroundColor(DSColor.inkMuted)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)

            if !viewModel.isViewingCurrentMonth {
                Button(action: {
                    Haptics.tapConfirm()
                    let now = Calendar.current.dateComponents([.year, .month], from: Date())
                    let targetYear = now.year ?? viewModel.currentYear
                    let targetMonth = now.month ?? viewModel.currentMonth
                    let isFuture = (viewModel.currentYear, viewModel.currentMonth) > (targetYear, targetMonth)
                    monthNavDirection = isFuture ? .leading : .trailing
                    withAnimation(reduceMotion ? nil : Motion.spring) { viewModel.goToCurrentMonth() }
                    UIAccessibility.post(notification: .announcement, argument: viewModel.currentMonthTitle)
                }) {
                    Text(NSLocalizedString("archive.today", comment: "Today button"))
                        .font(DSType.mono10)
                        .tracking(0.8)
                        .foregroundColor(DSColor.accentOnBg)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("archive.a11y.currentMonth.label", comment: "A11y label: back-to-current-month button"))
                .accessibilityHint(NSLocalizedString("archive.a11y.currentMonth.hint", comment: "A11y hint: back-to-current-month button"))
                .transition(.opacity)
            }
        }
        .dynamicTypeSize(.xSmall ... .xxLarge)
    }

    private var monthNavigationRow: some View {
        HStack(alignment: .center) {
            Button(action: {
                Haptics.rigid(intensity: 0.4)
                monthNavDirection = .leading
                withAnimation(Motion.spring) { viewModel.goToPreviousMonth() }
                UIAccessibility.post(notification: .announcement, argument: viewModel.currentMonthTitle)
            }) {
                Image(systemName: "chevron.left")
                    .font(DSType.bodySM)
                    .foregroundColor(DSColor.inkMuted)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("archive.a11y.prevMonth.label", comment: "A11y label: previous month button"))
            .accessibilityHint(NSLocalizedString("archive.a11y.prevMonth.hint", comment: "A11y hint: previous month button"))

            Spacer()

            // Serif month headline = the jump-to-month affordance (tap →
            // YearMonthPicker). The calendar's protagonist is the month, so
            // the month gets the display voice.
            VStack(spacing: 3) {
                Button {
                    Haptics.soft()
                    withAnimation(reduceMotion ? nil : Motion.fade) { showMonthPicker = true }
                } label: {
                    HStack(spacing: DSSpacing.xs) {
                        Text(localizedMonthTitle)
                            .font(DSFonts.serif(size: 22, weight: .semibold, relativeTo: .title2))
                            .foregroundColor(DSColor.inkPrimary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.78)
                            .dynamicTypeSize(.xSmall ... .xxxLarge)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(DSColor.inkMuted)
                            .padding(.top, 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(format: NSLocalizedString("archive.picker.open", comment: "Jump to month, current %@"), viewModel.currentMonthTitle))
                .accessibilityHint(NSLocalizedString("archive.picker.open.hint", comment: "Opens the month picker"))
                .accessibilityIdentifier("archive-month-picker-button")

                monthMetaLine
            }

            Spacer()

            Button(action: {
                Haptics.rigid(intensity: 0.4)
                monthNavDirection = .trailing
                withAnimation(Motion.spring) { viewModel.goToNextMonth() }
                UIAccessibility.post(notification: .announcement, argument: viewModel.currentMonthTitle)
            }) {
                Image(systemName: "chevron.right")
                    .font(DSType.bodySM)
                    .foregroundColor(DSColor.inkMuted)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("archive.a11y.nextMonth.label", comment: "A11y label: next month button"))
            .accessibilityHint(NSLocalizedString("archive.a11y.nextMonth.hint", comment: "A11y hint: next month button"))
        }
        .dynamicTypeSize(.xSmall ... .xxxLarge)
        .animation(reduceMotion ? nil : Motion.spring, value: viewModel.isViewingCurrentMonth)
    }

    private func toggleButton(_ label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            // Selection tick only when actually switching mode — tapping the
            // already-selected segment shouldn't fire feedback.
            if !isSelected { Haptics.selection() }
            action()
        } label: {
            Text(label)
                .monoLabelStyle(size: 10)
                // The inactive segment is still an available view switch,
                // not disabled chrome. Keep it quiet, but above the AA floor
                // used for small semantic labels on glass surfaces.
                .foregroundColor(isSelected ? DSColor.onAmber : DSColor.inkTertiaryAA)
                .padding(.horizontal, DSSpacing.md)
                .padding(.vertical, 6)
                .background(isSelected ? DSColor.amberDeep : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            label == "CAL"
                ? NSLocalizedString("archive.mode.calendar", comment: "Archive calendar view")
                : NSLocalizedString("archive.mode.list", comment: "Archive list view")
        )
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Calendar Grid

    /// Monday-first, locale-aware single-glyph weekday rail ("一 二 三…" in
    /// Chinese, "M T W…" in English). The old hardcoded MON–SUN row shouted
    /// over the day numbers it was only meant to caption.
    private static let weekdaySymbols: [String] = {
        let cal = Calendar.current
        let symbols = cal.veryShortStandaloneWeekdaySymbols  // [Sun, Mon, …]
        guard symbols.count == 7 else { return ["M", "T", "W", "T", "F", "S", "S"] }
        return (1...7).map { symbols[$0 % 7] }               // Monday-first
    }()
    private var weekdaySymbols: [String] { Self.weekdaySymbols }

    private var calendarGrid: some View {
        // 4pt gutters + 8pt inset: with the previous 1pt gaps the amber cell
        // fills fused with the amber-tinted glass panel into one flat salmon
        // slab — the density heatmap only reads when cells are discrete tiles.
        VStack(spacing: DSSpacing.xs) {
            // Weekday header row
            HStack(spacing: DSSpacing.xs) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, day in
                    Text(day)
                        .monoLabelStyle(size: 9)
                        .foregroundColor(DSColor.onSurfaceVariant)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                }
            }

            // Day cells
            let cells = viewModel.daysInCurrentMonth()
            let rows = cells.chunked(into: 7)
            ForEach(rows.indices, id: \.self) { rowIdx in
                HStack(spacing: DSSpacing.xs) {
                    ForEach(rows[rowIdx].indices, id: \.self) { colIdx in
                        let dayNum = rows[rowIdx][colIdx]
                        calendarCell(dayNum: dayNum)
                    }
                }
            }

            // #827: the density legend lives INSIDE the calendar panel as
            // its footer — it annotates the grid above it, so floating it
            // outside the glass surface made it read as a separate section.
            legendRow
                .padding(.horizontal, DSSpacing.xs)
                .padding(.top, 6)
        }
        .padding(DSSpacing.sm)
        // #771: month calendar grid → glass engine (.panel). Engine owns rim.
        .dpGlass(.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        // Calendar geometry must remain seven equal columns. Date glyphs and
        // the density legend are chrome with full VoiceOver labels, so cap
        // them before they inflate the grid beyond the viewport.
        .dynamicTypeSize(.xSmall ... .large)
    }

    /// 日历单元格的三态分类（US-006）。
    /// 基于预扫描的 `dailyDates` / `rawDates` 集合推导。
    private enum CellDataState {
        case compiled   // daily file exists → solid highlight
        case rawOnly    // only raw file exists → dot marker
        case none       // neither → 50% translucent gray, still tappable
    }

    private func cellState(for dateStr: String) -> CellDataState {
        if viewModel.dailyDates.contains(dateStr) { return .compiled }
        if viewModel.rawDates.contains(dateStr)   { return .rawOnly }
        return .none
    }

    @ViewBuilder
    private func calendarCell(dayNum: Int?) -> some View {
        if let day = dayNum {
            let dateStr = viewModel.dateString(day: day)
            let isToday = viewModel.isCurrentMonthAndYear && day == viewModel.today
            let data = cellState(for: dateStr)

            // Heatmap color from cached memo-count bucket; fall back to
            // pre-scanned file-existence state for days not yet loaded.
            // Empty days deliberately drop to a near-white whisper — with the
            // old densityNone fill the whole month fused with the amber glass
            // panel into one salmon slab and the ramp stopped reading.
            let density = viewModel.dayStats[dateStr]?.densityLevel
            let fillColor: Color = {
                if let d = density, d != .empty { return d.fillColor }
                switch data {
                case .compiled: return DSColor.amberDeep
                case .rawOnly:  return DSColor.heatmapLow
                case .none:     return DSColor.surfaceWhite.opacity(0.38)
                }
            }()

            let textColor: Color = {
                // A compiled-only day has `density == .empty` but still uses
                // the deep archival fill below. Let file state choose its
                // foreground in that case; dark ink on amberDeep was ~1.5:1.
                if let d = density, d != .empty { return d.textColor }
                switch data {
                // `compiled` cell fills with amberDeep — onAmber keeps the
                // foreground legible in both light and dark schemes.
                case .compiled: return DSColor.onAmber
                case .rawOnly:  return DSColor.inkPrimary
                // Every date is a tappable destination. `inkSubtle` is a
                // disabled/decorative token and fell below the small-text AA
                // floor on the warm glass tile; use the quiet semantic token.
                case .none:     return DSColor.inkTertiaryAA
                }
            }()

            // Match the raw-entry marker to the *actual* tile fill. Today can
            // be a low-density tan tile, where the old near-white dot nearly
            // disappeared; reserve onAmber for genuinely dark tiles.
            let usesDarkFill: Bool = {
                if let density, density != .empty { return density == .high }
                switch data {
                case .compiled: return true
                case .rawOnly, .none: return false
                }
            }()
            let dotColor: Color = usesDarkFill ? DSColor.onAmber : DSColor.accentOnBg

            Button(action: {
                Haptics.tapConfirm()
                handleDateTap(dateStr: dateStr)
            }) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: DSRadius.xs, style: .continuous)
                        .fill(fillColor)
                        .overlay(
                            RoundedRectangle(cornerRadius: DSRadius.xs, style: .continuous)
                                .stroke(isToday ? DSColor.amberAccent : DSColor.glassRim,
                                        lineWidth: isToday ? 1.5 : 0.5)
                        )

                    if isToday && !reduceMotion {
                        RoundedRectangle(cornerRadius: DSRadius.xs, style: .continuous)
                            .stroke(DSColor.amberAccent, lineWidth: 1.5)
                            .opacity(todayPulse ? 1.0 : 0.4)
                            .shadow(color: DSColor.amberAccent.opacity(todayPulse ? 0.6 : 0.2), radius: todayPulse ? 6 : 2)
                            .allowsHitTesting(false)
                    }

                    Text("\(day)")
                        .monoLabelStyle(size: 10)
                        .foregroundColor(textColor)
                        .padding(DSSpacing.xs)

                    if data == .rawOnly {
                        Circle()
                            .fill(dotColor)
                            .frame(width: 4, height: 4)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                            .padding(DSSpacing.xs)
                    }
                }
                .aspectRatio(1, contentMode: .fit)
            }
            .buttonStyle(CalendarCellButtonStyle())
            .modifier(ArchiveDayZoomSource(id: dateStr, namespace: dayZoomNamespace))
            .frame(maxWidth: .infinity)
            .accessibilityLabel(accessibilityLabel(dateStr: dateStr, state: data, stats: viewModel.dayStats[dateStr]))
            .accessibilityValue(viewModel.dayStats[dateStr]?.densityLevel.label ?? "")
            .accessibilityHint(NSLocalizedString("archive.a11y.day.hint", comment: "A11y hint: calendar day cell opens the day detail"))
        } else {
            RoundedRectangle(cornerRadius: DSRadius.xs, style: .continuous)
                .fill(Color.clear)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
        }
    }

    private func accessibilityLabel(dateStr: String, state: CellDataState, stats: DayStats?) -> String {
        let statePrefix: String
        switch state {
        case .compiled: statePrefix = NSLocalizedString("archive.a11y.day.compiled", comment: "A11y: day has a compiled daily page")
        case .rawOnly:  statePrefix = NSLocalizedString("archive.a11y.day.rawOnly", comment: "A11y: day has raw memos only")
        case .none:     return String(format: NSLocalizedString("archive.a11y.day.none", comment: "A11y: day with no entries; %@ = date"), dateStr)
        }
        guard let s = stats, s.memoCount > 0 else {
            return "\(dateStr)，\(statePrefix)"
        }
        let densityLabel: String
        switch s.densityLevel {
        case .empty:  densityLabel = NSLocalizedString("archive.a11y.density.empty", comment: "A11y density level: empty")
        case .low:    densityLabel = NSLocalizedString("archive.a11y.density.low", comment: "A11y density level: low")
        case .medium: densityLabel = NSLocalizedString("archive.a11y.density.medium", comment: "A11y density level: medium")
        case .high:   densityLabel = NSLocalizedString("archive.a11y.density.high", comment: "A11y density level: high")
        }
        var parts: [String] = [String(
            format: NSLocalizedString("archive.a11y.day.summary", comment: "A11y day summary: date, compile state, density, memo count"),
            dateStr, statePrefix, densityLabel, s.memoCount
        )]
        if s.photoCount > 0 { parts.append(String(format: NSLocalizedString("archive.a11y.day.photos", comment: "A11y: %d photos"), s.photoCount)) }
        if s.uniqueLocations > 0 { parts.append(String(format: NSLocalizedString("archive.a11y.day.locations", comment: "A11y: %d locations"), s.uniqueLocations)) }
        return parts.joined(separator: "，")
    }

    // MARK: - Heatmap Legend

    private var legendRow: some View {
        HStack(spacing: DSSpacing.sm) {
            // Narrative caption, not archival vocabulary → localized
            // (unlike the FINDING-010 mono ledger labels).
            Text(NSLocalizedString("archive.legend.density", comment: "Calendar legend caption: entry density"))
                .monoLabelStyle(size: 9)
                .foregroundColor(DSColor.inkMuted)

            // First swatch mirrors the quiet empty-cell fill, then the ramp.
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(DSColor.surfaceWhite.opacity(0.38))
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(DSColor.glassRim, lineWidth: 0.5))
                .frame(width: 10, height: 10)
            ForEach([DayStats.DensityLevel.low, .medium, .high], id: \.label) { level in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(level.fillColor)
                    .frame(width: 10, height: 10)
            }

            Spacer()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(NSLocalizedString("a11y.activity_legend", comment: "Activity legend"))
        .accessibilityValue(NSLocalizedString("a11y.activity_legend.value", comment: "Legend range"))
    }

    // MARK: - Monthly Summary

    private var monthlySummary: some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            // "This month" — a diary's month-end note, not a dashboard.
            // (W1: four 110pt shouting stat cards → one serif pillar row; the
            // export/share buttons fold into a quiet overflow menu.)
            HStack(alignment: .firstTextBaseline, spacing: DSSpacing.lg) {
                Text(NSLocalizedString("archive.summary.thisMonth", comment: "Monthly summary section title"))
                    .font(DSFonts.serif(size: 16, weight: .semibold, relativeTo: .headline))
                    .foregroundColor(DSColor.inkPrimary)
                Rectangle()
                    .fill(DSColor.inkFaint)
                    .frame(height: 0.5)
                Menu {
                    Button(action: exportMarkdown) {
                        Label(NSLocalizedString("archive.export.markdown", comment: "Button: export monthly summary as Markdown"), systemImage: "square.and.arrow.up")
                    }
                    Button {
                        Task { await shareScreenshot() }
                    } label: {
                        Label(NSLocalizedString("archive.export.screenshot", comment: "Button: share monthly summary as screenshot"), systemImage: "camera")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DSColor.inkMuted)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(NSLocalizedString("archive.summary.menu.a11y", comment: "A11y: monthly summary actions menu"))
            }

            HStack(alignment: .top, spacing: 0) {
                digestStat(value: "\(viewModel.totalEntries)",
                           label: NSLocalizedString("archive.stat.entries", comment: "Stat pillar label: entries"),
                           accent: true)
                if viewModel.totalPhotos > 0 {
                    digestDivider
                    digestStat(value: "\(viewModel.totalPhotos)",
                               label: NSLocalizedString("archive.stat.photos", comment: "Stat pillar label: photos"),
                               accent: false)
                }
                if viewModel.totalVoiceMinutes > 0 {
                    digestDivider
                    digestStat(value: "\(viewModel.totalVoiceMinutes)",
                               label: NSLocalizedString("archive.stat.voiceMin", comment: "Stat pillar label: voice minutes"),
                               accent: false)
                }
                if viewModel.totalLocations > 0 {
                    digestDivider
                    digestStat(value: "\(viewModel.totalLocations)",
                               label: NSLocalizedString("archive.stat.places", comment: "Stat pillar label: places"),
                               accent: false)
                }
            }

            // Filter chips
            HStack(spacing: DSSpacing.sm) {
                ForEach(MonthlySummaryFilter.allCases, id: \.rawValue) { filter in
                    filterChip(filter)
                }
                Spacer()
            }

            // Filtered day list (when not showing all, or always for quick browse)
            if summaryFilter != .all {
                let filtered = viewModel.filteredDays(filter: summaryFilter)
                if filtered.isEmpty {
                    Text(NSLocalizedString("archive.summary.noMatch", comment: "Monthly summary: no days match the active filter"))
                        .monoLabelStyle(size: 11)
                        .foregroundColor(DSColor.onSurfaceVariant)
                        .padding(.vertical, DSSpacing.sm)
                } else {
                    VStack(spacing: 6) {
                        ForEach(filtered, id: \.dateString) { stats in
                            Button(action: {
                                Haptics.tapConfirm()
                                handleDateTap(dateStr: stats.dateString)
                            }) {
                                HStack {
                                    Text(RelativeDate.label(for: stats.dateString, style: .caps))
                                        .monoLabelStyle(size: 11)
                                        .foregroundColor(DSColor.inkPrimary)
                                    Spacer()
                                    if stats.photoCount > 0 {
                                        Label("\(stats.photoCount)", systemImage: "photo")
                                            .monoLabelStyle(size: 10)
                                            .foregroundColor(DSColor.inkMuted)
                                    }
                                    if stats.uniqueLocations > 0 {
                                        Label("\(stats.uniqueLocations)", systemImage: "mappin")
                                            .monoLabelStyle(size: 10)
                                            .foregroundColor(DSColor.inkMuted)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .liquidGlassCard(cornerRadius: DSRadius.sm)
                            }
                            .buttonStyle(.plain)
                            .modifier(ArchiveDayZoomSource(id: stats.dateString, namespace: dayZoomNamespace))
                            .accessibilityLabel(RelativeDate.label(for: stats.dateString, style: .caps))
                            .accessibilityHint("Opens this day's entry")
                        }
                    }
                }
            }

        }
        .sheet(item: $exportedFile) { payload in
            ShareSheet(activityItems: [payload.url])
        }
        // Issue #302: card-style monthly share.
        .sheet(item: $sharePayload) { payload in
            ShareCardSheet(payload: payload)
        }
    }

    private func filterChip(_ filter: MonthlySummaryFilter) -> some View {
        let isSelected = summaryFilter == filter
        return Button(action: {
            Haptics.soft()
            withAnimation(Motion.spring) { summaryFilter = filter }
        }) {
            Text(filter.localizedLabel)
                .monoLabelStyle(size: 10)
                .foregroundColor(isSelected ? Color.white : DSColor.inkTertiaryAA)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isSelected ? DSColor.amberDeep : DSColor.glassLo, in: Capsule())
                .animation(Motion.spring, value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(filter.localizedLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func exportMarkdown() {
        let markdown = viewModel.generateMarkdownExport(filter: summaryFilter)
        let filename = "\(viewModel.currentMonthTitle.lowercased().replacingOccurrences(of: " ", with: "-"))-summary.md"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try markdown.write(to: tempURL, atomically: true, encoding: .utf8)
        } catch {
            DayPageLogger.shared.error("ArchiveView export: \(error)")
            return
        }
        // One immutable payload drives presentation and its initial items.
        exportedFile = ExportedFile(url: tempURL)
    }

    @MainActor
    private func shareScreenshot() async {
        // Issue #302: route through ShareCardSheet so users get the full template
        // gallery (Minimal × 4 + Polaroid × 4). The legacy PosterRenderer.swift
        // has been removed — its logic now lives in `MinimalMonthlyTemplate`.
        sharePayload = .monthly(
            MonthlySnapshot(
                monthTitle: viewModel.currentMonthTitle,
                totalEntries: viewModel.totalEntries,
                totalPhotos: viewModel.totalPhotos,
                totalVoiceMinutes: viewModel.totalVoiceMinutes,
                totalLocations: viewModel.totalLocations
            )
        )
    }

    // MARK: - List Content

    private var listContent: some View {
        // Issue #13 perf: month-grouped Sections let LazyVStack lay out only
        // the rows it actually needs (one bucket at a time), eliminating the
        // 1-2s freeze on the first scroll when a month has many populated
        // days. iOS 16 compatibility: do NOT use pinnedViews — sticky-header
        // behavior is inconsistent on 16.x; a plain header View is enough.
        LazyVStack(spacing: DSSpacing.sm, pinnedViews: []) {
            Color.clear.frame(height: 0).id("archiveListTop")

            if viewModel.sortedDays.isEmpty {
                EmptyStateView.archiveMonthEmpty {
                    nav.selectedTab = .today
                }
                .padding(.top, 40)
            } else {
                // R7 — Weekly Recap entry card, hoisted above the month digest.
                // Gated on `.weeklyRecap` flag + ≥3 compiled daily pages this
                // week so the entry doesn't tease an empty AI experience.
                weeklyRecapEntryCard
                    .padding(.bottom, DSSpacing.xs)

                // Compact monthly digest — list mode otherwise drops all the
                // month-level context that calendar mode shows in its summary
                // grid. (#archive-list-digest)
                monthDigestStrip
                    .padding(.bottom, DSSpacing.xs)

                ForEach(viewModel.groupedByMonth, id: \.monthKey) { group in
                    Section {
                        ForEach(group.days, id: \.dateString) { stats in
                            archiveListRow(stats: stats)
                                .id(stats.dateString)
                        }
                    } header: {
                        monthSectionHeader(monthKey: group.monthKey, dayCount: group.days.count)
                    }
                }
            }
        }
        .padding(.top, DSSpacing.sm)
    }

    // MARK: - Month Section Header (list mode, Issue #13)
    //
    // Renders "YYYY 年 M 月" on the left and "<count> 天" on the right. Uses
    // `.ultraThinMaterial` as the background since `DSColor.bgCard` is not
    // defined in this design system.
    /// Locale-aware "yyyy-MM" → month header ("2026年7月" / "July 2026").
    /// Formatters are cached statically so section renders stay cheap.
    private static let monthKeyParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    private static let monthHeaderFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("yMMMM")
        return f
    }()

    private func monthSectionHeader(monthKey: String, dayCount: Int) -> some View {
        let headerTitle = Self.monthKeyParser.date(from: monthKey)
            .map { Self.monthHeaderFormatter.string(from: $0) } ?? monthKey
        let dayCountText = String(
            format: NSLocalizedString(
                dayCount == 1 ? "archive.section.dayCount.one" : "archive.section.dayCount",
                comment: "Month section header trailing label: %d days with entries"
            ),
            dayCount
        )

        // Quiet ledger chapter head — mono caption + hairline, no material
        // slab (W1: three container styles in one list was two too many).
        return HStack(alignment: .firstTextBaseline, spacing: DSSpacing.md) {
            Text(headerTitle)
                .font(DSType.mono10)
                .tracking(1.0)
                .foregroundColor(DSColor.inkMuted)
            Rectangle()
                .fill(DSColor.inkFaint)
                .frame(height: 0.5)
            Text(dayCountText)
                .font(DSType.mono10)
                .foregroundColor(DSColor.inkMuted)
        }
        .padding(.horizontal, DSSpacing.xs)
        .padding(.top, DSSpacing.lg)
        .padding(.bottom, DSSpacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(headerTitle), \(dayCountText)")
    }

    // MARK: - Month Digest Strip (list mode)

    /// A single horizontally-scannable card that mirrors the calendar-mode
    /// monthly summary, condensed for the dense list. Leads with the metric
    /// that's absent everywhere else — active (logged) days this month — then
    /// entries / photos / voice / locations. Numbers stay in sync with the
    /// rows below because both derive from `dayStats`.
    private var monthDigestStrip: some View {
        let activeDays = viewModel.activeDayCount
        let entries = viewModel.totalEntries
        let photos = viewModel.totalPhotos
        let voice = viewModel.totalVoiceMinutes
        let locations = viewModel.totalLocations

        return VStack(alignment: .leading, spacing: DSSpacing.md) {
            Text("\(viewModel.currentMonthTitle) · DIGEST")
                .monoLabelStyle(size: 10)
                .foregroundColor(DSColor.inkMuted)

            HStack(alignment: .top, spacing: 0) {
                digestStat(value: "\(activeDays)",
                           label: NSLocalizedString("archive.stat.days", comment: "Stat pillar label: active days"),
                           accent: true)
                digestDivider
                digestStat(value: "\(entries)",
                           label: NSLocalizedString("archive.stat.entries", comment: "Stat pillar label: entries"),
                           accent: false)
                if photos > 0 {
                    digestDivider
                    digestStat(value: "\(photos)",
                               label: NSLocalizedString("archive.stat.photos", comment: "Stat pillar label: photos"),
                               accent: false)
                }
                if voice > 0 {
                    digestDivider
                    digestStat(value: "\(voice)",
                               label: NSLocalizedString("archive.stat.voiceMin", comment: "Stat pillar label: voice minutes"),
                               accent: false)
                }
                if locations > 0 {
                    digestDivider
                    digestStat(value: "\(locations)",
                               label: NSLocalizedString("archive.stat.places", comment: "Stat pillar label: places"),
                               accent: false)
                }
            }
        }
        .padding(.horizontal, DSSpacing.lg)
        .padding(.vertical, DSSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassCard(cornerRadius: DSRadius.md)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(
            format: NSLocalizedString("archive.list.digest.a11y", comment: "Month digest summary"),
            viewModel.currentMonthTitle, activeDays, entries, photos, voice, locations
        ))
    }

    private func digestStat(value: String, label: String, accent: Bool) -> some View {
        VStack(alignment: .center, spacing: DSSpacing.xs) {
            Text(value)
                .font(DSType.serifDisplay28)
                .foregroundColor(accent ? DSColor.accentOnBg : DSColor.inkPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(label)
                .monoLabelStyle(size: 9)
                .foregroundColor(DSColor.inkMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var digestDivider: some View {
        Rectangle()
            .fill(DSColor.inkFaint)
            .frame(width: 0.5, height: 28)
    }

    // MARK: - Weekly Recap Entry Card (R7)

    /// Gated entry card pushing `WeeklyRecapDetailView`. Two gates:
    ///   * `FeatureFlag.weeklyRecap` — kill switch.
    ///   * ≥3 compiled daily pages this week — avoids surfacing an AI
    ///     experience that has nothing to summarise. Uses the existing
    ///     `WeeklyRecapService.entries` since it already reads from
    ///     `vault/wiki/daily/` for the same week boundary.
    @ViewBuilder
    private var weeklyRecapEntryCard: some View {
        let flagOn = FeatureFlagStore.shared.isEnabled(.weeklyRecap)
        let recentDailyCount = WeeklyRecapService.shared.entries(referenceDate: Date()).count
        if flagOn && recentDailyCount >= 3 {
            // W1 fix: value-based push onto archivePath (was a closure
            // NavigationLink). Unifies it with the entity/day pushes on this
            // stack so edge-back pops it, the pop gesture is re-armed, and
            // entity-chip pushes from inside it land at the right depth.
            //
            // W1: value-based push onto archivePath (was a closure
            // NavigationLink), unifying it with the entity/day pushes on this
            // stack so edge-back pops it and the pop gesture is re-armed.
            //
            // Hit-testing fix (2026-07-18): the card body used `.liquidGlassCard`
            // (role .panel, no `.interactive()`), whose iOS 26 native
            // `glassEffect` layer swallowed the synthetic/real tap over most of
            // the card — only a tap near the trailing chevron registered, so the
            // entry was hard to open on device and in the simulator. Switched the
            // body to `.solidCard` (surface-white + hairline, no glass layer),
            // which never intercepts the NavigationLink label's tap and also
            // matches the surface-white card language of WeeklyRecapDetailView.
            NavigationLink(value: WeeklyRecapRef(referenceDate: Date())) {
                weeklyRecapEntryCardBody
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(weeklyRecapEntryA11yLabel)
            .accessibilityHint(NSLocalizedString("weekly.recap.entrycard.hint", comment: ""))
            .accessibilityAddTraits(.isButton)
        } else {
            EmptyView()
        }
    }

    private var weeklyRecapEntryA11yLabel: String {
        let isoWeek = WeeklyCompilationService.isoWeekKey(for: Date())
        let title = NSLocalizedString("weekly.recap.entrycard.title", comment: "")
        return "\(title), \(isoWeek)"
    }

    private var weeklyRecapEntryCardBody: some View {
        let isoWeek = WeeklyCompilationService.isoWeekKey(for: Date())
        let title = NSLocalizedString("weekly.recap.entrycard.title", comment: "")

        return HStack(alignment: .center, spacing: 14) {
            Image(systemName: "calendar")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(DSColor.accentOnBg)
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(title)
                    .font(DSType.titleSM)
                    .foregroundColor(DSColor.inkPrimary)
                Text(isoWeek)
                    .font(DSType.mono11)
                    .foregroundColor(DSColor.inkMuted)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(DSColor.inkMuted)
        }
        .padding(.horizontal, DSSpacing.lg)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // solidCard (not liquidGlassCard): a glass layer here swallowed the
        // NavigationLink's tap on iOS 26 (see note above the NavigationLink).
        .solidCard(cornerRadius: DSRadius.md)
    }

    private func relativeDateLabel(_ dateString: String) -> String {
        RelativeDate.label(for: dateString, style: .caps)
    }

    /// Journal-ledger row (W1): date column + one-line teaser + bare count.
    /// Replaces the shouting per-day glass card — twice the days per screen,
    /// and the scroll reads like flipping a ledger. Compiled days speak in
    /// primary ink and an amber date; metadata-only days stay muted. Zero
    /// photo/voice counters no longer occupy space (they said nothing).
    private func archiveListRow(stats: DayStats) -> some View {
        let isCompiled = stats.isDailyPageCompiled
        let teaser: String? = {
            if let s = stats.dailySummary, !s.isEmpty { return s }
            return viewModel.dayTeasers[stats.dateString]
        }()
        let stateLabel = isCompiled
            ? NSLocalizedString("archive.a11y.day.compiled", comment: "A11y: day has a compiled daily page")
            : NSLocalizedString("archive.a11y.day.rawOnly", comment: "A11y: day has raw memos only")

        return Button(action: {
            handleDateTap(dateStr: stats.dateString)
        }) {
            HStack(alignment: .firstTextBaseline, spacing: DSSpacing.md) {
                Text(ledgerDateLabel(stats.dateString))
                    .font(DSType.mono10)
                    .tracking(0.5)
                    .foregroundColor(isCompiled ? DSColor.accentOnBg : DSColor.inkMuted)
                    .frame(width: 64, alignment: .leading)

                Text(teaser ?? "—")
                    .font(DSType.bodySM)
                    .foregroundColor(isCompiled ? DSColor.inkPrimary : DSColor.inkMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: DSSpacing.sm)

                Text("\(stats.memoCount)")
                    .font(DSType.mono10)
                    .foregroundColor(DSColor.inkMuted)
            }
            .padding(.vertical, 13)
            .padding(.horizontal, DSSpacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DSColor.inkFaint)
                .frame(height: 0.5)
                .padding(.leading, 64 + DSSpacing.md)
        }
        .modifier(ArchiveDayZoomSource(id: stats.dateString, namespace: dayZoomNamespace))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(relativeDateLabel(stats.dateString))，\(stateLabel)，\(stats.memoCount)")
        .accessibilityHint(NSLocalizedString("archive.a11y.day.hint", comment: "A11y hint: calendar day cell opens the day detail"))
    }

    /// Fixed-width mono date column: relative caps for today/yesterday,
    /// "07·12" for everything older.
    private func ledgerDateLabel(_ dateString: String) -> String {
        guard let date = DateFormatters.isoDate.date(from: dateString) else { return dateString }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day ?? 99
        switch days {
        case 0: return NSLocalizedString("archive.ledger.today", comment: "Ledger date column: today")
        case 1: return NSLocalizedString("archive.ledger.yesterday", comment: "Ledger date column: yesterday")
        default:
            let parts = dateString.split(separator: "-")
            guard parts.count == 3 else { return dateString }
            return "\(parts[1])·\(parts[2])"
        }
    }
}

// MARK: - ArchiveListScrollOffsetKey

private struct ArchiveListScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - ArchiveVaultScan

fileprivate enum ArchiveVaultScan {
    static func load(_ request: ArchiveMonthRequest) async throws -> ArchiveMonthSnapshot {
        let task = Task.detached(priority: .userInitiated) {
            try scan(request)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func scan(_ request: ArchiveMonthRequest) throws -> ArchiveMonthSnapshot {
        try Task.checkCancellation()
        let rawDir = request.vaultRoot.appendingPathComponent("raw")
        let dailyDir = request.vaultRoot.appendingPathComponent("wiki/daily")
        // One filename enumeration per directory supplies the whole-Vault dots.
        let rawDates = try listDateFilenames(in: rawDir)
        let dailyDates = try listDateFilenames(in: dailyDir)
        let prefix = String(format: "%04d-%02d-", request.year, request.month)
        let dates = rawDates.union(dailyDates).filter { $0.hasPrefix(prefix) }.sorted()
        var stats: [String: DayStats] = [:]
        var teasers: [String: String] = [:]
        for dateString in dates {
            try Task.checkCancellation()
            var memos: [Memo] = []
            if rawDates.contains(dateString) {
                // Read the exact enumerated filename. RawStorage.read(for:) would
                // derive it again from the mutable global preferred time zone.
                let url = rawDir.appendingPathComponent("\(dateString).md")
                let content = try String(contentsOf: url, encoding: .utf8)
                memos = RawStorage.parse(fileContent: content, sourceFile: url)
            }
            var photos = 0
            var voiceSeconds = 0
            var locations = Set<String>()
            for memo in memos {
                if memo.type == .photo || memo.type == .mixed {
                    photos += memo.attachments.filter { $0.kind == "photo" }.count
                }
                if memo.type == .voice || memo.type == .mixed {
                    for attachment in memo.attachments where attachment.kind == "audio" {
                        if let duration = attachment.duration, duration.isFinite,
                           duration > 0, duration < Double(Int.max - voiceSeconds) {
                            voiceSeconds += Int(duration)
                        }
                    }
                }
                if let name = memo.location?.name, !name.isEmpty { locations.insert(name) }
            }
            var summary: String?
            if dailyDates.contains(dateString) {
                let url = dailyDir.appendingPathComponent("\(dateString).md")
                let content = try String(contentsOf: url, encoding: .utf8)
                summary = FrontmatterParser.extractField("summary", from: content)
            }
            stats[dateString] = DayStats(
                dateString: dateString, memoCount: memos.count, photoCount: photos,
                voiceSeconds: voiceSeconds, uniqueLocations: locations.count,
                isDailyPageCompiled: dailyDates.contains(dateString), dailySummary: summary
            )
            let teaser = summary?.isEmpty == false ? summary : memos.first { !$0.body.isEmpty }?.body
            if let teaser {
                let plain = MemoMarkdown.plainText(teaser)
                teasers[dateString] = String(plain.prefix(160))
            }
        }
        try Task.checkCancellation()
        return ArchiveMonthSnapshot(dayStats: stats, rawDates: rawDates,
                                    dailyDates: dailyDates, dayTeasers: teasers)
    }

    private static func listDateFilenames(in directory: URL) throws -> Set<String> {
        let entries: [String]
        do { entries = try FileManager.default.contentsOfDirectory(atPath: directory.path) }
        catch {
            let error = error as NSError
            // Missing directories are a legitimate empty Vault. Permission and
            // other read errors must not become a cached empty month.
            if error.domain == NSCocoaErrorDomain,
               error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError,
               !FileManager.default.fileExists(atPath: directory.path) {
                return []
            }
            throw error
        }
        return Set(entries.compactMap { name in
            guard name.hasSuffix(".md") else { return nil }
            let stem = String(name.dropLast(3))
            let bytes = Array(stem.utf8)
            guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
                  bytes.enumerated().allSatisfy({ index, byte in
                      index == 4 || index == 7 || (48...57).contains(byte)
                  }) else { return nil }
            return stem
        })
    }
}

// MARK: - Array+Chunked Helper

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

// MARK: - CalendarCellButtonStyle

private struct CalendarCellButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1.0)
            .opacity(configuration.isPressed ? 0.82 : 1.0)
            .dsAnimation(Motion.spring, value: configuration.isPressed)
    }
}

// MARK: - Archive Day Zoom Transition
//
// Mirror of Today's CardZoomSource/CardZoomDestination: the tapped calendar
// cell / list row is the source, the pushed DayDetailView is the destination,
// keyed by the day's date string. iOS 18+ only, and skipped under Reduce
// Motion — everywhere else the push falls back to the default slide.

struct ArchiveDayZoomSource: ViewModifier {
    let id: String
    let namespace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), !reduceMotion {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
    }
}

struct ArchiveDayZoomDestination: ViewModifier {
    let id: String
    let namespace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), !reduceMotion {
            content.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            content
        }
    }
}
