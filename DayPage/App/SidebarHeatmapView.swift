import SwiftUI
import UIKit
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
//
// PERFORMANCE (2026-07): the grid is a single `Canvas` draw call. The previous
// implementation composed 112 cell views × (fill + 3 stroke overlays + gesture
// + onChange) ≈ 800 view nodes and rebuilt all 112 dates (~120 DateFormatter
// calls) on EVERY body evaluation — and SidebarView re-evaluates whenever any
// @Published on the shared nav model ticks, so opening/dragging the drawer
// paid that cost repeatedly and stuttered. Now the grid geometry is cached in
// a `HeatGrid` snapshot rebuilt only when `counts` actually changes, and the
// whole board renders as one vector layer. Tap detection is plain coordinate
// math; the tooltip and first-entry glow stay as lightweight overlays so they
// keep their SwiftUI animations.

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

    @State private var grid = HeatGrid()
    @State private var selectedDay: HeatGrid.Day? = nil
    @State private var selectedColumnIndex: Int = 0
    @State private var tooltipDismissGeneration: Int = 0
    @State private var firstEntryGlow: Bool = false

    private let weeks = 16
    private let cellSpacing: CGFloat = 3
    private let cellHeight: CGFloat = 11
    /// Leading column reserved for the M/T/W… weekday letters (incl. gap).
    private let railWidth: CGFloat = 14
    /// Month-label row (9pt text + 5pt gap) above the first cell row.
    private let monthRowHeight: CGFloat = 14

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
            // Hide the grid from VoiceOver entirely. The header above already
            // exposes the full summary (`accessibilityText` — e.g. "15 weeks
            // heatmap, 3 days with entries, current streak 1"); per-cell labels
            // were 100+ identical "Jun 15, 0 entries" rotor stops with no extra
            // signal. Sighted users still tap cells for the day-detail tooltip;
            // VoiceOver users navigate days via the Recent rows below the grid.
            gridView.accessibilityHidden(true)
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
        .onAppear {
            if grid.columns.isEmpty {
                grid = HeatGrid.build(counts: counts, weeks: weeks)
            }
        }
        .onChange(of: counts) { newCounts in
            let previousTodayCount = grid.todayCount
            grid = HeatGrid.build(counts: newCounts, weeks: weeks)
            // First entry of the day → brief amber glow on today's cell.
            if grid.todayCount == 1, previousTodayCount == 0, !reduceMotion {
                withAnimation(.easeOut(duration: 0.25)) { firstEntryGlow = true }
                Task {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    withAnimation(.easeOut(duration: 0.5)) { firstEntryGlow = false }
                }
            }
        }
        // Midnight / timezone / clock changes shift the "today" anchor even
        // when `counts` is unchanged — rebuild so the grid never shows a
        // stale today marker.
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.significantTimeChangeNotification
        )) { _ in
            grid = HeatGrid.build(counts: counts, weeks: weeks)
        }
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
                    .font(DSFonts.serif(size: 18, weight: .semibold, relativeTo: .headline))
                    .foregroundColor(DSColor.inkPrimary)
                Text(NSLocalizedString("heatmap.entries", comment: "Entries unit"))
                    .font(DSType.mono9)
                    .tracking(1.2)
                    .foregroundColor(DSColor.inkMuted)
            }
        }
    }

    // MARK: - Grid (single Canvas)

    private var gridHeight: CGFloat {
        monthRowHeight + 7 * cellHeight + 6 * cellSpacing
    }

    private func cellWidth(in width: CGFloat) -> CGFloat {
        let usable = width - railWidth - CGFloat(weeks - 1) * cellSpacing
        return max(8, usable / CGFloat(weeks))
    }

    private var gridView: some View {
        GeometryReader { geo in
            let cellW = cellWidth(in: geo.size.width)
            heatCanvas
                .overlay(alignment: .topLeading) {
                    if firstEntryGlow, let pos = grid.todayPosition {
                        todayGlow(position: pos, cellW: cellW)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let sel = selectedDay {
                        tooltip(for: sel, cellW: cellW)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { point in
                    handleTap(at: point, cellW: cellW)
                }
        }
        .frame(height: gridHeight)
    }

    /// One vector layer for the weekday rail, month labels and all 112 cells.
    private var heatCanvas: some View {
        Canvas { context, size in
            let cellW = cellWidth(in: size.width)

            // Weekday rail: M T W T F S S
            let letters = ["M", "T", "W", "T", "F", "S", "S"]
            for (ri, letter) in letters.enumerated() {
                let y = monthRowHeight + CGFloat(ri) * (cellHeight + cellSpacing) + cellHeight / 2
                let text = Text(letter)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(DSColor.inkSubtle.opacity(ri % 2 == 1 ? 0.4 : 0.9))
                context.draw(context.resolve(text), at: CGPoint(x: 5, y: y))
            }

            // Month labels along the top edge. Canvas clips to its bounds, so
            // a label anchored at the last column (e.g. "JUL") must be clamped
            // back inside the canvas or it renders truncated ("JU"). Clamping
            // can also drag a label leftwards onto its neighbour (a 16-week
            // window that opens late in a month puts two labels one column
            // apart → "MARAPR"), so any label that would start before the
            // previous one ended is dropped — a missing month reads better
            // than two fused ones.
            var prevLabelMaxX: CGFloat = -.infinity
            for label in grid.monthLabels {
                let rawX = railWidth + CGFloat(label.column) * (cellW + cellSpacing)
                let text = Text(label.text)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(DSColor.inkMuted)
                let resolved = context.resolve(text)
                let textWidth = resolved.measure(in: CGSize(width: 60, height: 12)).width
                let x = min(rawX, size.width - textWidth)
                guard x >= prevLabelMaxX + 6 else { continue }
                context.draw(resolved, at: CGPoint(x: x, y: 4.5), anchor: .leading)
                prevLabelMaxX = x + textWidth
            }

            // Day cells.
            let dashed = StrokeStyle(lineWidth: 0.5, dash: [1.5, 1.5])
            for (ci, column) in grid.columns.enumerated() {
                for (ri, day) in column.enumerated() {
                    let rect = CGRect(
                        x: railWidth + CGFloat(ci) * (cellW + cellSpacing),
                        y: monthRowHeight + CGFloat(ri) * (cellHeight + cellSpacing),
                        width: cellW,
                        height: cellHeight
                    )
                    let path = Path(roundedRect: rect, cornerRadius: 2.5, style: .continuous)

                    if day.isFuture {
                        // Dashed placeholder for days that haven't happened yet.
                        context.stroke(path, with: .color(DSColor.borderSubtle), style: dashed)
                        continue
                    }

                    context.fill(path, with: .color(Self.palette[day.level]))

                    if day.isToday && day.level == 0 {
                        // Dashed ghost border for an unstarted today — reads as
                        // "open, awaiting capture".
                        context.stroke(path, with: .color(DSColor.borderSubtle), style: dashed)
                    }
                    if day.level == 3 {
                        context.stroke(path, with: .color(.black.opacity(0.06)), lineWidth: 0.5)
                    }
                    if day.isToday {
                        context.stroke(path, with: .color(DSColor.accentOnBg), lineWidth: 1)
                    }
                }
            }
        }
    }

    /// Brief amber halo over today's cell when the first memo of the day
    /// lands. Kept as a SwiftUI overlay (not Canvas) so its fade animates.
    private func todayGlow(position: HeatGrid.CellPosition, cellW: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(Self.palette[grid.todayLevel])
            .frame(width: cellW, height: cellHeight)
            .shadow(color: DSColor.accentAmber.opacity(0.55), radius: 4)
            .offset(
                x: railWidth + CGFloat(position.column) * (cellW + cellSpacing),
                y: monthRowHeight + CGFloat(position.row) * (cellHeight + cellSpacing)
            )
            .transition(.opacity)
            .allowsHitTesting(false)
    }

    private func tooltip(for day: HeatGrid.Day, cellW: CGFloat) -> some View {
        // §3 language discipline: the count unit was a bare Chinese "条" that
        // showed even in an English locale, and never pluralized. Route it
        // through a localized .one/.other pair.
        let countUnit = String(
            format: NSLocalizedString(
                day.count == 1 ? "heatmap.tooltip.count.one" : "heatmap.tooltip.count.other",
                comment: "Heatmap tooltip entry count, %d = number of memos that day"
            ),
            day.count
        )
        let tooltipText = "\(Self.monthDayFmt.string(from: day.date).uppercased()) · \(countUnit)"
        let xOffset = railWidth + CGFloat(selectedColumnIndex) * (cellW + cellSpacing) + cellW / 2
        return Text(tooltipText)
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
            .position(x: xOffset, y: 0)
            .transition(
                reduceMotion
                    ? .opacity
                    : .opacity.combined(with: .scale(scale: 0.88, anchor: .bottom))
            )
            .animation(
                reduceMotion ? .default : .spring(response: 0.22, dampingFraction: 0.7),
                value: day.date
            )
            .allowsHitTesting(false)
            .zIndex(10)
    }

    /// Coordinate → cell hit test. The 3pt gutters between cells resolve to
    /// the nearest cell (floor), which doubles as fat-finger tolerance.
    private func handleTap(at point: CGPoint, cellW: CGFloat) {
        let ci = Int(floor((point.x - railWidth) / (cellW + cellSpacing)))
        let ri = Int(floor((point.y - monthRowHeight) / (cellHeight + cellSpacing)))
        guard ci >= 0, ci < grid.columns.count, ri >= 0, ri < 7 else { return }
        let day = grid.columns[ci][ri]
        guard !day.isFuture else { return }

        if let sel = selectedDay, Calendar.current.isDate(sel.date, inSameDayAs: day.date) {
            selectedDay = nil
            return
        }
        selectedDay = day
        selectedColumnIndex = ci
        Haptics.soft()
        tooltipDismissGeneration += 1
        let gen = tooltipDismissGeneration
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if tooltipDismissGeneration == gen {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                    selectedDay = nil
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            HStack(spacing: 5) {
                Text("LESS")
                    .font(DSType.mono9).tracking(1.2)
                    .foregroundColor(DSColor.inkMuted)
                ForEach(Self.palette.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Self.palette[i])
                        .frame(width: 9, height: 9)
                }
                Text("MORE")
                    .font(DSType.mono9).tracking(1.2)
                    .foregroundColor(DSColor.inkMuted)
            }
            Spacer()
            if streak > 0 {
                streakPill(
                    icon: "flame.fill",
                    text: "\(streak) \(Self.dayUnit(streak))",
                    fg: DSColor.accentAmber,
                    bg: DSColor.accentSoft,
                    border: DSColor.accentBorder
                )
            } else if longestStreak > 0 {
                streakPill(
                    icon: "flame",
                    text: "BEST \(longestStreak) \(Self.dayUnit(longestStreak))",
                    fg: DSColor.inkSubtle,
                    bg: DSColor.glassStd,
                    border: DSColor.borderSubtle
                )
            }
        }
    }

    /// Archival mono label unit (intentionally untranslated, FINDING-010) —
    /// but never "1 DAYS".
    private static func dayUnit(_ n: Int) -> String { n == 1 ? "DAY" : "DAYS" }

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
        // §3 language discipline: was a hardcoded Chinese sentence read verbatim
        // by VoiceOver even in an English locale. Routed through localized
        // format strings.
        let base = String(
            format: NSLocalizedString(
                "heatmap.a11y.base",
                comment: "Heatmap VoiceOver summary, %d = entries in the last 16 weeks"
            ),
            totalEntries
        )
        if streak > 0 {
            return String(
                format: NSLocalizedString(
                    "heatmap.a11y.current_streak",
                    comment: "Heatmap VoiceOver: %1$@ = base summary, %2$d = current streak days"
                ),
                base, streak
            )
        } else if longestStreak > 0 {
            return String(
                format: NSLocalizedString(
                    "heatmap.a11y.best_streak",
                    comment: "Heatmap VoiceOver: %1$@ = base summary, %2$d = longest streak days"
                ),
                base, longestStreak
            )
        }
        return base
    }
}

