import SwiftUI

// MARK: - SidebarHeatmapView
//
// Museum-aesthetic 16-week × 7-day contribution heatmap — the visual hero of
// the redesigned sidebar (Claude Design bundle — detail.jsx DrawerHeatmap).
//
//   ┌────────────────────────────────────────────┐
//   │ LAST 16 WEEKS                    89 ENTRIES  │
//   │      FEB    MAR    APR    MAY                │
//   │ M  ▢▢▣▣▢▢▣▣▢▢▣▣▢▢▣▣                          │
//   │ T  …                                         │
//   │ LESS ▢▢▢▢ MORE          🔥 23 DAYS            │
//   └────────────────────────────────────────────┘
//
// Columns are weeks (oldest → newest left→right); rows are weekdays Mon→Sun.
// Today is forced to the highest tone; future cells render as a dashed
// placeholder. Counts map to 4 tonal buckets via the heatmap-* color tokens.

struct SidebarHeatmapView: View {
    /// Memo count per day keyed by `YYYY-MM-DD`.
    let counts: [String: Int]
    /// Total entries across the window (header figure).
    let totalEntries: Int
    /// Current consecutive-day streak (footer pill).
    let streak: Int

    private let weeks = 16
    private let cellSpacing: CGFloat = 3

    private static let isoFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f
    }()

    private static let monthFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMM"
        return f
    }()

    private static let palette: [Color] = [
        DSColor.heatmapEmpty, DSColor.heatmapLow, DSColor.heatmapMid, DSColor.heatmapHigh,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            grid
            footer
        }
        .padding(.init(top: 16, leading: 16, bottom: 14, trailing: 16))
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(DSColor.surfaceWhite)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(DSColor.borderSubtle, lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.04), radius: 1, x: 0, y: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("活动热力图，过去 16 周共 \(totalEntries) 条记录，当前连续 \(streak) 天")
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("LAST 16 WEEKS")
                .font(DSType.mono10)
                .tracking(1.6)
                .foregroundColor(DSColor.inkMuted)
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(totalEntries)")
                    .font(DSFonts.serif(size: 18, weight: .semibold))
                    .foregroundColor(DSColor.inkPrimary)
                Text("ENTRIES")
                    .font(DSType.mono9)
                    .tracking(1.2)
                    .foregroundColor(DSColor.inkSubtle)
            }
        }
    }

    // MARK: - Grid

    private var grid: some View {
        let columns = buildColumns()
        return HStack(alignment: .top, spacing: 8) {
            // Weekday rail: M T W T F S S
            VStack(spacing: cellSpacing) {
                Spacer().frame(height: 11) // align under the month-label row
                ForEach(Array(["M", "T", "W", "T", "F", "S", "S"].enumerated()), id: \.offset) { idx, d in
                    Text(d)
                        .font(.system(size: 8, design: .monospaced))
                        .tracking(1)
                        .foregroundColor(DSColor.inkSubtle)
                        .opacity(idx % 2 == 1 ? 0.4 : 0.9)
                        .frame(height: 11)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                monthLabels(columns: columns)
                GeometryReader { geo in
                    let cell = cellSize(in: geo.size.width)
                    HStack(spacing: cellSpacing) {
                        ForEach(columns.indices, id: \.self) { ci in
                            VStack(spacing: cellSpacing) {
                                ForEach(0..<7, id: \.self) { ri in
                                    cellView(columns[ci][ri], size: cell)
                                }
                            }
                        }
                    }
                }
                .frame(height: 7 * 11 + 6 * cellSpacing)
            }
        }
    }

    private func cellSize(in width: CGFloat) -> CGFloat {
        let total = width - CGFloat(weeks - 1) * cellSpacing
        return max(8, total / CGFloat(weeks))
    }

    @ViewBuilder
    private func cellView(_ cell: HeatCell, size: CGFloat) -> some View {
        switch cell {
        case .future:
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .strokeBorder(DSColor.borderSubtle, style: StrokeStyle(lineWidth: 0.5, dash: [1.5, 1.5]))
                .frame(height: 11)
        case .day(_, let level, let isToday):
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(Self.palette[level])
                .frame(height: 11)
                .overlay(
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .strokeBorder(Color.black.opacity(level == 3 ? 0.06 : 0), lineWidth: 0.5)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .strokeBorder(isToday ? DSColor.accentAmber : .clear, lineWidth: 1)
                )
        }
    }

    private func monthLabels(columns: [[HeatCell]]) -> some View {
        // Mark a label at the first column whose top cell starts a new month.
        var seenMonths = Set<Int>()
        var labels: [(col: Int, text: String)] = []
        let cal = Calendar.current
        for (ci, col) in columns.enumerated() {
            let firstDay = col.first(where: { if case .day = $0 { return true } else { return false } })
            if case let .day(date, _, _) = firstDay {
                let m = cal.component(.month, from: date)
                if !seenMonths.contains(m) {
                    seenMonths.insert(m)
                    labels.append((ci, Self.monthFmt.string(from: date).uppercased()))
                }
            }
        }
        return GeometryReader { geo in
            let cell = cellSize(in: geo.size.width)
            ForEach(labels, id: \.col) { item in
                Text(item.text)
                    .font(.system(size: 8, design: .monospaced))
                    .tracking(1.2)
                    .foregroundColor(DSColor.inkSubtle)
                    .offset(x: CGFloat(item.col) * (cell + cellSpacing))
            }
        }
        .frame(height: 9)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            HStack(spacing: 5) {
                Text("LESS")
                    .font(DSType.mono9).tracking(1.2)
                    .foregroundColor(DSColor.inkSubtle)
                ForEach(Self.palette.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Self.palette[i])
                        .frame(width: 9, height: 9)
                }
                Text("MORE")
                    .font(DSType.mono9).tracking(1.2)
                    .foregroundColor(DSColor.inkSubtle)
            }
            Spacer()
            if streak > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 10))
                        .foregroundColor(DSColor.accentAmber)
                    Text("\(streak) DAYS")
                        .font(DSType.mono9)
                        .tracking(1.2)
                        .foregroundColor(DSColor.accentAmber)
                        .fixedSize()
                }
                .padding(.init(top: 4, leading: 7, bottom: 4, trailing: 9))
                .background(DSColor.accentSoft, in: Capsule())
                .overlay(Capsule().strokeBorder(DSColor.accentBorder, lineWidth: 0.5))
            }
        }
    }

    // MARK: - Grid data

    /// A single heatmap cell.
    private enum HeatCell {
        case day(Date, level: Int, isToday: Bool)
        case future
    }

    /// Build 16 columns (weeks) × 7 rows (Mon→Sun) ending with today's week.
    private func buildColumns() -> [[HeatCell]] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let todayStr = Self.isoFmt.string(from: today)

        // Find the Monday on/just before today to anchor the current column.
        // Swift Calendar weekday: 1=Sun…7=Sat. Convert to days since Monday.
        let wd = cal.component(.weekday, from: today)
        let monOffset = (wd + 5) % 7
        guard let thisMonday = cal.date(byAdding: .day, value: -monOffset, to: today) else { return [] }

        var columns: [[HeatCell]] = []
        for w in stride(from: weeks - 1, through: 0, by: -1) {
            guard let weekMonday = cal.date(byAdding: .day, value: -7 * w, to: thisMonday) else { continue }
            var col: [HeatCell] = []
            for d in 0..<7 {
                guard let date = cal.date(byAdding: .day, value: d, to: weekMonday) else { continue }
                if date > today {
                    col.append(.future)
                } else {
                    let key = Self.isoFmt.string(from: date)
                    let count = counts[key] ?? 0
                    let isToday = key == todayStr
                    let lvl = isToday ? 3 : level(for: count)
                    col.append(.day(date, level: lvl, isToday: isToday))
                }
            }
            columns.append(col)
        }
        return columns
    }

    /// Map a memo count to one of 4 tonal buckets.
    private func level(for count: Int) -> Int {
        switch count {
        case 0: return 0
        case 1: return 1
        case 2...3: return 2
        default: return 3
        }
    }
}
