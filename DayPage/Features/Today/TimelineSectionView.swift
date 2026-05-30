import SwiftUI

// MARK: - TimelineSectionView
//
// One band of the Today historical timeline rendered as a continuous
// "kakejiku" (掛軸) museum spine — a single 0.5pt vertical hairline running
// through every row, with a marker shape that encodes granularity
// (dot → bar → ring → concentric). Content floats on bg-warm with NO card
// chrome, NO rounded corners, NO shadow — the serif title and inter lede
// hang off the spine like a scroll.
//
// Design source of truth: .design-handoff/v8/app.jsx:590-720
// (Timeline / TimelineSection / TimelineRow / DayRow / WeekRowItem /
//  MonthRow / YearRow / RowMeta). Faithful web port:
// web/src/app/(app)/today/WeekFeedSpine.tsx.
//
// The iOS data model currently only produces day-level entries
// (`TimelineSectionKind` = thisWeekOthers / lastWeek / weekBeforeLast /
// month). The four marker shapes & row builders are all implemented so the
// week/month/year granularities are structurally ready the moment the
// view-model starts emitting coarser buckets — matching how the web groups
// 本周 BY DAY · 本月 BY WEEK · 今年 BY MONTH · 历年 BY YEAR.

struct TimelineSectionView: View {

