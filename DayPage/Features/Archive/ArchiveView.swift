import SwiftUI

// MARK: - ArchiveMode

enum ArchiveMode {
    case calendar
    case list
}

// MARK: - MonthlySummaryFilter

enum MonthlySummaryFilter: String, CaseIterable {
    case all = "全部"
    case hasLocation = "有位置"
    case hasPhoto = "有照片"
}

// MARK: - SystemStatus

enum SystemStatus {
    case synchronized
    case pendingCompilation
    case offline

    var label: String {
        switch self {
        case .synchronized:       return "SYNCHRONIZED"
        case .pendingCompilation: return "PENDING COMPILATION"
        case .offline:            return "OFFLINE"
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
            case .medium, .high: return Color.white
            }
        }

        var label: String {
            switch self {
            case .empty: return "EMPTY"
            case .low: return "LOW"
            case .medium: return "MEDIUM"
            case .high: return "HIGH"
            }
        }

        /// Right-corner dot color — amber accent on today cell, text color otherwise.
        func dotColor(isToday: Bool) -> Color {
            isToday ? Color.white : textColor
        }
    }
}

// MARK: - ArchiveViewModel

@MainActor
final class ArchiveViewModel: ObservableObject {

    @Published var currentYear: Int
    @Published var currentMonth: Int
    @Published var dayStats: [String: DayStats] = [:]  // keyed by "yyyy-MM-dd"
    @Published var isLoading: Bool = false

    // Task handle used to cancel a stale loadMonth request when the user
    // navigates to a different month before the previous load finishes.
    private var loadMonthTask: Task<Void, Never>?

    // Cache: keyed by "yyyy-MM" so navigating back to a viewed month is instant.
    // Cleared only when the view model is deallocated or a forced refresh is requested.
    private var monthCache: [String: [String: DayStats]] = [:]

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

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

            func countMemoBlocks(in content: String) -> Int {
                content.components(separatedBy: "\n\n---\n\n").count
            }

            // DateFormatter is not Sendable; create a local instance for this task.
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.timeZone = TimeZone.current

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

                let rawURL = rawDir.appendingPathComponent("\(dateStr).md")
                let dailyURL = dailyDir.appendingPathComponent("\(dateStr).md")

                var memoCount = 0
                var photoCount = 0
                var voiceSeconds = 0
                var uniqueLocations = Set<String>()

                // RawStorage.read returns [] when the file is missing and parses
                // the day's memos in one pass. Calling it directly avoids a redundant
                // disk read (the previous `String(contentsOf:)` guard only existed
                // to provide a fallback when read threw — handled below).
                let memos: [Memo]
                do {
                    memos = try RawStorage.read(for: date)
                } catch {
                    // Fallback: parse-failure should not zero the day. Read raw and
                    // count blocks so the calendar density still reflects activity.
                    let raw = (try? String(contentsOf: rawURL, encoding: .utf8)) ?? ""
                    memoCount = raw.isEmpty ? 0 : countMemoBlocks(in: raw)
                    memos = []
                }
                if !memos.isEmpty { memoCount = memos.count }
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

