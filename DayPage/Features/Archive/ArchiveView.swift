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
struct DayStats {
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
            switch self {
            case .empty:  return DSColor.densityNone
            case .low:    return DSColor.densityLow
            case .medium: return DSColor.densityMid
            case .high:   return DSColor.densityHigh
            }
        }

        var textColor: Color {
            switch self {
            case .empty, .low: return DSColor.inkPrimary
            // medium / high density chips fill with amber → use onAmber token
            // so the warm-cream foreground tracks dark mode correctly.
            case .medium, .high: return DSColor.onAmber
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

    // Task handle used to cancel a stale loadMonth request when the user
    // navigates to a different month before the previous load finishes.
    private var loadMonthTask: Task<Void, Never>?

    // Cache: keyed by "yyyy-MM" so navigating back to a viewed month is instant.
    // Cleared only when the view model is deallocated or a forced refresh is requested.
    private var monthCache: [String: [String: DayStats]] = [:]

    init() {
        let now = Calendar.current.dateComponents([.year, .month], from: Date())
        currentYear = now.year ?? Calendar.current.component(.year, from: Date())
        currentMonth = now.month ?? Calendar.current.component(.month, from: Date())
    }

    var currentMonthTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        var comps = DateComponents()
        comps.year = currentYear
        comps.month = currentMonth
        comps.day = 1
        guard let date = Calendar.current.date(from: comps) else { return "" }
        return formatter.string(from: date).uppercased()
    }

    func goToPreviousMonth() {
        var comps = DateComponents()
        comps.year = currentYear
        comps.month = currentMonth - 1
        comps.day = 1
        if let date = Calendar.current.date(from: comps) {
            let c = Calendar.current.dateComponents([.year, .month], from: date)
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
        if let date = Calendar.current.date(from: comps) {
            let c = Calendar.current.dateComponents([.year, .month], from: date)
            currentYear = c.year ?? currentYear
            currentMonth = c.month ?? currentMonth
        }
        loadMonth()
    }

    func loadMonth() {
        // Serve cached month instantly (no spinner, no disk read).
        let cacheKey = String(format: "%04d-%02d", currentYear, currentMonth)
        if let cached = monthCache[cacheKey] {
            dayStats = cached
            return
        }

        // Cancel any in-flight load so that a stale result from a prior month
        // cannot overwrite the data for the month the user just navigated to.
        loadMonthTask?.cancel()
        isLoading = true

        // Capture value-type state before leaving the MainActor.
        let year = currentYear
        let month = currentMonth
        let rawDir = VaultInitializer.vaultURL.appendingPathComponent("raw")
        let dailyDir = VaultInitializer.vaultURL.appendingPathComponent("wiki/daily")

        loadMonthTask = Task.detached(priority: .userInitiated) {
            // Pure helpers inlined here to avoid calling @MainActor instance methods
            // from a non-isolated context.
            func daysInMonth(year: Int, month: Int) -> Int {
                var comps = DateComponents()
                comps.year = year
                comps.month = month
                guard let date = Calendar.current.date(from: comps),
                      let range = Calendar.current.range(of: .day, in: .month, for: date)
                else { return 30 }
                return range.count
            }

            let fmt = DateFormatters.isoDate

            // Issue #28: single contentsOfDirectory scan + on-disk filename
            // filter beats 31 fileExists() probes. Most months have <10
            // populated days; the previous code paid 31 full RawStorage.read
            // calls (= 31 YAML parses + 31 Memo[] allocations) regardless.
            //
            // We restrict to filenames matching the current `yyyy-MM-` prefix
            // and only parse the days that actually have a file. The empty
            // days fall through to the default DayStats below.
            let monthPrefix = String(format: "%04d-%02d-", year, month)
            let presentRawStems: Set<String>
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: rawDir.path) {
                presentRawStems = Set(
                    entries
                        .filter { $0.hasSuffix(".md") && $0.hasPrefix(monthPrefix) }
                        .map { String($0.dropLast(3)) }
                )
            } else {
                presentRawStems = []
            }
            let presentDailyStems: Set<String>
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: dailyDir.path) {
                presentDailyStems = Set(
                    entries
                        .filter { $0.hasSuffix(".md") && $0.hasPrefix(monthPrefix) }
                        .map { String($0.dropLast(3)) }
                )
            } else {
                presentDailyStems = []
            }

            var result: [String: DayStats] = [:]
            let totalDays = daysInMonth(year: year, month: month)

            for day in 1...totalDays {
                // Early exit: if the task was cancelled mid-loop, reset isLoading
                // so the UI never stays stuck on a spinner after navigation.
                guard !Task.isCancelled else {
                    await MainActor.run { self.isLoading = false }
                    return
                }
                var comps = DateComponents()
                comps.year = year
                comps.month = month
                comps.day = day
                guard let date = Calendar.current.date(from: comps) else { continue }
                let dateStr = fmt.string(from: date)

                let hasRaw = presentRawStems.contains(dateStr)
                let isDailyCompiled = presentDailyStems.contains(dateStr)

                // Skip the entire YAML-parse + Memo allocation cost on empty
                // days. They get no DayStats entry and the calendar simply
                // renders no dot — which is the same visual outcome as the
                // previous all-zero entry.
                guard hasRaw || isDailyCompiled else { continue }

                var memoCount = 0
                var photoCount = 0
                var voiceSeconds = 0
                var uniqueLocations = Set<String>()

                if hasRaw {
                    let memos: [Memo]
                    do {
                        memos = try RawStorage.read(for: date)
                    } catch {
                        memos = []
                    }
                    memoCount = memos.count
                    for memo in memos {
                        if memo.type == .photo || memo.type == .mixed {
                            photoCount += memo.attachments.filter { $0.kind == "photo" }.count
                        }
                        if memo.type == .voice || memo.type == .mixed {
                            for att in memo.attachments where att.kind == "audio" {
                                if let dur = att.duration {
                                    voiceSeconds += Int(dur)
                                }
                            }
                        }
                        if let loc = memo.location, let name = loc.name, !name.isEmpty {
                            uniqueLocations.insert(name)
                        }
                    }
                }

                var dailySummary: String? = nil
                if isDailyCompiled {
                    let dailyURL = dailyDir.appendingPathComponent("\(dateStr).md")
                    if let content = (try? String(contentsOf: dailyURL, encoding: .utf8)) {
                        dailySummary = FrontmatterParser.extractField("summary", from: content)
                    }
                }

                result[dateStr] = DayStats(
                    dateString: dateStr,
                    memoCount: memoCount,
                    photoCount: photoCount,
                    voiceSeconds: voiceSeconds,
                    uniqueLocations: uniqueLocations.count,
                    isDailyPageCompiled: isDailyCompiled,
                    dailySummary: dailySummary
                )
            }

            // If this task was cancelled while the loop was running, discard results
            // and ensure isLoading is reset so the UI never stays on a spinner.
            guard !Task.isCancelled else {
                await MainActor.run { self.isLoading = false }
                return
            }

            let key = String(format: "%04d-%02d", year, month)
            await MainActor.run {
                self.monthCache[key] = result
                self.dayStats = result
                self.isLoading = false
            }
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
        let now = Calendar.current.dateComponents([.year, .month], from: Date())
        return now.year == currentYear && now.month == currentMonth
    }

    var isViewingCurrentMonth: Bool { isCurrentMonthAndYear }

    func goToCurrentMonth() {
        let now = Calendar.current.dateComponents([.year, .month], from: Date())
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
        Calendar.current.component(.day, from: Date())
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
        guard let date = Calendar.current.date(from: comps),
              let range = Calendar.current.range(of: .day, in: .month, for: date) else { return 30 }
        return range.count
    }

    private func firstWeekdayOfMonth(year: Int, month: Int) -> Int {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = 1
        guard let date = Calendar.current.date(from: comps) else { return 1 }
        return Calendar.current.component(.weekday, from: date)
    }
}