    let section: TimelineSection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TimelineSpine.SectionHeader(label: headerLabel, sub: headerSub)
            spineBody
        }
        // app.jsx:609 — section { marginBottom: 22 } (12 for the last band).
        .padding(.bottom, TimelineSpine.sectionGap)
    }

    // MARK: Spine + rows

    /// The relative-positioned region: a fixed-x hairline behind the rows.
    /// app.jsx:617-624 — `padding: 8px 22px 4px`, spine inset top:18 bottom:6.
    private var spineBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(section.days.enumerated()), id: \.element.id) { index, day in
                TimelineDayRow(
                    entry: day,
                    isFirst: index == 0,
                    isLast: index == section.days.count - 1
                )
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
        .padding(.horizontal, TimelineSpine.sectionPadH)
        .background(alignment: .topLeading) {
            // ONE continuous hairline, fixed left x, behind every row.
            // app.jsx:618 — width:0.5, var(--border-subtle), top:18 bottom:6.
            Rectangle()
                .fill(DSTokens.Colors.borderSubtle)
                .frame(width: 0.5)
                .padding(.leading, TimelineSpine.spineX - 0.25)
                .padding(.top, 18)
                .padding(.bottom, 6)
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: Section header copy

    /// Left display caption — 本周 / 本月 / 今年 + month name. app.jsx:612.
    private var headerLabel: String {
        switch section.kind {
        case .thisWeekOthers:
            return NSLocalizedString("today.timeline.thisWeek", value: "本周", comment: "Timeline band")
        case .lastWeek:
            return NSLocalizedString("today.timeline.lastWeek", value: "上周", comment: "Timeline band")
        case .weekBeforeLast:
            return NSLocalizedString("today.timeline.weekBeforeLast", value: "前两周", comment: "Timeline band")
        case .month(let date):
            let f = DateFormatter()
            f.dateFormat = "MMMM yyyy"
            f.locale = Locale.current
            f.timeZone = TimeZone.current
            return f.string(from: date)
        }
    }

    /// Right mono caption — "BY DAY · N条". app.jsx:598-601, 614.
    private var headerSub: String {
        let n = section.days.count
        return "BY DAY · \(n) 条"
    }
}

// MARK: - TimelineDayRow

/// One day row hung off the spine. Tap to expand — that day's raw memos load
/// lazily inline (no navigation, see #276). The collapsed presentation is the
/// faithful museum row: mono day / display date nameplate · accent dot ·
/// serif title · inter lede · mono meta footer.
struct TimelineDayRow: View {

    let entry: TimelineDayEntry
    let isFirst: Bool
    let isLast: Bool

    @State private var isExpanded: Bool = false
    @State private var loadedMemos: [Memo] = []
    @State private var hasLoaded: Bool = false

    var body: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 0) {
                rowScaffold
                if isExpanded {
                    expandedMemos
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(isExpanded
            ? NSLocalizedString("today.timeline.collapse", value: "Collapse", comment: "")
            : NSLocalizedString("today.timeline.expand", value: "Expand", comment: ""))
    }

    // MARK: Row scaffold — nameplate | marker | content

    /// app.jsx:631-647 — grid 52px | 1fr, columnGap 24, paddingTop 26
    /// (0 first), paddingBottom 26 (6 last). The marker is overlaid in the
    /// gap so it sits exactly on the spine.
    private var rowScaffold: some View {
        HStack(alignment: .top, spacing: TimelineSpine.columnGap) {
            nameplate
            content
        }
        .padding(.top, isFirst ? 0 : 26)
        .padding(.bottom, isLast ? 6 : 26)
        // Marker overlaid on the spine — top-leading so the dot lines up with
        // the title regardless of content height. app.jsx:654.
        .overlay(alignment: .topLeading) {
            TimelineSpine.DayMarker()
                .offset(
                    x: TimelineSpine.rowSpineX - TimelineSpine.DayMarker.size / 2,
                    y: (isFirst ? 0 : 26) + 11
                )
        }
    }

    /// Left nameplate column — right-aligned mono weekday + display date.
    /// app.jsx:638-643 (mono 9.5 / display 13).
    private var nameplate: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(weekdayLabel)
                .font(DSFonts.jetBrainsMono(size: 9.5, weight: .bold))
                .tracking(1.8)
                .textCase(.uppercase)
                .foregroundColor(DSTokens.Colors.fgSubtle)
            Text(monthDayLabel)
                .font(DSFonts.spaceGrotesk(size: 13, weight: .semibold))
                .tracking(-0.1)
                .foregroundColor(DSTokens.Colors.fgPrimary)
        }
        .frame(width: TimelineSpine.nameplateWidth, alignment: .trailing)
        .padding(.top, 6)
    }

    /// Right content column — serif title, inter lede, mono meta footer.
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title = displayTitle {
                TimelineSpine.RowTitle(text: title, size: 20)
            }
            if let lede = displayLede {
                TimelineSpine.RowLede(text: lede)
                    .padding(.top, 10)        // app.jsx:656 margin:'10px 0 0'
                    .lineLimit(isExpanded ? nil : 3)
            }
            TimelineSpine.RowMeta(tags: metaTags, right: { wordsRight })
                .padding(.top, 14)            // app.jsx:705 marginTop:14
        }
        .padding(.leading, 6)                 // app.jsx:645 paddingLeft:6
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Right-aligned word count for a day row. app.jsx:657.
    private var wordsRight: some View {
        HStack(spacing: 4) {
            Text("\(approxWordCount)")
                .font(DSFonts.jetBrainsMono(size: 9.5, weight: .bold))
                .foregroundColor(DSTokens.Colors.fgMuted)
            Text("WORDS")
                .font(DSFonts.jetBrainsMono(size: 9.5, weight: .bold))
                .foregroundColor(DSTokens.Colors.fgMuted.opacity(0.6))
        }
        .tracking(1.3)
    }

    // MARK: Expanded memo list

    private var expandedMemos: some View {
        VStack(spacing: 8) {
            ForEach(loadedMemos, id: \.id) { memo in
                MemoCardView(memo: memo)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.leading, TimelineSpine.nameplateWidth + TimelineSpine.columnGap + 6)
        .padding(.bottom, 18)
    }

    // MARK: Interaction

    private func toggle() {
        if !hasLoaded {
            Task {
                let memos = TimelineService.memos(for: entry)
                await MainActor.run {
                    loadedMemos = memos
                    hasLoaded = true
                }
            }
        }
        withAnimation(.easeInOut(duration: DSTokens.Motion.fast)) {
            isExpanded.toggle()
        }
    }

    // MARK: Derived content

    /// Compiled summary acts as the serif title (the day's "成稿" headline).
    /// Falls back to the formatted date when the day hasn't compiled yet so
    /// the row still reads as a museum plate rather than an empty card.
    private var displayTitle: String? {
        if let summary = entry.summary, !summary.isEmpty {
            // First sentence / line as the title; keeps the serif headline tight.
            let firstLine = summary
                .split(whereSeparator: { $0 == "\n" || $0 == "。" })
                .first.map(String.init) ?? summary
            return firstLine
        }
        return longDateLabel
    }

    /// Lede only when a compiled summary spills past its title line.
    private var displayLede: String? {
        guard let summary = entry.summary, !summary.isEmpty else { return nil }
        guard let title = displayTitle, summary.count > title.count + 1 else { return nil }
        let remainder = summary.dropFirst(title.count)
            .drop(while: { $0 == "\n" || $0 == "。" || $0 == " " })
        let text = String(remainder)
        return text.isEmpty ? nil : text
    }

    private var metaTags: [String] {
        // No tag model on TimelineDayEntry yet — surface memo count as a
        // single mono tag so the footer keeps its rhythm (web shows item.tags).
        [memoCountTag]
    }

    // MARK: Formatters

    private var weekdayLabel: String {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f.string(from: entry.date).uppercased()
    }

    /// Display date for the nameplate — mirrors web's `item.date` (e.g. 05.30).
    private var monthDayLabel: String {
        let f = DateFormatter()
        f.dateFormat = "MM.dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f.string(from: entry.date)
    }

    private var longDateLabel: String {
        let f = DateFormatter()
        f.dateFormat = "M月d日"
        f.locale = Locale.current
        f.timeZone = TimeZone.current
        return f.string(from: entry.date)
    }

    private var memoCountTag: String {
        let n = entry.memoCount
        let fallback = n == 1 ? "1 MEMO" : "\(n) MEMOS"
        let key = n == 1 ? "today.timeline.memoCount.one" : "today.timeline.memoCount.other"
        let format = NSLocalizedString(key, value: fallback, comment: "Memo count chip")
        return String(format: format, n)
    }

    /// Rough word/character count to mirror the web's `item.words`. Uses the
    /// summary length as a cheap proxy (no raw file read when collapsed).
    private var approxWordCount: Int {
        guard let summary = entry.summary, !summary.isEmpty else { return entry.memoCount }
        return summary.count
    }

    private var accessibilityLabel: String {
        let summaryText = entry.summary.flatMap { $0.isEmpty ? nil : $0 } ?? memoCountTag
        return "\(entry.dateString), \(summaryText)"
    }
}

