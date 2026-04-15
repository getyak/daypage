import SwiftUI

// MARK: - ArchiveMode

enum ArchiveMode {
    case calendar
    case list
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
            case .empty:  return Color(hex: "F9F9F9")
            case .low:    return Color(hex: "E8E8E8")
            case .medium: return Color(hex: "474747")
            case .high:   return Color(hex: "000000")
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

            if let content = try? String(contentsOf: rawURL, encoding: .utf8) {
                let memos = try? RawStorage.read(for: date)
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
            if isDailyCompiled, let content = try? String(contentsOf: dailyURL, encoding: .utf8) {
                dailySummary = extractSummary(from: content)
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
    @State private var showDailyPage: Bool = false

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
            .onAppear { viewModel.loadMonth() }
            .fullScreenCover(isPresented: $showDailyPage) {
                if let dateStr = selectedDateString {
                    DailyPageView(dateString: dateStr)
                }
            }
        }
    }

    // MARK: - Archive Header

    private var archiveHeader: some View {
        HStack {
            Text("ARCHIVE")
                .headlineMDStyle()
                .foregroundColor(DSColor.onSurface)
            Spacer()
            Text(Date(), format: .dateTime.month(.wide).year())
                .monoLabelStyle(size: 11)
                .foregroundColor(DSColor.onSurfaceVariant)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
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
        VStack(spacing: 2) {
            // Weekday header row
            HStack(spacing: 2) {
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
                HStack(spacing: 2) {
                    ForEach(rows[rowIdx].indices, id: \.self) { colIdx in
                        let dayNum = rows[rowIdx][colIdx]
                        calendarCell(dayNum: dayNum)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func calendarCell(dayNum: Int?) -> some View {
        if let day = dayNum {
            let dateStr = viewModel.dateString(day: day)
            let stats = viewModel.dayStats[dateStr]
            let density = stats?.densityLevel ?? .empty
            let isToday = viewModel.isCurrentMonthAndYear && day == viewModel.today

            Button(action: {
                selectedDateString = dateStr
                if stats?.isDailyPageCompiled == true {
                    showDailyPage = true
                }
            }) {
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(density.fillColor)
                        .overlay(
                            Rectangle()
                                .stroke(isToday ? DSColor.primary : DSColor.outlineVariant,
                                        lineWidth: isToday ? 2 : 0.5)
                        )

                    Text(String(format: "%02d", day))
                        .monoLabelStyle(size: 9)
                        .foregroundColor(density.textColor)
                        .padding(4)
                }
                .aspectRatio(1, contentMode: .fit)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
        } else {
            Rectangle()
                .fill(DSColor.surfaceContainerLowest.opacity(0.3))
                .overlay(Rectangle().stroke(DSColor.outlineVariant, lineWidth: 0.5))
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
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
                summaryCard("UNIQUE LOCATIONS", value: "\(viewModel.totalLocations)", accentPrimary: true)
            }
        }
    }

    private func summaryCard(_ label: String, value: String, unit: String? = nil, accentPrimary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .monoLabelStyle(size: 10)
                .foregroundColor(DSColor.onSurfaceVariant)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.custom("SpaceGrotesk-Bold", size: 36))
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

    private func archiveListRow(stats: DayStats) -> some View {
        Button(action: {
            selectedDateString = stats.dateString
            if stats.isDailyPageCompiled {
                showDailyPage = true
            }
        }) {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(DSColor.primary)
                    .frame(width: 4)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(stats.dateString.uppercased())
                            .font(.custom("SpaceGrotesk-Bold", size: 15))
                            .foregroundColor(DSColor.onSurface)

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
                    }

                    HStack(spacing: 16) {
                        metaIcon("doc.text", count: stats.memoCount)
                        metaIcon("photo", count: stats.photoCount)
                        metaIcon("mic", count: stats.voiceMinutes, unit: "min")
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DSColor.surfaceContainer)
            }
            .cornerRadius(0)
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

// MARK: - Array+Chunked Helper

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
