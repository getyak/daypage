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

/// Statistics for a single day in the Archive.
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
        case 0: return .empty
        case 1...2: return .low
        case 3...5: return .medium
        default: return .high
        }
    }

    enum DensityLevel {
        case empty, low, medium, high

        var fillColor: Color {
            switch self {
            case .empty:  return DSColor.heatmapEmpty
            case .low:    return DSColor.heatmapLow
            case .medium: return DSColor.heatmapMid
            case .high:   return DSColor.heatmapHigh
            }
        }

        var textColor: Color {
            switch self {
            case .empty, .low: return DSColor.onSurface
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

        /// Color for the bottom-right indicator dot.
        /// On today cells the dot matches the border (primary / white),
        /// otherwise it matches the cell's text color so it always contrasts
        /// with the heat-map background.
        func dotColor(isToday: Bool) -> Color {
            if isToday {
                // today border is DSColor.primary (black); use onPrimary so dot is visible
                return DSColor.onPrimary
            }
            return textColor
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
        isLoading = true
        var result: [String: DayStats] = [:]
        let rawDir = VaultInitializer.vaultURL.appendingPathComponent("raw")
        let dailyDir = VaultInitializer.vaultURL.appendingPathComponent("wiki/daily")

        let daysInMonth = numberOfDays(year: currentYear, month: currentMonth)

        for day in 1...daysInMonth {
            var comps = DateComponents()
            comps.year = currentYear
            comps.month = currentMonth
            comps.day = day
            guard let date = Calendar.current.date(from: comps) else { continue }
            let dateStr = dateFormatter.string(from: date)

            let rawURL = rawDir.appendingPathComponent("\(dateStr).md")
            let dailyURL = dailyDir.appendingPathComponent("\(dateStr).md")

            var memoCount = 0
            var photoCount = 0
            var voiceSeconds = 0
            var uniqueLocations = Set<String>()

            if let content = (try? String(contentsOf: rawURL, encoding: .utf8)) {
                let memos: [Memo]?
                do { memos = try RawStorage.read(for: date) }
                catch { memos = nil; DayPageLogger.shared.error("ArchiveView: read memos: \(error)") }
                memoCount = memos?.count ?? countMemoBlocks(in: content)
                for memo in (memos ?? []) {
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

            let isDailyCompiled = FileManager.default.fileExists(atPath: dailyURL.path)
            var dailySummary: String? = nil
            if isDailyCompiled {
                if let content = (try? String(contentsOf: dailyURL, encoding: .utf8)) {
                    dailySummary = extractSummary(from: content)
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

        dayStats = result
        isLoading = false
    }

    // MARK: Monthly Aggregates

    var totalEntries: Int { dayStats.values.reduce(0) { $0 + $1.memoCount } }

    // MARK: System Status

    /// Derived system status based on the current month's compilation state.
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

    // MARK: Calendar Helpers

    func daysInCurrentMonth() -> [Int?] {
        let total = numberOfDays(year: currentYear, month: currentMonth)
        let firstWeekday = firstWeekdayOfMonth(year: currentYear, month: currentMonth)
        // Monday-first: offset (Mon=0, Tue=1..Sun=6)
        let offset = (firstWeekday + 5) % 7   // Convert Sun=1..Sat=7 to Mon=0..Sun=6
        var cells: [Int?] = Array(repeating: nil, count: offset)
        cells += (1...total).map { Optional($0) }
        // Pad to multiple of 7
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

    private func extractSummary(from content: String) -> String? {
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("summary:") {
                let value = String(trimmed.dropFirst("summary:".count))
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }
}

// MARK: - ArchiveView

struct ArchiveView: View {

    @StateObject private var viewModel = ArchiveViewModel()
    @State private var mode: ArchiveMode = .calendar
    @State private var selectedDateString: String? = nil
    @State private var showDayDetail: Bool = false
    @State private var showSearch: Bool = false
    @State private var summaryFilter: MonthlySummaryFilter = .all
    @State private var showShareSheet: Bool = false
    @State private var shareItems: [Any] = []
    @Environment(\.colorScheme) private var colorScheme

    // MARK: - Pre-scanned vault sets (US-006)
    //
    // Populated asynchronously on appear. Drives the three-state calendar cell
    // visual: daily compiled → solid highlight; raw only → dot marker;
    // neither → 50% translucent gray (still tappable).
    @State private var rawDates: Set<String> = []
    @State private var dailyDates: Set<String> = []

    var body: some View {
        NavigationStack {
            ZStack {
                DSColor.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    archiveHeader

                    Divider().background(DSColor.outline)

                    ScrollView {
                        VStack(spacing: 0) {
                            monthNavigationRow
                                .padding(.horizontal, 20)
                                .padding(.vertical, 16)

                            if mode == .calendar {
                                calendarGrid
                                    .padding(.horizontal, 12)

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
                }
            }
            .navigationBarHidden(true)
            .onAppear {
                viewModel.loadMonth()
                Task { await preScanVault() }
            }
            .fullScreenCover(isPresented: $showDayDetail) {
                if let dateStr = selectedDateString {
                    DayDetailView(dateString: dateStr)
                }
            }
            .sheet(isPresented: $showSearch) {
                SearchView { dateStr in
                    selectedDateString = dateStr
                    showSearch = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        showDayDetail = true
                    }
                }
            }
        }
    }

    // MARK: - Navigation Helper

    /// Every calendar cell is tappable (US-006). DayDetailView itself handles the
    /// `.empty` / `.error` / `.rawOnly` / `.compiled` states — see US-002.
    private func handleDateTap(dateStr: String) {
        selectedDateString = dateStr
        showDayDetail = true
    }

    // MARK: - Vault Pre-Scan (US-006)

    /// Lists `vault/raw/*.md` and `vault/wiki/daily/*.md` off-main and publishes
    /// the discovered date strings into `@State` sets. Non-blocking; failures
    /// degrade to empty sets (calendar falls back to "no data" visual — still tappable).
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
        HStack(spacing: 10) {
            // Calendar icon (decorative)
            Image(systemName: "calendar")
                .font(.system(size: 18, weight: .regular))
                .foregroundColor(DSColor.onSurface)

            Text("ARCHIVE")
                .font(.custom("SpaceGrotesk-Bold", size: 20))
                .foregroundColor(DSColor.onSurface)
                .kerning(2)

            Spacer()

            Button(action: { showSearch = true }) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundColor(DSColor.onSurface)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("搜索")
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    // MARK: - Month Navigation Row

    private var monthNavigationRow: some View {
        HStack {
            // Left arrow
            Button(action: { viewModel.goToPreviousMonth() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(DSColor.onSurface)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)

            Text(viewModel.currentMonthTitle)
                .font(.custom("SpaceGrotesk-Bold", size: 20))
                .foregroundColor(DSColor.primary)
                .frame(maxWidth: .infinity, alignment: .center)

            Button(action: { viewModel.goToNextMonth() }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(DSColor.onSurface)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)

            // CALENDAR / LIST toggle
            HStack(spacing: 0) {
                toggleButton("CAL", isSelected: mode == .calendar) { mode = .calendar }
                toggleButton("LIST", isSelected: mode == .list) { mode = .list }
            }
            .overlay(Rectangle().stroke(DSColor.outlineVariant, lineWidth: 1))
        }
    }

    private func toggleButton(_ label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .monoLabelStyle(size: 10)
                .foregroundColor(isSelected ? DSColor.onPrimary : DSColor.onSurfaceVariant)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isSelected ? DSColor.primary : Color.clear)
        }
        .buttonStyle(.plain)
        .cornerRadius(0)
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
        .background(DSColor.surfaceContainerLow)
        .overlay(
            Rectangle()
                .stroke(DSColor.outlineVariant, lineWidth: 1)
        )
    }

    /// Three-state classification for a calendar cell (US-006).
    /// Derived from the pre-scanned `dailyDates` / `rawDates` sets.
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

            let fillColor: Color = {
                switch data {
                case .compiled: return DSColor.primary
                case .rawOnly:  return DSColor.surfaceContainerLow
                case .none:     return DSColor.surfaceContainerLow.opacity(0.5)
                }
            }()

            let textColor: Color = {
                switch data {
                case .compiled: return DSColor.onPrimary
                case .rawOnly:  return DSColor.onSurface
                case .none:     return DSColor.onSurface.opacity(0.5)
                }
            }()

            let dotColor: Color = {
                // Dot appears only in .rawOnly state; keep it primary-tinted so
                // it reads as a positive "has data" signal.
                isToday ? DSColor.primary : DSColor.onSurface
            }()

            Button(action: {
                handleDateTap(dateStr: dateStr)
            }) {
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(fillColor)
                        .overlay(
                            Rectangle()
                                .stroke(isToday ? DSColor.primary : DSColor.outlineVariant,
                                        lineWidth: isToday ? 2 : 0.5)
                        )

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
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(accessibilityLabel(dateStr: dateStr, state: data))
        } else {
            Rectangle()
                .fill(DSColor.surfaceContainerLowest.opacity(0.3))
                .overlay(Rectangle().stroke(DSColor.outlineVariant, lineWidth: 0.5))
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
        }
    }

    private func accessibilityLabel(dateStr: String, state: CellDataState) -> String {
        switch state {
        case .compiled: return "\(dateStr)，已编译 Daily Page"
        case .rawOnly:  return "\(dateStr)，有原始记录"
        case .none:     return "\(dateStr)，无记录"
        }
    }

    // MARK: - Heatmap Legend

    private var legendRow: some View {
        HStack(spacing: 8) {
            Text("Activity:")
                .monoLabelStyle(size: 9)
                .foregroundColor(DSColor.onSurfaceVariant)

            ForEach([DayStats.DensityLevel.empty, .low, .medium, .high], id: \.label) { level in
                Rectangle()
                    .fill(level.fillColor)
                    .frame(width: 12, height: 12)
                    .overlay(Rectangle().stroke(DSColor.outlineVariant, lineWidth: 0.5))
            }

            Text("Higher Density")
                .monoLabelStyle(size: 9)
                .foregroundColor(DSColor.onSurfaceVariant)

            Spacer()
        }
    }

    // MARK: - Monthly Summary

    private var monthlySummary: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Text("\(viewModel.currentMonthTitle) SUMMARY")
                    .font(.custom("SpaceGrotesk-Bold", size: 11))
                    .foregroundColor(DSColor.outline)
                    .kerning(2)
                Rectangle()
                    .fill(DSColor.outlineVariant)
                    .frame(height: 1)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                summaryCard("TOTAL ENTRIES", value: "\(viewModel.totalEntries)", accentPrimary: true)
                summaryCard("VOICE DURATION", value: "\(viewModel.totalVoiceMinutes)", unit: "min", accentPrimary: false)
                summaryCard("PHOTOS CAPTURED", value: "\(viewModel.totalPhotos)", accentPrimary: false)
                summaryCard("TRAVEL LOCATIONS", value: "\(viewModel.totalLocations)", accentPrimary: true)
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
                    VStack(spacing: 4) {
                        ForEach(filtered, id: \.dateString) { stats in
                            Button(action: { handleDateTap(dateStr: stats.dateString) }) {
                                HStack {
                                    Text(formatArchiveDate(stats.dateString))
                                        .monoLabelStyle(size: 11)
                                        .foregroundColor(DSColor.onSurface)
                                    Spacer()
                                    if stats.photoCount > 0 {
                                        Label("\(stats.photoCount)", systemImage: "photo")
                                            .monoLabelStyle(size: 10)
                                            .foregroundColor(DSColor.onSurfaceVariant)
                                    }
                                    if stats.uniqueLocations > 0 {
                                        Label("\(stats.uniqueLocations)", systemImage: "mappin")
                                            .monoLabelStyle(size: 10)
                                            .foregroundColor(DSColor.onSurfaceVariant)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(DSColor.surfaceContainer)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            // Export / Share actions
            HStack(spacing: 12) {
                Button(action: exportMarkdown) {
                    Label("导出 Markdown", systemImage: "square.and.arrow.up")
                        .monoLabelStyle(size: 11)
                        .foregroundColor(DSColor.onSurface)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(DSColor.surfaceContainer)
                        .overlay(Rectangle().stroke(DSColor.outlineVariant, lineWidth: 1))
                }
                .buttonStyle(.plain)

                Button {
                    Task { await shareScreenshot() }
                } label: {
                    Label("截图分享", systemImage: "camera")
                        .monoLabelStyle(size: 11)
                        .foregroundColor(DSColor.onSurface)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(DSColor.surfaceContainer)
                        .overlay(Rectangle().stroke(DSColor.outlineVariant, lineWidth: 1))
                }
                .buttonStyle(.plain)

                Spacer()
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheetView(activityItems: shareItems)
        }
    }

    private func filterChip(_ filter: MonthlySummaryFilter) -> some View {
        let isSelected = summaryFilter == filter
        return Button(action: { summaryFilter = filter }) {
            Text(filter.rawValue)
                .monoLabelStyle(size: 10)
                .foregroundColor(isSelected ? DSColor.onPrimary : DSColor.onSurfaceVariant)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isSelected ? DSColor.primary : DSColor.surfaceContainer)
                .overlay(Rectangle().stroke(DSColor.outlineVariant, lineWidth: 1))
        }
        .buttonStyle(.plain)
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
        let image = PosterRenderer.render(
            monthTitle: viewModel.currentMonthTitle,
            totalEntries: viewModel.totalEntries,
            totalPhotos: viewModel.totalPhotos,
            totalVoiceMinutes: viewModel.totalVoiceMinutes,
            totalLocations: viewModel.totalLocations
        )
        shareItems = [image]
        showShareSheet = true
    }

    private func summaryCard(_ label: String, value: String, unit: String? = nil, accentPrimary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .monoLabelStyle(size: 10)
                .foregroundColor(DSColor.onSurfaceVariant)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.custom("SpaceGrotesk-Bold", size: 48))
                    .foregroundColor(DSColor.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if let unit {
                    Text(unit.uppercased())
                        .monoLabelStyle(size: 10)
                        .foregroundColor(DSColor.onSurfaceVariant)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 120)
        .background(DSColor.surfaceContainer)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(accentPrimary ? DSColor.primary : DSColor.outline)
                .frame(width: 4)
        }
        .cornerRadius(0)
    }

    // MARK: - System Status Artifact

    private var systemStatusArtifact: some View {
        VStack(spacing: 0) {
            // Top divider line
            Rectangle()
                .fill(DSColor.outlineVariant)
                .frame(height: 1)

            ZStack {
                DSColor.onSurface.opacity(0.96)
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
        case .synchronized:       return DSColor.onBackgroundSubtle
        case .pendingCompilation: return DSColor.warningAmber
        case .offline:            return DSColor.errorRed
        }
    }

    // MARK: - List Content

    private var listContent: some View {
        LazyVStack(spacing: 8) {
            if viewModel.sortedDays.isEmpty {
                Text("本月暂无记录")
                    .bodySMStyle()
                    .foregroundColor(DSColor.onSurfaceVariant)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 40)
            } else {
                ForEach(viewModel.sortedDays, id: \.dateString) { stats in
                    archiveListRow(stats: stats)
                }
            }
        }
        .padding(.top, 8)
    }

    /// Converts "yyyy-MM-dd" to "APRIL 14" (MMMM d, en_US, all caps).
    private func formatArchiveDate(_ dateString: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        guard let date = parser.date(from: dateString) else { return dateString }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date).uppercased()
    }

    /// Human-friendly date label: TODAY / YESTERDAY / N DAYS AGO / APRIL 14.
    private func relativeDateLabel(_ dateString: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        guard let date = parser.date(from: dateString) else { return dateString }
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
            HStack(spacing: 0) {
                Rectangle()
                    .fill(DSColor.primary)
                    .frame(width: 4)
                    .opacity(isMetadataOnly ? 0.8 : 1.0)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(relativeDateLabel(stats.dateString))
                            .font(.custom("SpaceGrotesk-Bold", size: 15))
                            .foregroundColor(DSColor.onSurface)
                            .opacity(isMetadataOnly ? 0.8 : 1.0)

                        Spacer()

                        StatusBadge(
                            label: stats.isDailyPageCompiled ? "VERIFIED" : "METADATA",
                            style: stats.isDailyPageCompiled ? .verified : .metadata
                        )
                    }

                    if let summary = stats.dailySummary, !summary.isEmpty {
                        Text(summary)
                            .bodySMStyle()
                            .foregroundColor(DSColor.onSurfaceVariant)
                            .italic()
                            .lineLimit(2)
                            .opacity(isMetadataOnly ? 0.8 : 1.0)
                    }

                    HStack(spacing: 16) {
                        metaIcon("doc.text", count: stats.memoCount)
                        metaIcon("photo", count: stats.photoCount)
                        metaIcon("mic", count: stats.voiceMinutes, unit: "min")
                    }
                    .opacity(isMetadataOnly ? 0.8 : 1.0)
                }
                .padding(DSSpacing.cardGap)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DSColor.surfaceContainer)
            }
            .cornerRadius(DSSpacing.radiusCard)
            .surfaceElevatedShadow()
            .pressableCard()
        }
        .buttonStyle(.plain)
    }

    private func metaIcon(_ systemName: String, count: Int, unit: String? = nil) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemName)
                .font(.system(size: 10))
                .foregroundColor(DSColor.onSurfaceVariant)
            Text(unit != nil ? "\(count) \(unit!)" : "\(count)")
                .monoLabelStyle(size: 11)
                .foregroundColor(DSColor.onSurfaceVariant)
        }
    }
}

// MARK: - ArchiveVaultScan (US-006)

/// File-scoped helpers for the pre-scan that runs off-main on ArchiveView appear.
/// Kept outside the view so the `Task.detached` closure can call it without
/// capturing `self` (which would defeat the `@MainActor`-free goal).
fileprivate enum ArchiveVaultScan {

    /// Returns the set of `YYYY-MM-DD` basenames of `.md` files directly under `dir`.
    /// Ignores non-matching filenames (assets/, attachments, etc.). Missing
    /// directories degrade to an empty set — the calendar then renders every cell
    /// as the "no data" state, still tappable.
    static func listDateFilenames(in dir: URL, fileManager: FileManager) -> Set<String> {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        var out: Set<String> = []
        for name in entries {
            guard name.hasSuffix(".md") else { continue }
            let base = String(name.dropLast(3))  // strip ".md"
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

// MARK: - ShareSheetView

private struct ShareSheetView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - ArtifactGeometricView

/// Black-and-white minimal decorative graphic echoing the "archaeological archive" design language.
/// Renders concentric rings with radial tick marks — evoking a compass or archival seal.
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