// MARK: - TimelineSpine

/// Shared geometry, markers, and typed text primitives for the museum spine.
/// All four granularity markers are implemented so coarser buckets render
/// faithfully the moment the view-model emits them. app.jsx:606-718.
enum TimelineSpine {

    // MARK: Geometry

    /// Section internal horizontal padding. app.jsx:611/617 — 22.
    static let sectionPadH: CGFloat = 22
    /// Left nameplate column width. app.jsx:634 — 52.
    static let nameplateWidth: CGFloat = 52
    /// Gap between nameplate and content. app.jsx:634 — columnGap 24.
    static let columnGap: CGFloat = 24
    /// Trailing band margin. app.jsx:609 — marginBottom 22.
    static let sectionGap: CGFloat = 22

    /// Spine x within the padded spine body (nameplate + half the gap).
    /// app.jsx:607 — `const SPINE = 22 + 52 + 12` minus the section's own
    /// 22 left padding (already applied) → 52 + 12 = 64.
    static let rowSpineX: CGFloat = nameplateWidth + columnGap / 2   // 64
    /// Spine x relative to the spine-body's leading edge (post-padding).
    static let spineX: CGFloat = rowSpineX                            // 64

    // MARK: Markers (shape encodes granularity)

    /// DAY — solid 7pt accent dot. app.jsx:654.
    struct DayMarker: View {
        static let size: CGFloat = 7
        var body: some View {
            Circle()
                .fill(DSTokens.Colors.accent)
                .frame(width: Self.size, height: Self.size)
                .background(halo(radius: 4))
        }
    }

    /// WEEK — short 18×3pt horizontal bar (a span, not a point). app.jsx:666.
    struct WeekMarker: View {
        static let width: CGFloat = 18
        static let height: CGFloat = 3
        var body: some View {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(DSTokens.Colors.accent)
                .frame(width: Self.width, height: Self.height)
                .background(halo(radius: 4))
        }
    }

