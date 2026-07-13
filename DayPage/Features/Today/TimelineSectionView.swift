import SwiftUI
import DayPageModels
import DayPageServices

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
    /// Shared zoom namespace from the Today root, so each row can act as the
    /// `matchedTransitionSource` for the DayDetailView it pushes (iOS 18+ zoom
    /// hero). Optional — previews / callers that don't wire it get a plain push.
    var zoomNamespace: Namespace.ID? = nil
    /// Parent-driven actions invoked by each row. All are optional so the
    /// section view stays usable in previews and from call sites that haven't
    /// wired the new gesture vocabulary yet.
    var onOpenDate: ((String) -> Void)? = nil
    var onShareDate: ((TimelineDayEntry) -> Void)? = nil
    var onDeleteDate: ((TimelineDayEntry) -> Void)? = nil

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
                    isLast: index == section.days.count - 1,
                    zoomNamespace: zoomNamespace,
                    onOpenDate: onOpenDate,
                    onShareDate: onShareDate,
                    onDeleteDate: onDeleteDate
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
                .fill(DSColor.inkFaint)
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
        case .pinned:
            return NSLocalizedString("today.timeline.pinned", value: "📌 PINNED", comment: "Timeline band header for user-pinned days")
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

    /// Right mono caption — "BY DAY · N". app.jsx:598-601, 614.
    /// Pure mono-English, matching the untranslated MEMOS/WORDS row labels
    /// (FINDING-010 convention) — no mixed-script "N 条" tail.
    private var headerSub: String {
        let n = section.days.count
        return "BY DAY · \(n)"
    }
}

// MARK: - TimelineDayRow

/// One day row hung off the spine. The collapsed presentation is the faithful
/// museum row: mono day / display date nameplate · accent dot · serif title ·
/// inter lede · mono meta footer.
///
/// Gesture vocabulary (deliberately picked so every action has one obvious
/// home and the destructive one never sits on a swipe path):
///   • Tap            → open the Daily Page for this date (full-screen cover).
///   • Long-press     → system contextMenu with a preview card; menu items
///                      cover open / share / pin toggle / copy / delete.
///   • Right-swipe    → leading panel: pin / unpin (amber).
///   • Left-swipe     → trailing panel: share via system sheet (amber).
///   • Delete         → ONLY from the contextMenu, behind a destructive role
///                      and a confirmation alert. Never on a swipe.
struct TimelineDayRow: View {

    let entry: TimelineDayEntry
    let isFirst: Bool
    let isLast: Bool

    /// Shared zoom namespace from Today root — makes this row the
    /// `matchedTransitionSource` for the DayDetailView it pushes (iOS 18+).
    var zoomNamespace: Namespace.ID? = nil
    /// Parent-driven actions. All optional — when nil the corresponding
    /// gesture / menu item is hidden, so the row keeps working in previews.
    var onOpenDate: ((String) -> Void)? = nil
    var onShareDate: ((TimelineDayEntry) -> Void)? = nil
    var onDeleteDate: ((TimelineDayEntry) -> Void)? = nil

    @ObservedObject private var pinService = TimelinePinService.shared

    /// Loaded lazily on first long-press so the contextMenu preview card can
    /// show that day's memos without paying the parse cost on every cold
    /// scroll past the row.
    @State private var loadedMemos: [Memo] = []
    @State private var hasLoaded: Bool = false

    @State private var showDeleteConfirm: Bool = false

    // Swipe-to-reveal state (mirrors SwipeableMemoCard's vocabulary).
    @State private var settledOffset: CGFloat = 0
    @State private var dragDelta: CGFloat = 0
    @State private var isPanActive: Bool = false
    @State private var armedSide: SwipeSide? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isPinned: Bool { pinService.isPinned(entry.dateString) }

    fileprivate enum SwipeSide { case leading, trailing }