                let isDailyCompiled = FileManager.default.fileExists(atPath: dailyURL.path)
                var dailySummary: String? = nil
                if isDailyCompiled {
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

    // MARK: System Status

    /// 基于当月编译状态推算的系统状态。
    var systemStatus: SystemStatus {
        let days = dayStats.values
        // Days that have raw memos but no compiled Daily Page
        let hasPending = days.contains { $0.memoCount > 0 && !$0.isDailyPageCompiled }
        let hasAny = days.contains { $0.memoCount > 0 || $0.isDailyPageCompiled }
        guard hasAny else { return .synchronized }
        return hasPending ? .pendingCompilation : .synchronized
    }

    var lastSyncTimestamp: String {
        let compiled = dayStats.values
            .filter { $0.isDailyPageCompiled }
            .sorted { $0.dateString > $1.dateString }
        guard let latest = compiled.first else { return "N/A" }
        return latest.dateString.replacingOccurrences(of: "-", with: ".")
    }
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

    // MARK: Sorted Days for List Mode

    var sortedDays: [DayStats] {
        dayStats.values
            .filter { $0.memoCount > 0 || $0.isDailyPageCompiled }
            .sorted { $0.dateString > $1.dateString }
    }

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
        lines.append("# \(currentMonthTitle) 月度摘要")
        lines.append("")
        lines.append("- 总记录：\(totalEntries) 条")
        lines.append("- 照片：\(totalPhotos) 张")
        lines.append("- 语音：\(totalVoiceMinutes) 分钟")
        lines.append("- 地点：\(totalLocations) 处")
        lines.append("")
        if filter != .all {
            lines.append("> 筛选：\(filter.rawValue)")
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
            lines.append("- 记录：\(stats.memoCount) 条，照片：\(stats.photoCount) 张，语音：\(stats.voiceMinutes) 分钟，地点：\(stats.uniqueLocations) 处")
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

    private func countMemoBlocks(in content: String) -> Int {
        content.components(separatedBy: "\n\n---\n\n").count
    }
}

// MARK: - ArchiveView

struct ArchiveView: View {

    @EnvironmentObject private var nav: AppNavigationModel
    @StateObject private var viewModel = ArchiveViewModel()
    @State private var mode: ArchiveMode = .calendar
    @State private var selectedDateString: String? = nil
    @State private var showDayDetail: Bool = false
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
                            monthNavigationRow
                                .padding(.horizontal, 20)
                                .padding(.vertical, 16)

                            if viewModel.isLoading {
                                HStack {
                                    Spacer()
                                    VStack(spacing: 8) {
                                        ProgressView()
                                            .tint(DSColor.amberAccent)
                                        Text(NSLocalizedString("archive.loading_month", comment: ""))
                                            .font(DSType.mono9)
                                            .foregroundColor(DSColor.inkSubtle)
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
                                        DragGesture(minimumDistance: 30)
                                            .onEnded { value in
                                                let w = value.translation.width
                                                let h = value.translation.height
                                                guard abs(w) > abs(h) * 1.2, abs(w) > 50 else { return }
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

                                legendRow
                                    .padding(.horizontal, 12)
                                    .padding(.top, 8)

                                monthlySummary
                                    .padding(.horizontal, 20)
                                    .padding(.top, 32)

                                systemStatusArtifact
                                    .padding(.top, 32)
                                    .padding(.bottom, 40)
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
            .fullScreenCover(isPresented: $showDayDetail) {
                if let dateStr = selectedDateString {
                    DayDetailView(dateString: dateStr)
                }
            }
            .sheet(isPresented: $showSearch) {
                SearchView(
                    onSelect: { dateStr in
                        selectedDateString = dateStr
                        showSearch = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            showDayDetail = true
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
        selectedDateString = dateStr
        showDayDetail = true
    }

    /// Consume any pending deep-link from the sidebar's Recent row. Cleared
    /// after consumption so re-tapping the same row in the drawer still
    /// triggers a new presentation.
    private func consumePendingArchiveDate() {
        guard let dateStr = nav.pendingArchiveDate else { return }
        nav.pendingArchiveDate = nil
        selectedDateString = dateStr
        // Defer the cover so SwiftUI commits the tab switch first; presenting
        // a fullScreenCover during the same runloop as the tab change can
        // race and skip the animation on some iOS 16 builds.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            showDayDetail = true
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
                    Text("Archive")
                        .font(DSType.serifDisplay28)
                        .foregroundColor(DSColor.inkPrimary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open navigation")
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
                            .foregroundColor(DSColor.inkSubtle)
                            .tracking(1.0)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(DSColor.inkSubtle)
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
            .accessibilityLabel("搜索")
            .accessibilityHint("搜索历史记录")
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    // MARK: - Month Navigation Row

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
            .accessibilityLabel("上个月")
            .accessibilityHint("切换到上一个月")

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
                    Text("TODAY")
                        .monoLabelStyle(size: 10)
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(DSColor.amberDeep, in: Capsule())
                        .overlay(Capsule().strokeBorder(DSColor.glassRim, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("回到本月")
                .accessibilityHint("跳转到当前月份")
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
            .accessibilityLabel("下个月")
            .accessibilityHint("切换到下一个月")
        }
        .animation(reduceMotion ? nil : Motion.spring, value: viewModel.isViewingCurrentMonth)
    }

    private func toggleButton(_ label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .monoLabelStyle(size: 10)
                .foregroundColor(isSelected ? .white : DSColor.inkSubtle)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? DSColor.amberDeep : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Calendar Grid

    private let weekdaySymbols = ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"]

    private var calendarGrid: some View {
        VStack(spacing: 1) {
            // Weekday header row
            HStack(spacing: 1) {
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
                HStack(spacing: 1) {
                    ForEach(rows[rowIdx].indices, id: \.self) { colIdx in
                        let dayNum = rows[rowIdx][colIdx]
                        calendarCell(dayNum: dayNum)
                    }
                }
            }
        }
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
                case .compiled: return Color.white
                case .rawOnly:  return DSColor.inkPrimary
                case .none:     return DSColor.inkSubtle
                }
            }()

            let dotColor: Color = isToday ? Color.white : DSColor.amberAccent

            Button(action: {
                Haptics.tapConfirm()
                handleDateTap(dateStr: dateStr)
            }) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(fillColor)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(isToday ? DSColor.amberAccent : DSColor.glassRim,
                                        lineWidth: isToday ? 1.5 : 0.5)
                        )

                    if isToday && !reduceMotion {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
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
            .frame(maxWidth: .infinity)
            .accessibilityLabel(accessibilityLabel(dateStr: dateStr, state: data, stats: viewModel.dayStats[dateStr]))
            .accessibilityValue(viewModel.dayStats[dateStr]?.densityLevel.label ?? "")
            .accessibilityHint("双击打开当天详情")
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.clear)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
        }
    }

    private func accessibilityLabel(dateStr: String, state: CellDataState, stats: DayStats?) -> String {
        let statePrefix: String
        switch state {
        case .compiled: statePrefix = "已编译 Daily Page"
        case .rawOnly:  statePrefix = "有原始记录"
        case .none:     return "\(dateStr)，无记录"
        }
        guard let s = stats, s.memoCount > 0 else {
            return "\(dateStr)，\(statePrefix)"
        }
        let densityLabel: String
        switch s.densityLevel {
        case .empty:  densityLabel = "空"
        case .low:    densityLabel = "较低"
        case .medium: densityLabel = "中等"
        case .high:   densityLabel = "较高"
        }
        var parts: [String] = ["\(dateStr)，\(statePrefix)，活跃度 \(densityLabel)，\(s.memoCount) 条记录"]
        if s.photoCount > 0 { parts.append("\(s.photoCount) 张照片") }
        if s.uniqueLocations > 0 { parts.append("\(s.uniqueLocations) 处位置") }
        return parts.joined(separator: "，")
    }

    // MARK: - Heatmap Legend

    private var legendRow: some View {
        HStack(spacing: 8) {
            Text("Activity:")
                .monoLabelStyle(size: 9)
                .foregroundColor(DSColor.inkSubtle)

            ForEach([DayStats.DensityLevel.empty, .low, .medium, .high], id: \.label) { level in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(level.fillColor)
                    .frame(width: 12, height: 12)
            }

            Text("Higher Density")
                .monoLabelStyle(size: 9)
                .foregroundColor(DSColor.inkSubtle)

            Spacer()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Activity density legend")
        .accessibilityValue("Ranges from empty to high")
    }

    // MARK: - Monthly Summary

    private var monthlySummary: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Text("\(viewModel.currentMonthTitle) Summary")
                    .font(DSType.sectionLabel)
                    .foregroundColor(DSColor.inkSubtle)
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
                    Text("无符合条件的日期")
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
                                    Text(formatArchiveDate(stats.dateString))
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
                                .liquidGlassCard(cornerRadius: 10)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(formatArchiveDate(stats.dateString))
                            .accessibilityHint("Opens this day's entry")
                        }
                    }
                }
            }

            // Export / Share actions
            HStack(spacing: 10) {
                Button(action: exportMarkdown) {
                    Label("导出 Markdown", systemImage: "square.and.arrow.up")
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
                    Label("截图分享", systemImage: "camera")
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
            ShareSheetView(activityItems: shareItems)
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
            Text(filter.rawValue)
                .monoLabelStyle(size: 10)
                .foregroundColor(isSelected ? Color.white : DSColor.inkSubtle)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isSelected ? DSColor.amberDeep : DSColor.glassLo, in: Capsule())
                .animation(Motion.spring, value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(filter.rawValue)
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
                    .foregroundColor(accentPrimary ? DSColor.amberDeep : DSColor.inkPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if let unit {
                    Text(unit.uppercased())
                        .monoLabelStyle(size: 10)
                        .foregroundColor(DSColor.inkSubtle)
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

    // MARK: - System Status Artifact

    private var systemStatusArtifact: some View {
        VStack(spacing: 0) {
            // Top divider line
            Rectangle()
                .fill(DSColor.inkFaint)
                .frame(height: 0.5)

            ZStack {
                DSColor.amberDeep.opacity(0.92)
                    .ignoresSafeArea(edges: [])

                VStack(spacing: 16) {
                    // Decorative geometric graphic
                    ArtifactGeometricView()
                        .frame(width: 80, height: 80)

                    // Status label
                    VStack(spacing: 6) {
                        HStack(spacing: 6) {
                            Text("SYSTEM STATUS:")
                                .font(DSFonts.jetBrainsMono(size: 11, weight: .medium))
                                .foregroundColor(Color.white.opacity(0.4))
                                .tracking(0.5)

                            Text(viewModel.systemStatus.label)
                                .font(DSFonts.jetBrainsMono(size: 11, weight: .medium))
                                .foregroundColor(statusTextColor)
                                .tracking(0.5)
                        }

                        Text("LAST SYNC // \(viewModel.lastSyncTimestamp)")
                            .font(DSFonts.jetBrainsMono(size: 10, weight: .regular))
                            .foregroundColor(Color.white.opacity(0.3))
                            .tracking(0.5)
                    }
                }
                .padding(.vertical, 32)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var statusTextColor: Color {
        switch viewModel.systemStatus {
        case .synchronized:       return Color.white.opacity(0.6)
        case .pendingCompilation: return DSColor.warningAmber
        case .offline:            return DSColor.errorRed
        }
    }

    // MARK: - List Content

    private var listContent: some View {
        LazyVStack(spacing: 8) {
            Color.clear.frame(height: 0).id("archiveListTop")

            if viewModel.sortedDays.isEmpty {
                EmptyStateView.archiveMonthEmpty {
                    nav.selectedTab = .today
                }
                .padding(.top, 40)
            } else {
                // Compact monthly digest — list mode otherwise drops all the
                // month-level context that calendar mode shows in its summary
                // grid. (#archive-list-digest)
                monthDigestStrip
                    .padding(.bottom, 4)

                ForEach(viewModel.sortedDays, id: \.dateString) { stats in
                    archiveListRow(stats: stats)
                }
            }
        }
        .padding(.top, 8)
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
                .foregroundColor(DSColor.inkSubtle)

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
        .liquidGlassCard(cornerRadius: DSSpacing.radiusCard)
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
                .foregroundColor(accent ? DSColor.amberDeep : DSColor.inkPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(label)
                .monoLabelStyle(size: 9)
                .foregroundColor(DSColor.inkSubtle)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var digestDivider: some View {
        Rectangle()
            .fill(DSColor.inkFaint)
            .frame(width: 0.5, height: 28)
    }

    private static let isoParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM d"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// 将 "yyyy-MM-dd" 转换为 "APRIL 14"（MMMM d, en_US, 全大写）。
    private func formatArchiveDate(_ dateString: String) -> String {
        guard let date = Self.isoParser.date(from: dateString) else { return dateString }
        return Self.monthDayFormatter.string(from: date).uppercased()
    }

    /// 人性化日期标签：TODAY / YESTERDAY / N DAYS AGO / APRIL 14。
    private func relativeDateLabel(_ dateString: String) -> String {
        guard let date = Self.isoParser.date(from: dateString) else { return dateString }
        let cal = Calendar.current
        let now = Date()
        if cal.isDateInToday(date) { return "TODAY" }
        if cal.isDateInYesterday(date) { return "YESTERDAY" }
        let daysDiff = cal.dateComponents([.day], from: date, to: now).day ?? 0
        if daysDiff > 0 && daysDiff < 7 { return "\(daysDiff) DAYS AGO" }
        return formatArchiveDate(dateString)
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
            .liquidGlassCard(cornerRadius: DSSpacing.radiusCard)
            .pressableCard()
        }
        .buttonStyle(.plain)
    }

    private func metaIcon(_ systemName: String, count: Int, unit: String? = nil) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemName)
                .font(DSType.labelXS)
                .foregroundColor(DSColor.inkSubtle)
            Text(unit != nil ? "\(count) \(unit!)" : "\(count)")
                .monoLabelStyle(size: 11)
                .foregroundColor(DSColor.inkSubtle)
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

// MARK: - ArtifactGeometricView

/// 黑白极简装饰图案，呼应"考古档案"设计语言。
/// 渲染带径向刻度线的同心圆 — 令人联想到罗盘或档案封印。
private struct ArtifactGeometricView: View {

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let outerR = min(size.width, size.height) / 2 - 1
            let white   = Color.white
            let dimmed  = Color.white.opacity(0.25)

            // --- Outer ring ---
            context.stroke(
                Path { p in p.addArc(center: center, radius: outerR, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false) },
                with: .color(white.opacity(0.5)),
                lineWidth: 1
            )

            // --- Middle ring ---
            context.stroke(
                Path { p in p.addArc(center: center, radius: outerR * 0.72, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false) },
                with: .color(white.opacity(0.35)),
                lineWidth: 0.75
            )

            // --- Inner ring ---
            context.stroke(
                Path { p in p.addArc(center: center, radius: outerR * 0.44, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false) },
                with: .color(white.opacity(0.25)),
                lineWidth: 0.75
            )

            // --- Center dot ---
            let dotR: CGFloat = 3
            context.fill(
                Path { p in p.addArc(center: center, radius: dotR, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false) },
                with: .color(white.opacity(0.6))
            )

            // --- Radial tick marks (24 major + 24 minor) ---
            let totalTicks = 48
            for i in 0..<totalTicks {
                let angle = Double(i) * (360.0 / Double(totalTicks))
                let rad   = angle * .pi / 180
                let isMajor = i % 2 == 0
                let tickOuter = outerR
                let tickInner = isMajor ? outerR * 0.86 : outerR * 0.92
                let color = isMajor ? white.opacity(0.55) : dimmed

                let outer = CGPoint(
                    x: center.x + tickOuter * CGFloat(cos(rad)),
                    y: center.y + tickOuter * CGFloat(sin(rad))
                )
                let inner = CGPoint(
                    x: center.x + tickInner * CGFloat(cos(rad)),
                    y: center.y + tickInner * CGFloat(sin(rad))
                )

                context.stroke(
                    Path { p in p.move(to: outer); p.addLine(to: inner) },
                    with: .color(color),
                    lineWidth: isMajor ? 1 : 0.5
                )
            }

            // --- Cross hair lines ---
            let crossR = outerR * 0.38
            let crossColor = white.opacity(0.2)
            for angleDeg in [0.0, 90.0] {
                let rad = angleDeg * .pi / 180
                let p1 = CGPoint(x: center.x - crossR * CGFloat(cos(rad)), y: center.y - crossR * CGFloat(sin(rad)))
                let p2 = CGPoint(x: center.x + crossR * CGFloat(cos(rad)), y: center.y + crossR * CGFloat(sin(rad)))
                context.stroke(
                    Path { p in p.move(to: p1); p.addLine(to: p2) },
                    with: .color(crossColor),
                    lineWidth: 0.5
                )
            }
        }
        .accessibilityHidden(true)
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