    /// MONTH — hollow 11pt accent ring (1.6pt border). app.jsx:678.
    struct MonthMarker: View {
        static let size: CGFloat = 11
        var body: some View {
            Circle()
                .fill(DSTokens.Colors.bgWarm)
                .frame(width: Self.size, height: Self.size)
                .overlay(
                    Circle().strokeBorder(DSTokens.Colors.accent, lineWidth: 1.6)
                )
                .background(halo(radius: 3))
        }
    }

    /// YEAR — concentric 15pt ring + 5pt inner accent dot. app.jsx:690-693.
    struct YearMarker: View {
        static let size: CGFloat = 15
        var body: some View {
            Circle()
                .fill(DSTokens.Colors.bgWarm)
                .frame(width: Self.size, height: Self.size)
                .overlay(
                    Circle().strokeBorder(DSTokens.Colors.accent, lineWidth: 1.6)
                )
                .overlay(
                    Circle()
                        .fill(DSTokens.Colors.accent)
                        .frame(width: 5, height: 5)
                )
                .background(halo(radius: 3))
        }
    }

    /// bg-warm halo behind a marker so it punches cleanly through the spine.
    /// CSS `boxShadow: 0 0 0 Npx var(--bg-warm)`.
    private static func halo(radius: CGFloat) -> some View {
        Circle()
            .fill(DSTokens.Colors.bgWarm)
            .padding(-radius)
    }

    // MARK: Typed text primitives

    /// Serif row title. Size scales 20/20/22/24 across day/week/month/year;
    /// letter-spacing tightens as it grows. app.jsx:655/667/679/695.
    struct RowTitle: View {
        let text: String
        let size: CGFloat
        var body: some View {
            let tracking: CGFloat = size >= 24 ? -0.6 : (size >= 22 ? -0.5 : -0.4)
            return Text(text)
                .font(DSFonts.serif(size: size, weight: .semibold))
                .tracking(tracking)
                .foregroundColor(DSTokens.Colors.fgPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
    }

    /// Inter body lede, 3-line clamp, 0.85 opacity. app.jsx:656.
    struct RowLede: View {
        let text: String
        var body: some View {
            Text(text)
                .font(DSFonts.inter(size: 14))
                .tracking(0.1)
                .lineSpacing(14 * 0.7)        // line-height 1.7 ≈ +0.7em leading
                .foregroundColor(DSTokens.Colors.fgPrimary.opacity(0.85))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Mono meta footer — tags separated by · with a right-aligned count.
    /// app.jsx:702-718.
    struct RowMeta<Right: View>: View {
        let tags: [String]
        @ViewBuilder let right: () -> Right
        var body: some View {
            HStack(alignment: .center, spacing: 9) {
                ForEach(Array(tags.enumerated()), id: \.offset) { index, tag in
                    if index > 0 {
                        Text("·")
                            .font(DSFonts.jetBrainsMono(size: 9.5, weight: .bold))
                            .foregroundColor(DSTokens.Colors.fgSubtle.opacity(0.55))
                    }
                    Text(tag)
                        .font(DSFonts.jetBrainsMono(size: 9.5, weight: .bold))
                        .tracking(1.6)
                        .foregroundColor(DSTokens.Colors.fgSubtle)
                }
                Spacer(minLength: 12)
                right()
            }
        }
    }

    // MARK: Section header

    /// Hairline-bounded mono caption. app.jsx:611-615.
    struct SectionHeader: View {
        let label: String
        let sub: String
        var body: some View {
            HStack(alignment: .lastTextBaseline, spacing: 14) {
                Text(label)
                    .font(DSFonts.spaceGrotesk(size: 13, weight: .bold))
                    .tracking(1.5)
                    .foregroundColor(DSTokens.Colors.fgPrimary)
                Rectangle()
                    .fill(DSTokens.Colors.borderSubtle)
                    .frame(height: 0.5)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 2)
                Text(sub)
                    .font(DSFonts.jetBrainsMono(size: 9.5, weight: .bold))
                    .tracking(1.6)
                    .foregroundColor(DSTokens.Colors.fgSubtle)
            }
            .padding(.horizontal, sectionPadH)
            .padding(.top, 10)
            .padding(.bottom, 14)
        }
    }
}