    var body: some View {
        rowZoomSource(
            gestureSurface
                .clipped()
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityHint(NSLocalizedString("today.timeline.openDailyPage", value: "Open Daily Page", comment: ""))
                .accessibilityAction(named: shareActionTitle) { onShareDate?(entry) }
                .accessibilityAction(named: pinActionTitle) { _ = pinService.togglePin(entry.dateString) }
                .contextMenu { menuButtons } preview: { previewCard }
                .alert(deleteAlertTitle, isPresented: $showDeleteConfirm, actions: deleteAlertActions, message: deleteAlertMessage)
        )
    }

    /// Tags the row as the zoom transition source keyed by its date, so the
    /// pushed DayDetailView (which carries a matching `CardZoomDestination`)
    /// grows out of this row on iOS 18+. No-op on iOS 17 / Reduce Motion / when
    /// no namespace was wired — the push just uses the default slide.
    @ViewBuilder
    private func rowZoomSource(_ content: some View) -> some View {
        if #available(iOS 18.0, *), let ns = zoomNamespace, !reduceMotion {
            content.matchedTransitionSource(id: entry.dateString, in: ns)
        } else {
            content
        }
    }

    // MARK: Body sub-views (kept small so SwiftUI's type-checker stays fast)

    /// ZStack carrying the swipe-translated content + the side panels.
    private var gestureSurface: some View {
        ZStack(alignment: .center) {
            rowContent
            sidePanels
        }
    }

    /// LAYER 1 — the museum row, offset by the live swipe translation. The
    /// UIKit pan/tap host sits as an overlay so vertical scrolls still belong
    /// to the parent ScrollView (see SwipeableMemoCard for the rationale).
    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            rowScaffold
        }
        .contentShape(Rectangle())
        .background(DSColor.bgWarm)
        .offset(x: currentOffset)
        .overlay(panGestureOverlay)
    }

    private var panGestureOverlay: some View {
        HorizontalPanGesture(
            isActive: $isPanActive,
            onChanged: handlePanChanged,
            onEnded: handlePanEnded,
            onCancelled: handlePanCancelled,
            onTap: handleRowTap,
            isEnabled: true
        )
    }

    /// LAYER 2 — both side panels. Hidden at rest; only hit-testable once a
    /// side is actually open so they never steal taps from the row.
    private var sidePanels: some View {
        HStack(spacing: 0) {
            TimelineSwipePanel(
                actions: leadingActions,
                edge: .leading,
                progress: max(0, revealProgress)
            )
            Spacer(minLength: 0)
            TimelineSwipePanel(
                actions: trailingActions,
                edge: .trailing,
                progress: max(0, -revealProgress)
            )
        }
        .allowsHitTesting(revealedSide != nil)
    }

    private var previewCard: some View {
        TimelineDayPreviewCard(entry: entry, memos: loadedMemos)
            .frame(width: 320, height: 360)
            .onAppear { ensureMemosLoaded() }
    }

    // MARK: Localized strings (computed once per render)

    private var shareActionTitle: String {
        NSLocalizedString("today.timeline.action.share", value: "Share", comment: "")
    }

    private var pinActionTitle: String {
        isPinned
            ? NSLocalizedString("today.timeline.action.unpin", value: "Unpin", comment: "")
            : NSLocalizedString("today.timeline.action.pin", value: "Pin", comment: "")
    }

    private var deleteAlertTitle: String {
        NSLocalizedString("today.timeline.delete.title", value: "Delete this day?", comment: "")
    }

    @ViewBuilder
    private func deleteAlertActions() -> some View {
        Button(NSLocalizedString("today.timeline.delete.confirm", value: "Delete", comment: ""), role: .destructive) {
            onDeleteDate?(entry)
        }
        Button(NSLocalizedString("today.timeline.delete.cancel", value: "Cancel", comment: ""), role: .cancel) {}
    }

    private func deleteAlertMessage() -> some View {
        let format = NSLocalizedString(
            "today.timeline.delete.message",
            value: "This will permanently remove %d memo(s) and the compiled summary for %@.",
            comment: "Delete-day confirmation body"
        )
        return Text(String(format: format, entry.memoCount, entry.dateString))
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
        // When the day is user-pinned the marker is replaced by a tiny pin
        // glyph so the row reads as "this one's mine" at a glance.
        .overlay(alignment: .topLeading) {
            Group {
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(DSColor.accentAmber)
                } else {
                    TimelineSpine.DayMarker()
                }
            }
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
                .font(DSFonts.jetBrainsMono(size: 9.5, weight: .bold, relativeTo: .caption2))
                .tracking(1.8)
                .textCase(.uppercase)
                .foregroundColor(DSColor.inkMuted)
            Text(monthDayLabel)
                .font(DSFonts.spaceGrotesk(size: 13, weight: .semibold, relativeTo: .footnote))
                .tracking(-0.1)
                .foregroundColor(DSColor.inkPrimary)
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
                    // app.jsx:656 margin:'10px 0 0' — only under a title;
                    // an uncompiled row's excerpt starts flush at the top.
                    .padding(.top, displayTitle == nil ? 0 : 10)
                    .lineLimit(3)
            }
            TimelineSpine.RowMeta(tags: metaTags, right: {
                // Word count only for compiled prose. Uncompiled days used
                // to fall back to memoCount here, printing "3 MEMOS … 3
                // WORDS" — fabricated data that always mirrored the left tag.
                if hasSummary { wordsRight }
            })
            .padding(.top, 14)                // app.jsx:705 marginTop:14
        }
        .padding(.leading, 6)                 // app.jsx:645 paddingLeft:6
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Right-aligned word count for a day row. app.jsx:657.
    private var wordsRight: some View {
        HStack(spacing: 4) {
            Text("\(approxWordCount)")
                .font(DSFonts.jetBrainsMono(size: 9.5, weight: .bold, relativeTo: .caption2))
                .foregroundColor(DSColor.inkMuted)
            Text(wordUnitLabel)
                .font(DSFonts.jetBrainsMono(size: 9.5, weight: .bold, relativeTo: .caption2))
                .foregroundColor(DSColor.inkMuted.opacity(0.6))
        }
        .tracking(1.3)
    }

    // MARK: Interaction

    /// Plain tap routes to the Daily Page. If a swipe panel is currently
    /// revealed, the tap closes it instead so users can dismiss a drawer
    /// without firing the underlying action.
    private func handleRowTap() {
        if revealedSide != nil {
            snapClose()
            return
        }
        Haptics.tapConfirm()
        onOpenDate?(entry.dateString)
    }

    /// Loads memos lazily for the contextMenu preview card.
    private func ensureMemosLoaded() {
        guard !hasLoaded else { return }
        Task {
            let memos = TimelineService.memos(for: entry)
            await MainActor.run {
                loadedMemos = memos
                hasLoaded = true
            }
        }
    }

    // MARK: Context menu items

    @ViewBuilder
    private var menuButtons: some View {
        Button {
            onOpenDate?(entry.dateString)
        } label: {
            Label(
                NSLocalizedString("today.timeline.menu.open", value: "Open Daily Page", comment: ""),
                systemImage: "book.pages"
            )
        }
        Button {
            onShareDate?(entry)
        } label: {
            Label(
                NSLocalizedString("today.timeline.menu.share", value: "Share", comment: ""),
                systemImage: "square.and.arrow.up"
            )
        }
        Button {
            _ = pinService.togglePin(entry.dateString)
            Haptics.tapConfirm()
        } label: {
            Label(
                isPinned
                    ? NSLocalizedString("today.timeline.menu.unpin", value: "Unpin", comment: "")
                    : NSLocalizedString("today.timeline.menu.pin", value: "Pin to top", comment: ""),
                systemImage: isPinned ? "pin.slash" : "pin"
            )
        }
        if let summary = entry.summary, !summary.isEmpty {
            Button {
                UIPasteboard.general.string = summary
                Haptics.soft()
            } label: {
                Label(
                    NSLocalizedString("today.timeline.menu.copy", value: "Copy summary", comment: ""),
                    systemImage: "doc.on.doc"
                )
            }
        }
        Divider()
        Button(role: .destructive) {
            showDeleteConfirm = true
        } label: {
            Label(
                NSLocalizedString("today.timeline.menu.delete", value: "Delete", comment: ""),
                systemImage: "trash"
            )
        }
    }

    // MARK: Swipe actions (mirrors SwipeableMemoCard's two-panel layout)

    private var leadingActions: [SwipeAction] {
        [
            SwipeAction(
                id: .pin,
                label: isPinned
                    ? NSLocalizedString("today.timeline.swipe.unpin", value: "Unpin", comment: "")
                    : NSLocalizedString("today.timeline.swipe.pin", value: "Pin", comment: ""),
                systemImage: isPinned ? "pin.slash.fill" : "pin.fill",
                tone: .accent,
                run: {
                    Haptics.tapConfirm()
                    snapClose()
                    // Sync with SwipeableMemoCard: wait for the snap animation
                    // to fully settle before firing the parent callback so any
                    // presented sheet / dialog can't animate over a still-open
                    // drawer. Same delay constant as SwipePhysics.actionCommitDelay.
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.actionCommitDelay) {
                        _ = pinService.togglePin(entry.dateString)
                    }
                }
            )
        ]
    }

    private var trailingActions: [SwipeAction] {
        [
            SwipeAction(
                id: .share,
                label: NSLocalizedString("today.timeline.swipe.share", value: "Share", comment: ""),
                systemImage: "square.and.arrow.up",
                tone: .accent,
                run: {
                    Haptics.tapConfirm()
                    snapClose()
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.actionCommitDelay) {
                        onShareDate?(entry)
                    }
                }
            )
        ]
    }

    /// Delay between `snapClose()` and firing the parent's action callback.
    /// Kept equal to SwipePhysics.actionCommitDelay so timeline rows and
    /// memo cards commit actions in lock-step.
    fileprivate static let actionCommitDelay: TimeInterval = 0.36

    // MARK: Pan callbacks (slimmed copy of SwipeableMemoCard's gesture loop)

    private var currentOffset: CGFloat {
        let raw = settledOffset + dragDelta
        let w = TimelineSwipePhysics.panelWidth
        if raw > w  { return w  + (raw - w)  * TimelineSwipePhysics.rubberBand }
        if raw < -w { return -w + (raw + w)  * TimelineSwipePhysics.rubberBand }
        return raw
    }

    private var revealProgress: CGFloat {
        let p = currentOffset / TimelineSwipePhysics.panelWidth
        return max(-1.4, min(1.4, p))
    }

    private var revealedSide: SwipeSide? {
        if settledOffset < -1 { return .trailing }
        if settledOffset > 1  { return .leading }
        return nil
    }

    private var snapAnimation: Animation {
        reduceMotion ? TimelineSwipePhysics.reducedSnap : TimelineSwipePhysics.snapSpring
    }

    private func handlePanChanged(_ translation: CGFloat) {
        dragDelta = translation
        let offset = currentOffset
        let arming: SwipeSide?
        if offset > TimelineSwipePhysics.openThreshold {
            arming = .leading
        } else if offset < -TimelineSwipePhysics.openThreshold {
            arming = .trailing
        } else {
            arming = nil
        }
        if arming != armedSide {
            armedSide = arming
            if arming != nil { Haptics.soft() }
        }
    }

    private func handlePanEnded(_ translation: CGFloat, _ velocity: CGFloat) {
        dragDelta = 0
        let openT = TimelineSwipePhysics.openThreshold
        let closeT = TimelineSwipePhysics.closeThreshold
        let vOpen = TimelineSwipePhysics.velocityOpen
        let vClose = TimelineSwipePhysics.velocityClose
        switch revealedSide {
        case nil:
            if      translation < -openT || velocity < -vOpen { snapOpen(.trailing) }
            else if translation >  openT || velocity >  vOpen { snapOpen(.leading)  }
            else                                              { snapClose()         }
        case .trailing:
            (translation > closeT || velocity > vClose) ? snapClose() : snapOpen(.trailing)
        case .leading:
            (translation < -closeT || velocity < -vClose) ? snapClose() : snapOpen(.leading)
        }
        armedSide = nil
    }

    private func handlePanCancelled() {
        dragDelta = 0
        armedSide = nil
    }

    private func snapOpen(_ side: SwipeSide) {
        let target: CGFloat = side == .trailing
            ? -TimelineSwipePhysics.panelWidth
            : TimelineSwipePhysics.panelWidth
        withAnimation(snapAnimation) { settledOffset = target }
        HapticFeedback.light()
    }

    private func snapClose() {
        withAnimation(snapAnimation) { settledOffset = 0 }
    }

    // MARK: Derived content

    private var hasSummary: Bool {
        guard let summary = entry.summary else { return false }
        return !summary.isEmpty
    }

    /// Compiled summary acts as the serif title (the day's "成稿" headline).
    /// Uncompiled days get NO serif title — the nameplate already states the
    /// date, and repeating it at 20pt serif was pure duplication. The serif
    /// voice is reserved for compiled prose; drafts speak through the lede.
    private var displayTitle: String? {
        guard let summary = entry.summary, !summary.isEmpty else { return nil }
        // First sentence / line as the title; keeps the serif headline tight.
        return summary
            .split(whereSeparator: { $0 == "\n" || $0 == "。" })
            .first.map(String.init) ?? summary
    }

    /// Lede: the compiled summary's spill-over — or, for uncompiled days,
    /// the first memo's opening line so the row smells of real content.
    private var displayLede: String? {
        guard let summary = entry.summary, !summary.isEmpty else {
            return entry.excerpt
        }
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
    //
    // These read from process-level cached formatters instead of allocating a
    // fresh `DateFormatter` per computed-var read. The Today history timeline
    // reads `weekdayLabel`/`monthDayLabel` per visible row, re-evaluated on
    // every scroll frame (the main scroll fires a ScrollOffsetPreferenceKey) —
    // a `DateFormatter()` alloc there is one of Foundation's most expensive
    // per-frame costs and showed up as visible scroll hitching.


    private var weekdayLabel: String {
        DateFormatters.weekdayShort.string(from: entry.date).uppercased()
    }

    /// Display date for the nameplate — mirrors web's `item.date` (e.g. 05.30).
    private var monthDayLabel: String {
        DateFormatters.monthDayDotted.string(from: entry.date)
    }

    private var memoCountTag: String {
        let n = entry.memoCount
        let fallback = n == 1 ? "1 MEMO" : "\(n) MEMOS"
        let key = n == 1 ? "today.timeline.memoCount.one" : "today.timeline.memoCount.other"
        let format = NSLocalizedString(key, value: fallback, comment: "Memo count chip")
        return String(format: format, n)
    }

    /// CJK-aware word count using the canonical counter from TodayViewModel.
    /// Only meaningful for compiled days — callers must gate on `hasSummary`
    /// (never fabricate a count from memoCount; see the RowMeta note).
    private var approxWordCount: Int {
        guard let summary = entry.summary, !summary.isEmpty else { return 0 }
        return TodayViewModel.wordCount(in: summary)
    }

    /// "字" when the summary is majority-CJK, "WORDS" otherwise.
    private var wordUnitLabel: String {
        guard let summary = entry.summary, !summary.isEmpty else { return "WORDS" }
        var cjkCount = 0
        var nonWhitespaceCount = 0
        for scalar in summary.unicodeScalars {
            let v = scalar.value
            guard !CharacterSet.whitespacesAndNewlines.contains(scalar) else { continue }
            nonWhitespaceCount += 1
            if (v >= 0x4E00 && v <= 0x9FFF)
                || (v >= 0x3400 && v <= 0x4DBF)
                || (v >= 0x20000 && v <= 0x2A6DF)
                || (v >= 0xF900 && v <= 0xFAFF)
                || (v >= 0x2E80 && v <= 0x2EFF)
                || (v >= 0x3000 && v <= 0x303F) {
                cjkCount += 1
            }
        }
        return (nonWhitespaceCount > 0 && cjkCount * 2 > nonWhitespaceCount) ? "字" : "WORDS"
    }

    private var accessibilityLabel: String {
        let summaryText = entry.summary.flatMap { $0.isEmpty ? nil : $0 }
            ?? entry.excerpt
            ?? memoCountTag
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
                .fill(DSColor.accentOnBg)
                .frame(width: Self.size, height: Self.size)
                .background(halo(radius: 4))
        }
    }

    /// bg-warm halo behind a marker so it punches cleanly through the spine.
    /// CSS `boxShadow: 0 0 0 Npx var(--bg-warm)`.
    private static func halo(radius: CGFloat) -> some View {
        Circle()
            .fill(DSColor.bgWarm)
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
                .font(DSFonts.serif(size: size, weight: .semibold, relativeTo: .title2))
                .tracking(tracking)
                .foregroundColor(DSColor.inkPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
    }

    /// Inter body lede, 3-line clamp, 0.85 opacity. app.jsx:656.
    struct RowLede: View {
        let text: String
        var body: some View {
            Text(text)
                .font(DSFonts.inter(size: 14, relativeTo: .subheadline))
                .tracking(0.1)
                .lineSpacing(14 * 0.7)        // line-height 1.7 ≈ +0.7em leading
                .foregroundColor(DSColor.inkPrimary.opacity(0.85))
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
                            .font(DSFonts.jetBrainsMono(size: 9.5, weight: .bold, relativeTo: .caption2))
                            .foregroundColor(DSColor.inkSubtle.opacity(0.55))
                    }
                    Text(tag)
                        .font(DSFonts.jetBrainsMono(size: 9.5, weight: .bold, relativeTo: .caption2))
                        .tracking(1.6)
                        .foregroundColor(DSColor.inkMuted)
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
                    .font(DSFonts.spaceGrotesk(size: 13, weight: .bold, relativeTo: .footnote))
                    .tracking(1.5)
                    .foregroundColor(DSColor.inkPrimary)
                Rectangle()
                    .fill(DSColor.inkFaint)
                    .frame(height: 0.5)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 2)
                Text(sub)
                    .font(DSFonts.jetBrainsMono(size: 9.5, weight: .bold, relativeTo: .caption2))
                    .tracking(1.6)
                    .foregroundColor(DSColor.inkMuted)
            }
            .padding(.horizontal, sectionPadH)
            .padding(.top, 20)
            .padding(.bottom, 14)
        }
    }
}