// MARK: - HeatGrid (cached geometry snapshot)

/// Immutable snapshot of everything the heatmap Canvas needs to draw a frame.
/// Built once per `counts` change instead of on every body evaluation, so the
/// ~120 Calendar/DateFormatter calls no longer run on unrelated view updates.
private struct HeatGrid: Equatable {

    struct Day: Equatable {
        let date: Date
        let level: Int
        let isToday: Bool
        let count: Int
        let isFuture: Bool
    }

    struct MonthLabel: Equatable {
        let column: Int
        let text: String
    }

    struct CellPosition: Equatable {
        let column: Int
        let row: Int
    }

    var columns: [[Day]] = []
    var monthLabels: [MonthLabel] = []
    var todayPosition: CellPosition? = nil
    var todayCount: Int = 0
    var todayLevel: Int = 0

    private static let monthFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMM"
        return f
    }()

    /// Build `weeks` columns (weeks) × 7 rows (Mon→Sun) ending with today's week.
    static func build(counts: [String: Int], weeks: Int) -> HeatGrid {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let todayStr = DateFormatters.isoDate.string(from: today)

        // Find the Monday on/just before today to anchor the current column.
        // Swift Calendar weekday: 1=Sun…7=Sat. Convert to days since Monday.
        let wd = cal.component(.weekday, from: today)
        let monOffset = (wd + 5) % 7
        guard let thisMonday = cal.date(byAdding: .day, value: -monOffset, to: today) else {
            return HeatGrid()
        }

        var grid = HeatGrid()
        var seenMonths = Set<Int>()

        for w in stride(from: weeks - 1, through: 0, by: -1) {
            guard let weekMonday = cal.date(byAdding: .day, value: -7 * w, to: thisMonday) else { continue }
            let columnIndex = grid.columns.count
            var col: [Day] = []
            for d in 0..<7 {
                guard let date = cal.date(byAdding: .day, value: d, to: weekMonday) else { continue }
                if date > today {
                    col.append(Day(date: date, level: 0, isToday: false, count: 0, isFuture: true))
                    continue
                }
                let key = DateFormatters.isoDate.string(from: date)
                let count = counts[key] ?? 0
                let isToday = key == todayStr
                let lvl = level(for: count)
                col.append(Day(date: date, level: lvl, isToday: isToday, count: count, isFuture: false))

                if isToday {
                    grid.todayPosition = CellPosition(column: columnIndex, row: d)
                    grid.todayCount = count
                    grid.todayLevel = lvl
                }
                // Month label at the first column whose top row starts a new month.
                if d == 0 {
                    let m = cal.component(.month, from: date)
                    if !seenMonths.contains(m) {
                        seenMonths.insert(m)
                        grid.monthLabels.append(
                            MonthLabel(column: columnIndex, text: monthFmt.string(from: date).uppercased())
                        )
                    }
                }
            }
            grid.columns.append(col)
        }
        return grid
    }

    /// Map a memo count to one of 4 tonal buckets.
    static func level(for count: Int) -> Int {
        switch count {
        case 0: return 0
        case 1: return 1
        case 2...3: return 2
        default: return 3
        }
    }
}
