import SwiftUI
import DayPageModels
import DayPageServices

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
// Today is colored by its real memo count (amber strokeBorder marks it as today);
// empty-today gets a dashed ghost border. Future cells render as a dashed placeholder.
// Counts map to 4 tonal buckets via the heatmap-* color tokens.

struct SidebarHeatmapView: View {
    /// Memo count per day keyed by `YYYY-MM-DD`.
    let counts: [String: Int]
    /// Total entries across the window (header figure).
    let totalEntries: Int
    /// Current consecutive-day streak (footer pill).
    let streak: Int
    /// All-time longest consecutive-day streak (footer fallback when streak == 0).
    let longestStreak: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selectedCell: (date: Date, count: Int)? = nil
    @State private var selectedColumnIndex: Int = 0
    @State private var tooltipDismissGeneration: Int = 0
    @State private var firstEntryGlow: Bool = false

    private let weeks = 16
    private let cellSpacing: CGFloat = 3

    private static let monthFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMM"
        return f
    }()

    private static let monthDayFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMM d"
        return f
    }()

    private static let palette: [Color] = [
        DSColor.heatmapEmpty, DSColor.heatmapLow, DSColor.heatmapMid, DSColor.heatmapHigh,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityText)
            // Hide the 105-cell grid from VoiceOver entirely. The header above
            // already exposes the full summary (`accessibilityText` — e.g. "15
            // weeks heatmap, 3 days with entries, current streak 1"), so the
            // per-cell labels were 100+ identical "Jun 15, 0 entries" rotor
            // stops with no extra signal. Sighted users still tap cells for
            // the day-detail tooltip; VoiceOver users navigate days via the
            // Recent rows below the grid.
            grid.accessibilityHidden(true)
            footer
                // Footer = LESS/MORE swatches + streak pill — the swatches are a
                // pure legend (no signal beyond the accessibilityText already
                // exposed by `header`), and the streak pill duplicates the
                // streak phrase in `accessibilityText`. Hide the whole row from
                // VoiceOver so users land on the next focusable element instead
                // of trekking through 7+ decorative children.
                .accessibilityHidden(true)
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
                Text(NSLocalizedString("heatmap.entries", comment: "Entries unit"))
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
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                monthLabels(columns: columns)
                    // MAR / APR / MAY are purely visual context for the grid —
                    // each day cell already announces its own MMM-d in its
                    // accessibilityLabel, so reading these labels aloud is
                    // duplicative.
                    .accessibilityHidden(true)
                GeometryReader { geo in
                    let cell = cellSize(in: geo.size.width)
                    HStack(spacing: cellSpacing) {
                        ForEach(columns.indices, id: \.self) { ci in
                            VStack(spacing: cellSpacing) {
                                ForEach(0..<7, id: \.self) { ri in
                                    cellView(columns[ci][ri], size: cell, columnIndex: ci)
                                }
                            }
                        }
                    }
                    .overlay(alignment: .top) {
                        if let sel = selectedCell {
                            let tooltipText = "\(Self.monthDayFmt.string(from: sel.date).uppercased()) · \(sel.count) 条"
                            let xOffset = CGFloat(selectedColumnIndex) * (cell + cellSpacing) + cell / 2
                            Text(tooltipText)
                                .font(DSType.mono9)
                                .tracking(0.8)
                                .foregroundColor(DSColor.inkPrimary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(DSColor.surfaceWhite)
                                        .overlay(
                                            Capsule(style: .continuous)
                                                .strokeBorder(DSColor.borderSubtle, lineWidth: 0.5)
                                        )
                                        .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 2)
                                )
                                .fixedSize()
                                .position(x: xOffset, y: -14)
                                .transition(
                                    reduceMotion
                                        ? .opacity
                                        : .opacity.combined(with: .scale(scale: 0.88, anchor: .bottom))
                                )
                                .animation(reduceMotion ? .default : .spring(response: 0.22, dampingFraction: 0.7), value: sel.date)
                                .allowsHitTesting(false)
                                .zIndex(10)
                        }
                    }
                    .animation(reduceMotion ? .default : .spring(response: 0.22, dampingFraction: 0.7), value: selectedCell?.date)
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
    private func cellView(_ cell: HeatCell, size: CGFloat, columnIndex: Int) -> some View {
        switch cell {
        case .future:
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .strokeBorder(DSColor.borderSubtle, style: StrokeStyle(lineWidth: 0.5, dash: [1.5, 1.5]))
                .frame(height: 11)
                .accessibilityHidden(true)
        case .day(let date, let level, let isToday, let count):
            let isTodayEmpty = isToday && level == 0
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(Self.palette[level])
                .frame(height: 11)
                .overlay(
                    // Dashed ghost border for an unstarted today — reads as "open, awaiting capture"
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .strokeBorder(
                            isTodayEmpty ? DSColor.borderSubtle : .clear,
                            style: StrokeStyle(lineWidth: 0.5, dash: [1.5, 1.5])
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .strokeBorder(Color.black.opacity(level == 3 ? 0.06 : 0), lineWidth: 0.5)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .strokeBorder(isToday ? DSColor.accentOnBg : .clear, lineWidth: 1)
                )
                .shadow(
                    color: isToday && firstEntryGlow ? DSColor.accentAmber.opacity(0.55) : .clear,
                    radius: firstEntryGlow ? 4 : 0
                )
                .onChange(of: count) { newCount in
                    if isToday && newCount == 1 && !reduceMotion {
                        withAnimation(.easeOut(duration: 0.25)) { firstEntryGlow = true }
                        Task {
                            try? await Task.sleep(nanoseconds: 600_000_000)
                            withAnimation(.easeOut(duration: 0.5)) { firstEntryGlow = false }
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if let sel = selectedCell, Calendar.current.isDate(sel.date, inSameDayAs: date) {
                        selectedCell = nil
                    } else {
                        selectedCell = (date: date, count: count)
                        selectedColumnIndex = columnIndex
                        Haptics.soft()
                        tooltipDismissGeneration += 1
                        let gen = tooltipDismissGeneration
                        Task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            if tooltipDismissGeneration == gen {
                                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                                    selectedCell = nil
                                }
                            }
                        }
                    }
                }
                // Per-cell a11y intentionally omitted: the parent `grid` is
                // .accessibilityHidden(true), so VoiceOver gets a single
                // summary line from the heatmap header instead of 105
                // identical "Jun 15, 0 entries" rotor stops.
        }
    }

    private func monthLabels(columns: [[HeatCell]]) -> some View {
        // Mark a label at the first column whose top cell starts a new month.
        var seenMonths = Set<Int>()
        var labels: [(col: Int, text: String)] = []
        let cal = Calendar.current
        for (ci, col) in columns.enumerated() {
            let firstDay = col.first(where: { if case .day = $0 { return true } else { return false } })
            if case let .day(date, _, _, _) = firstDay {
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
                streakPill(
                    icon: "flame.fill",
                    text: "\(streak) DAYS",
                    fg: DSColor.accentAmber,
                    bg: DSColor.accentSoft,
                    border: DSColor.accentBorder
                )
            } else if longestStreak > 0 {
                streakPill(
                    icon: "flame",
                    text: "BEST \(longestStreak) DAYS",
                    fg: DSColor.inkSubtle,
                    bg: DSColor.glassStd,
                    border: DSColor.borderSubtle
                )
            }
        }
    }

    private func streakPill(icon: String, text: String, fg: Color, bg: Color, border: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(fg)
            Text(text)
                .font(DSType.mono9)
                .tracking(1.2)
                .foregroundColor(fg)
                .fixedSize()
        }
        .padding(.init(top: 4, leading: 7, bottom: 4, trailing: 9))
        .background(bg, in: Capsule())
        .overlay(Capsule().strokeBorder(border, lineWidth: 0.5))
    }

    private var accessibilityText: String {
        let base = "活动热力图，过去 16 周共 \(totalEntries) 条记录"
        if streak > 0 {
            return "\(base)，当前连续 \(streak) 天"
        } else if longestStreak > 0 {
            return "\(base)，当前连续 0 天，历史最佳 \(longestStreak) 天"
        }
        return base
    }

    // MARK: - Grid data

    /// A single heatmap cell.
    private enum HeatCell {
        case day(Date, level: Int, isToday: Bool, count: Int)
        case future
    }

    /// Build 16 columns (weeks) × 7 rows (Mon→Sun) ending with today's week.
    private func buildColumns() -> [[HeatCell]] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let todayStr = DateFormatters.isoDate.string(from: today)

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
                    let key = DateFormatters.isoDate.string(from: date)
                    let count = counts[key] ?? 0
                    let isToday = key == todayStr
                    let lvl = level(for: count)
                    col.append(.day(date, level: lvl, isToday: isToday, count: count))
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