// MARK: - TimelineSwipePhysics
//
// Slimmed mirror of SwipePhysics in SwipeableMemoCard.swift. A separate
// constant set lets the timeline tune the row swipe independently (each side
// here has ONE action, so the panel is narrower than the memo card).
private enum TimelineSwipePhysics {
    static let actionWidth: CGFloat = 84
    static let panelWidth: CGFloat = actionWidth        // single action per side
    static let openThreshold: CGFloat = 40
    static let closeThreshold: CGFloat = 24
    static let velocityOpen: CGFloat = 600
    static let velocityClose: CGFloat = 500
    static let rubberBand: CGFloat = 0.25
    static let snapSpring: Animation = .spring(response: 0.28, dampingFraction: 0.86)
    static let reducedSnap: Animation = .easeOut(duration: 0.22)
}

// MARK: - TimelineSwipePanel
//
// Visual surface for one side of the timeline swipe drawer. Single-action
// variant of SwipeActionPanel from SwipeableMemoCard.swift — sized so the
// label reads cleanly without crowding adjacent content.
private struct TimelineSwipePanel: View {
    enum Edge { case leading, trailing }

    let actions: [SwipeAction]
    let edge: Edge
    let progress: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            ForEach(actions) { action in
                TimelineSwipeButton(action: action, progress: progress)
            }
        }
        .frame(width: TimelineSwipePhysics.panelWidth)
        .frame(maxHeight: .infinity)
        .opacity(progress > 0.02 ? 1 : 0)
        .allowsHitTesting(progress > 0.02)
        .accessibilityHidden(progress <= 0.02)
    }
}