// MARK: - ArchiveView

struct ArchiveView: View {

    @EnvironmentObject private var nav: AppNavigationModel
    @StateObject private var viewModel = ArchiveViewModel()
    @State private var mode: ArchiveMode = .calendar
    /// The historical day pushed onto Archive's NavigationStack as a
    /// DayDetailView. Replaces the former `selectedDateString` + `showDayDetail`
    /// bool that drove a `fullScreenCover`; pushing gives the day a system back
    /// button + interactive edge-swipe-to-pop and a zoom hero (iOS 18+) out of
    /// the tapped calendar cell / list row.
    @State private var selectedDay: DayNavTarget? = nil
    /// Shared zoom namespace so the tapped calendar cell / list row is the
    /// `matchedTransitionSource` for the pushed DayDetailView.
    @Namespace private var dayZoomNamespace
    @State private var showSearch: Bool = false
    /// Pre-filled query passed into SearchView when opened via deep link
    /// (`daypage://search?q=…` from `AskTodayIntent`). Cleared after consume
    /// so re-triggering the same shortcut re-fires the navigation.
    @State private var searchInitialQuery: String? = nil
    @State private var summaryFilter: MonthlySummaryFilter = .all
    @State private var showShareSheet: Bool = false
    @State private var shareItems: [Any] = []
    @State private var monthNavDirection: Edge = .leading
    @State private var todayPulse: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - List mode scroll-to-top
    @State private var listScrollOffset: CGFloat = 0
    @State private var listScrollProxy: ScrollViewProxy? = nil