// MARK: - TimelineSwipeButton

private struct TimelineSwipeButton: View {
    let action: SwipeAction
    let progress: CGFloat

    private let labelFadeStart: CGFloat = 0.30

    var body: some View {
        Button(action: action.run) {
            ZStack {
                background
                content
            }
            .frame(width: TimelineSwipePhysics.actionWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.label)
    }

    private var background: some View {
        let tint = Double(0.42 + 0.58 * min(1, progress))
        return ZStack {
            Rectangle().fill(.ultraThinMaterial)
            DSColor.accentAmber.opacity(tint)
        }
    }

    private var content: some View {
        VStack(spacing: 6) {
            Image(systemName: action.systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
                .scaleEffect(0.6 + 0.4 * max(0, min(1, progress)))
            Text(action.label)
                .font(.custom("Inter-Medium", size: 10.5))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundColor(.white)
                .opacity(Double(max(0, min(1, (progress - labelFadeStart) / (1 - labelFadeStart)))))
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - TimelineDayPreviewCard
//
// Shown inside .contextMenu(preview:) on long-press. A miniature daily page:
// the compiled serif title, the lede, then the first few raw memos so the
// user can recognize what they're about to open.
struct TimelineDayPreviewCard: View {
    let entry: TimelineDayEntry
    let memos: [Memo]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let summary = entry.summary, !summary.isEmpty {
                Text(summary)
                    .font(DSFonts.serif(size: 18, weight: .semibold, relativeTo: .headline))
                    .foregroundColor(DSColor.inkPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(4)
            } else {
                Text(NSLocalizedString("today.timeline.preview.noSummary",
                                       value: "No compiled summary yet.",
                                       comment: ""))
                    .font(DSFonts.serif(size: 16, relativeTo: .body))
                    .italic()
                    .foregroundColor(DSColor.inkMuted)
            }
            Divider().padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(memos.prefix(3), id: \.id) { memo in
                    Text(memo.body)
                        .font(DSFonts.inter(size: 13, relativeTo: .footnote))
                        .foregroundColor(DSColor.inkPrimary.opacity(0.85))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                if memos.count > 3 {
                    Text(String(format: NSLocalizedString(
                        "today.timeline.preview.moreMemos",
                        value: "+ %d more",
                        comment: "Count of additional memos hidden in preview"
                    ), memos.count - 3))
                        .font(DSFonts.jetBrainsMono(size: 10, weight: .bold, relativeTo: .caption2))
                        .tracking(1.4)
                        .foregroundColor(DSColor.inkMuted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .background(DSColor.surfaceWhite)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(entry.dateString)
                .font(DSFonts.jetBrainsMono(size: 10, weight: .bold, relativeTo: .caption2))
                .tracking(1.6)
                .foregroundColor(DSColor.accentAmber)
            Spacer(minLength: 8)
            Text("\(entry.memoCount) MEMOS")
                .font(DSFonts.jetBrainsMono(size: 9.5, weight: .bold, relativeTo: .caption2))
                .tracking(1.4)
                .foregroundColor(DSColor.inkMuted)
        }
    }
}