    /// Issue #302: monthly summary → share-card sheet.
    @State private var sharePayload: SharePayload? = nil
    @Environment(\.colorScheme) private var colorScheme

    // MARK: - Pre-scanned vault sets (US-006)
    //
    // 在视图出现时异步填充。驱动三态日历单元格视觉效果：
    // 已编译日记 → 实色高亮；仅有原始记录 → 圆点标记；
    // 二者皆无 → 50% 半透明灰色（仍可点击）。
    @State private var rawDates: Set<String> = []
    @State private var dailyDates: Set<String> = []

    /// Controls the year/month jump picker overlay (opened by tapping the
    /// Archive header's month title).
    @State private var showMonthPicker: Bool = false

    /// "yyyy-MM" set of months that hold at least one entry, derived from the
    /// pre-scanned raw/daily date sets. Drives the activity dots in the picker
    /// at zero extra disk cost.
    private var monthsWithEntries: Set<String> {
        var months = Set<String>()
        for dateStr in rawDates.union(dailyDates) where dateStr.count == 10 {
            months.insert(String(dateStr.prefix(7)))  // "yyyy-MM-dd" → "yyyy-MM"
        }
        return months
    }

    var body: some View {
        NavigationStack {
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
                                .padding(.horizontal, 20)
                                .padding(.vertical, 16)

                            if viewModel.isLoading {
                                HStack {
                                    Spacer()
                                    VStack(spacing: 8) {
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
                                    .padding(.horizontal, 12)
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
                                        .padding(.horizontal, 20)
                                        .padding(.top, 32)
                                        .padding(.bottom, 40)
                                } else {
                                    monthlySummary
                                        .padding(.horizontal, 20)
                                        .padding(.top, 32)
                                        .padding(.bottom, 40)
                                }
                            } else {
                                listContent
                                    .padding(.horizontal, 20)
                                    .padding(.bottom, 40)
                            }
                        }
                    }
                    .coordinateSpace(name: "archiveListScroll")
                    .onPreferenceChange(ArchiveListScrollOffsetKey.self) { value in
                        listScrollOffset = value
                    }
                    .onAppear { listScrollProxy = proxy }
                    .overlay(alignment: .bottomTrailing) {
                        if mode == .list && listScrollOffset < -240 && !viewModel.sortedDays.isEmpty {
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
                            .padding(.trailing, 20)
                            .padding(.bottom, 20)
                            .transition(.opacity.combined(with: .scale(scale: 0.8)))
                            .accessibilityLabel(NSLocalizedString("archive.scroll_to_top", comment: "Scroll to top of archive list"))
                            .accessibilityIdentifier("archive-scroll-to-top-button")
                        }
                    }
                    .animation(reduceMotion ? nil : Motion.rise, value: mode == .list && listScrollOffset < -240)
                    } // end ScrollViewReader
                }
            }
            .navigationBarHidden(true)
            // US-030 note: the left-edge open-sidebar swipe lives ONLY in
            // RootView's edge strip (1:1 finger tracking) — see TodayView for
            // why the fire-on-release duplicate was removed.
            .onAppear {
                viewModel.loadMonth()
                Task { await preScanVault() }
                consumePendingArchiveDate()
                consumePendingSearchQuery()
                guard !reduceMotion else { return }
                withAnimation(Motion.breathing) { todayPulse = true }
            }
            .onChange(of: nav.pendingArchiveDate) { _ in
                consumePendingArchiveDate()
            }
            .onChange(of: nav.pendingSearchQuery) { _ in
                consumePendingSearchQuery()
            }
            // isPresented-based (iOS 16+) rather than item: (iOS 17+) so the
            // push compiles against the 17.0 deployment target without an
            // availability gate. The bound day is read inside the builder.
            .navigationDestination(
                isPresented: Binding(
                    get: { selectedDay != nil },
                    set: { if !$0 { selectedDay = nil } }
                )
            ) {
                if let target = selectedDay {
                    DayDetailView(dateString: target.dateString)
                        .modifier(ArchiveDayZoomDestination(
                            id: target.dateString, namespace: dayZoomNamespace
                        ))
                }
            }
            .sheet(isPresented: $showSearch) {
                SearchView(
                    onSelect: { dateStr in
                        // Close the search sheet, then push the day once it has
                        // dismissed. A push while the sheet is still animating
                        // out gets swallowed, so defer by one runloop hop — much
                        // shorter than the old 0.25s cover-vs-sheet workaround.
                        showSearch = false
                        DispatchQueue.main.async {
                            selectedDay = DayNavTarget(dateString: dateStr)
                        }
                    },
                    initialQuery: searchInitialQuery
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
    }

    // MARK: - Navigation Helper

    /// 每个日历单元格均可点击（US-006）。DayDetailView 自身处理
    /// `.empty` / `.error` / `.rawOnly` / `.compiled` 等状态 — 参见 US-002。
    private func handleDateTap(dateStr: String) {
        Haptics.soft()
        selectedDay = DayNavTarget(dateString: dateStr)
    }

    /// Consume any pending deep-link from the sidebar's Recent row. Cleared
    /// after consumption so re-tapping the same row in the drawer still
    /// triggers a new presentation.
    private func consumePendingArchiveDate() {
        guard let dateStr = nav.pendingArchiveDate else { return }
        nav.pendingArchiveDate = nil
        // Defer the push so SwiftUI commits the tab switch first; pushing during
        // the same runloop as the tab change can race and skip the animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            selectedDay = DayNavTarget(dateString: dateStr)
        }
    }

    /// Consume a pending search query delivered via `daypage://search?q=…`
    /// (e.g. from `AskTodayIntent`). Mirrors `consumePendingArchiveDate` —
    /// clears the nav state immediately, then presents SearchView on the
    /// next runloop so the tab-switch animation commits first.
    private func consumePendingSearchQuery() {
        guard let q = nav.pendingSearchQuery else { return }
        nav.pendingSearchQuery = nil
        searchInitialQuery = q
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            showSearch = true
        }
    }

    // MARK: - Vault Pre-Scan (US-006)

    /// 列出 `vault/raw/*.md` 和 `vault/wiki/daily/*.md`（脱离主线程），并将
    /// 发现的日期字符串发布到 `@State` 集合中。非阻塞；失败时降级为空集合
    ///（日历会退回到"无数据"视觉效果 — 仍可点击）。
    private func preScanVault() async {
        let scanned: (Set<String>, Set<String>) = await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let rawDir = VaultInitializer.vaultURL.appendingPathComponent("raw")
            let dailyDir = VaultInitializer.vaultURL.appendingPathComponent("wiki/daily")
            return (
                ArchiveVaultScan.listDateFilenames(in: rawDir, fileManager: fm),
                ArchiveVaultScan.listDateFilenames(in: dailyDir, fileManager: fm)
            )
        }.value
        rawDates = scanned.0
        dailyDates = scanned.1
    }

    // MARK: - Archive Header

    private var archiveHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                // "Archive" title — opens the sidebar (tap), keeping the
                // primary navigation affordance the rest of the app uses.
                Button {
                    nav.openSidebar()
                } label: {
                    Text(NSLocalizedString("archive.title", comment: "Archive page title"))
                        .font(DSType.serifDisplay28)
                        .foregroundColor(DSColor.inkPrimary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("a11y.nav.open", comment: "Sidebar open button"))
                .accessibilityIdentifier("sidebar-menu-button")

                // Month subtitle — now a jump-to-month affordance. A chevron
                // signals it's interactive; tapping opens the YearMonthPicker.
                Button {
                    Haptics.soft()
                    withAnimation(reduceMotion ? nil : Motion.fade) { showMonthPicker = true }
                } label: {
                    HStack(spacing: 4) {
                        Text(viewModel.currentMonthTitle.uppercased())
                            .font(DSType.mono10)
                            .foregroundColor(DSColor.inkMuted)
                            .tracking(1.0)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(DSColor.inkMuted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(format: NSLocalizedString("archive.picker.open", comment: "Jump to month, current %@"), viewModel.currentMonthTitle))
                .accessibilityHint(NSLocalizedString("archive.picker.open.hint", comment: "Opens the month picker"))
                .accessibilityIdentifier("archive-month-picker-button")
            }

            Spacer()

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
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
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
        VStack(spacing: 8) {
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

    private var monthNavigationRow: some View {
        HStack {
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

            // CALENDAR / LIST toggle — glass pill
            HStack(spacing: 2) {
                toggleButton("CAL", isSelected: mode == .calendar) { mode = .calendar }
                toggleButton("LIST", isSelected: mode == .list) { mode = .list }
            }
            .padding(3)
            // #771: CAL/LIST view-mode toggle → glass engine (.pill).
            .dpGlass(.pill, in: Capsule())
            .clipShape(Capsule())

            Spacer()

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
                        .monoLabelStyle(size: 10)
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(DSColor.amberDeep, in: Capsule())
                        .overlay(Capsule().strokeBorder(DSColor.glassRim, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("archive.a11y.currentMonth.label", comment: "A11y label: back-to-current-month button"))
                .accessibilityHint(NSLocalizedString("archive.a11y.currentMonth.hint", comment: "A11y hint: back-to-current-month button"))
                .transition(.scale.combined(with: .opacity))
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
                .foregroundColor(isSelected ? DSColor.onAmber : DSColor.inkSubtle)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? DSColor.amberDeep : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Calendar Grid

    private let weekdaySymbols = ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"]

    private var calendarGrid: some View {
        // 4pt gutters + 8pt inset: with the previous 1pt gaps the amber cell
        // fills fused with the amber-tinted glass panel into one flat salmon
        // slab — the density heatmap only reads when cells are discrete tiles.
        VStack(spacing: 4) {
            // Weekday header row
            HStack(spacing: 4) {
                ForEach(weekdaySymbols, id: \.self) { day in
                    Text(day)
                        .monoLabelStyle(size: 9)
                        .foregroundColor(DSColor.onSurfaceVariant)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                }
            }

            // Day cells
            let cells = viewModel.daysInCurrentMonth()
            let rows = cells.chunked(into: 7)
            ForEach(rows.indices, id: \.self) { rowIdx in
                HStack(spacing: 4) {
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
                .padding(.horizontal, 4)
                .padding(.top, 6)
        }
        .padding(8)
        // #771: month calendar grid → glass engine (.panel). Engine owns rim.
        .dpGlass(.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// 日历单元格的三态分类（US-006）。
    /// 基于预扫描的 `dailyDates` / `rawDates` 集合推导。
    private enum CellDataState {
        case compiled   // daily file exists → solid highlight
        case rawOnly    // only raw file exists → dot marker
        case none       // neither → 50% translucent gray, still tappable
    }

    private func cellState(for dateStr: String) -> CellDataState {
        if dailyDates.contains(dateStr) { return .compiled }
        if rawDates.contains(dateStr)   { return .rawOnly }
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
            let density = viewModel.dayStats[dateStr]?.densityLevel
            let fillColor: Color = {
                if let d = density { return d.fillColor }
                switch data {
                case .compiled: return DSColor.amberDeep
                case .rawOnly:  return DSColor.densityLow
                case .none:     return DSColor.densityNone
                }
            }()

            let textColor: Color = {
                if let d = density { return d.textColor }
                switch data {
                // `compiled` cell fills with amberDeep — onAmber keeps the
                // foreground legible in both light and dark schemes.
                case .compiled: return DSColor.onAmber
                case .rawOnly:  return DSColor.inkPrimary
                case .none:     return DSColor.inkSubtle
                }
            }()

            // Today dot sits on the amber today-cell fill — onAmber instead
            // of pure white so dark mode keeps the warm-cream language.
            let dotColor: Color = isToday ? DSColor.onAmber : DSColor.accentOnBg

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

                    Text(String(format: "%02d", day))
                        .monoLabelStyle(size: 9)
                        .foregroundColor(textColor)
                        .padding(4)

                    if data == .rawOnly {
                        Circle()
                            .fill(dotColor)
                            .frame(width: 4, height: 4)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                            .padding(4)
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
        HStack(spacing: 8) {
            Text("Activity:")
                .monoLabelStyle(size: 9)
                .foregroundColor(DSColor.inkMuted)

            ForEach([DayStats.DensityLevel.empty, .low, .medium, .high], id: \.label) { level in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(level.fillColor)
                    .frame(width: 12, height: 12)
            }

            Text(NSLocalizedString("archive.heatmap.higher", comment: "Heatmap legend higher"))
                .monoLabelStyle(size: 9)
                .foregroundColor(DSColor.inkMuted)

            Spacer()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(NSLocalizedString("a11y.activity_legend", comment: "Activity legend"))
        .accessibilityValue(NSLocalizedString("a11y.activity_legend.value", comment: "Legend range"))
    }

    // MARK: - Monthly Summary

    private var monthlySummary: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Text(String(format: NSLocalizedString("archive.summary.title", comment: "Monthly summary section title; %@ = month title"), viewModel.currentMonthTitle))
                    .font(DSType.sectionLabel)
                    .foregroundColor(DSColor.inkMuted)
                Rectangle()
                    .fill(DSColor.inkFaint)
                    .frame(height: 0.5)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                summaryCard("TOTAL ENTRIES", value: "\(viewModel.totalEntries)", accentPrimary: true)
                if viewModel.totalVoiceMinutes > 0 {
                    summaryCard("VOICE DURATION", value: "\(viewModel.totalVoiceMinutes)", unit: "min", accentPrimary: false)
                }
                if viewModel.totalPhotos > 0 {
                    summaryCard("PHOTOS CAPTURED", value: "\(viewModel.totalPhotos)", accentPrimary: false)
                }
                if viewModel.totalLocations > 0 {
                    summaryCard("TRAVEL LOCATIONS", value: "\(viewModel.totalLocations)", accentPrimary: true)
                }
            }

            // Filter chips
            HStack(spacing: 8) {
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
                        .padding(.vertical, 8)
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

            // Export / Share actions
            HStack(spacing: 10) {
                Button(action: exportMarkdown) {
                    Label(NSLocalizedString("archive.export.markdown", comment: "Button: export monthly summary as Markdown"), systemImage: "square.and.arrow.up")
                        .monoLabelStyle(size: 11)
                        .foregroundColor(DSColor.inkPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .liquidGlassCard(cornerRadius: 8)
                }
                .buttonStyle(.plain)

                Button {
                    Task { await shareScreenshot() }
                } label: {
                    Label(NSLocalizedString("archive.export.screenshot", comment: "Button: share monthly summary as screenshot"), systemImage: "camera")
                        .monoLabelStyle(size: 11)
                        .foregroundColor(DSColor.inkPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .liquidGlassCard(cornerRadius: 8)
                }
                .buttonStyle(.plain)

                Spacer()
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(activityItems: shareItems)
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
                .foregroundColor(isSelected ? Color.white : DSColor.inkSubtle)
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
        }
        shareItems = [tempURL]
        showShareSheet = true
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

    private func summaryCard(_ label: String, value: String, unit: String? = nil, accentPrimary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .monoLabelStyle(size: 10)
                .foregroundColor(DSColor.onSurfaceVariant)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(DSType.serifDisplay32)
                    .foregroundColor(accentPrimary ? DSColor.accentOnBg : DSColor.inkPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if let unit {
                    Text(unit.uppercased())
                        .monoLabelStyle(size: 10)
                        .foregroundColor(DSColor.inkMuted)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 110)
        .liquidGlassCard(cornerRadius: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(unit != nil ? "\(value) \(unit!)" : value)
    }

    // MARK: - List Content

    private var listContent: some View {
        // Issue #13 perf: month-grouped Sections let LazyVStack lay out only
        // the rows it actually needs (one bucket at a time), eliminating the
        // 1-2s freeze on the first scroll when a month has many populated
        // days. iOS 16 compatibility: do NOT use pinnedViews — sticky-header
        // behavior is inconsistent on 16.x; a plain header View is enough.
        LazyVStack(spacing: 8, pinnedViews: []) {
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
                    .padding(.bottom, 4)

                // Compact monthly digest — list mode otherwise drops all the
                // month-level context that calendar mode shows in its summary
                // grid. (#archive-list-digest)
                monthDigestStrip
                    .padding(.bottom, 4)

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
        .padding(.top, 8)
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
            format: NSLocalizedString("archive.section.dayCount", comment: "Month section header trailing label: %d days with entries"),
            dayCount
        )

        return HStack(alignment: .firstTextBaseline) {
            Text(headerTitle)
                .font(DSType.titleSM)
                .foregroundColor(DSColor.inkPrimary)
            Spacer(minLength: 8)
            Text(dayCountText)
                .font(DSType.labelSM)
                .foregroundColor(DSColor.inkMuted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
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

        return VStack(alignment: .leading, spacing: 12) {
            Text("\(viewModel.currentMonthTitle) · DIGEST")
                .monoLabelStyle(size: 10)
                .foregroundColor(DSColor.inkMuted)

            HStack(alignment: .top, spacing: 0) {
                digestStat(value: "\(activeDays)", label: "DAYS", accent: true)
                digestDivider
                digestStat(value: "\(entries)", label: "ENTRIES", accent: false)
                if photos > 0 {
                    digestDivider
                    digestStat(value: "\(photos)", label: "PHOTOS", accent: false)
                }
                if voice > 0 {
                    digestDivider
                    digestStat(value: "\(voice)", label: "VOICE MIN", accent: false)
                }
                if locations > 0 {
                    digestDivider
                    digestStat(value: "\(locations)", label: "PLACES", accent: false)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassCard(cornerRadius: DSRadius.md)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(
            format: NSLocalizedString("archive.list.digest.a11y", comment: "Month digest summary"),
            viewModel.currentMonthTitle, activeDays, entries, photos, voice, locations
        ))
    }

    private func digestStat(value: String, label: String, accent: Bool) -> some View {
        VStack(alignment: .center, spacing: 4) {
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
            NavigationLink {
                WeeklyRecapDetailView(referenceDate: Date())
            } label: {
                weeklyRecapEntryCardBody
            }
            .buttonStyle(.plain)
        } else {
            EmptyView()
        }
    }

    private var weeklyRecapEntryCardBody: some View {
        let isoWeek = WeeklyCompilationService.isoWeekKey(for: Date())
        let title = NSLocalizedString("weekly.recap.entrycard.title", comment: "")

        return HStack(alignment: .center, spacing: 14) {
            Image(systemName: "calendar")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(DSColor.accentOnBg)
            VStack(alignment: .leading, spacing: 4) {
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
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassCard(cornerRadius: DSRadius.md)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(isoWeek)")
        .accessibilityHint(NSLocalizedString("weekly.recap.entrycard.hint", comment: ""))
        .accessibilityAddTraits(.isButton)
    }

    private func relativeDateLabel(_ dateString: String) -> String {
        RelativeDate.label(for: dateString, style: .caps)
    }

    private func archiveListRow(stats: DayStats) -> some View {
        let isMetadataOnly = !stats.isDailyPageCompiled
        return Button(action: {
            handleDateTap(dateStr: stats.dateString)
        }) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(relativeDateLabel(stats.dateString))
                        .font(DSType.h2)
                        .foregroundColor(DSColor.inkPrimary)
                        .opacity(isMetadataOnly ? 0.7 : 1.0)

                    Spacer()

                    StatusBadge(
                        label: stats.isDailyPageCompiled ? "VERIFIED" : "METADATA",
                        style: stats.isDailyPageCompiled ? .verified : .metadata
                    )
                }

                if let summary = stats.dailySummary, !summary.isEmpty {
                    Text(summary)
                        .font(DSType.serifBody16)
                        .foregroundColor(DSColor.inkMuted)
                        .italic()
                        .lineLimit(2)
                        .opacity(isMetadataOnly ? 0.7 : 1.0)
                }

                HStack(spacing: 16) {
                    metaIcon("doc.text", count: stats.memoCount)
                    metaIcon("photo", count: stats.photoCount)
                    metaIcon("mic", count: stats.voiceMinutes, unit: "min")
                }
                .opacity(isMetadataOnly ? 0.7 : 1.0)
            }
            .padding(DSSpacing.cardGap)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlassCard(cornerRadius: DSRadius.md)
            .pressableCard()
        }
        .buttonStyle(.plain)
        .modifier(ArchiveDayZoomSource(id: stats.dateString, namespace: dayZoomNamespace))
    }

    private func metaIcon(_ systemName: String, count: Int, unit: String? = nil) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemName)
                .font(DSType.labelXS)
                .foregroundColor(DSColor.inkMuted)
            Text(unit != nil ? "\(count) \(unit!)" : "\(count)")
                .monoLabelStyle(size: 11)
                .foregroundColor(DSColor.inkMuted)
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

// MARK: - ArchiveVaultScan (US-006)

/// 文件级辅助函数，用于 ArchiveView 出现时在后台运行的预扫描。
/// 放在视图外部，以便 `Task.detached` 闭包可以调用而不捕获
/// `self`（否则会破坏脱离 `@MainActor` 的目的）。
fileprivate enum ArchiveVaultScan {

    /// 返回 `dir` 目录下 `.md` 文件的 `YYYY-MM-DD` 基础名称集合。
    /// 忽略不匹配的文件名（assets/、附件等）。缺失目录降级为空集合
    /// — 日历会将所有单元格渲染为"无数据"状态，仍可点击。
    static func listDateFilenames(in dir: URL, fileManager: FileManager) -> Set<String> {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        var out: Set<String> = []
        for name in entries {
            guard name.hasSuffix(".md") else { continue }
            let base = String(name.dropLast(3))  // 去除 ".md"
            guard base.count == 10,
                  base[base.index(base.startIndex, offsetBy: 4)] == "-",
                  base[base.index(base.startIndex, offsetBy: 7)] == "-" else { continue }
            let digits = base.replacingOccurrences(of: "-", with: "")
            guard digits.count == 8, digits.allSatisfy({ $0.isNumber }) else { continue }
            out.insert(base)
        }
        return out
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
