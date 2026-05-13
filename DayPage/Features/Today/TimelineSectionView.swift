import SwiftUI

// MARK: - TimelineSectionView

/// Renders one band of the Today historical timeline — a labelled divider
/// followed by one card per day. Expanding a card reveals that day's raw
/// memos inline (no navigation, see issue #276).
///
/// Visual language mirrors `WeeklyRecapSection`: low-contrast section header
/// and surface-container cards, signalling "settled history" rather than the
/// active composer day above.
struct TimelineSectionView: View {

    let section: TimelineSection

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionDivider
            ForEach(section.days) { day in
                TimelineDayCard(entry: day)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
    }

    // MARK: Section header

    private var sectionDivider: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(DSColor.outlineVariant)
                .frame(height: 1)
                .frame(maxWidth: 24)
            Text(headerTitle)
                .sectionLabelStyle()
                .foregroundColor(DSColor.onSurfaceVariant)
            Rectangle()
                .fill(DSColor.outlineVariant)
                .frame(height: 1)
                .frame(maxWidth: .infinity)
        }
    }

    /// Localized header. Month buckets format as "MMMM yyyy" in the user's
    /// current locale so it reads naturally in either English or Chinese.
    private var headerTitle: String {
        switch section.kind {
        case .thisWeekOthers:
            return NSLocalizedString("today.timeline.thisWeek", value: "THIS WEEK", comment: "Timeline band")
        case .lastWeek:
            return NSLocalizedString("today.timeline.lastWeek", value: "LAST WEEK", comment: "Timeline band")
        case .weekBeforeLast:
            return NSLocalizedString("today.timeline.weekBeforeLast", value: "TWO WEEKS AGO", comment: "Timeline band")
        case .month(let date):
            let f = DateFormatter()
            f.dateFormat = "MMMM yyyy"
            f.locale = Locale.current
            f.timeZone = TimeZone.current
            return f.string(from: date).uppercased()
        }
    }
}

// MARK: - TimelineDayCard

/// One day card inside a timeline section. Tap to expand — the card grows
/// downward to show that day's raw memos, loaded lazily via TimelineService.
struct TimelineDayCard: View {

    let entry: TimelineDayEntry

    @State private var isExpanded: Bool = false
    @State private var loadedMemos: [Memo] = []
    @State private var hasLoaded: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                Divider()
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                expandedMemos
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSColor.surfaceContainer)
        .cornerRadius(DSSpacing.radiusCard)
    }

    // MARK: Header (always visible)

    private var header: some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 14) {
                dateRail
                summaryColumn
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DSColor.onSurfaceVariant)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(isExpanded
            ? NSLocalizedString("today.timeline.collapse", value: "Collapse", comment: "")
            : NSLocalizedString("today.timeline.expand", value: "Expand", comment: ""))
    }

    private var dateRail: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(weekdayLabel)
                .font(.custom("JetBrainsMono-Regular", fixedSize: 10))
                .foregroundColor(DSColor.onSurfaceVariant)
            Text(monthDayLabel)
                .font(.custom("SpaceGrotesk-Bold", size: 16))
                .foregroundColor(DSColor.onSurface)
        }
        .frame(width: 56, alignment: .leading)
    }

    private var summaryColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let summary = entry.summary, !summary.isEmpty {
                Text(summary)
                    .bodySMStyle()
                    .foregroundColor(DSColor.onSurface)
                    .lineLimit(isExpanded ? nil : 2)
                    .multilineTextAlignment(.leading)
            }
            Text(memoCountLabel)
                .font(.custom("JetBrainsMono-Regular", fixedSize: 10))
                .foregroundColor(DSColor.onSurfaceVariant)
                .textCase(.uppercase)
                .tracking(1.0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Expanded memo list

    private var expandedMemos: some View {
        VStack(spacing: 8) {
            ForEach(loadedMemos, id: \.id) { memo in
                MemoCardView(memo: memo)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    // MARK: Interaction

    private func toggle() {
        if !hasLoaded {
            // First expand: parse the day's file once and cache. Subsequent
            // toggles just flip the flag — no extra I/O. Load off-main to
            // avoid blocking the UI thread on synchronous file I/O.
            Task {
                let memos = TimelineService.memos(for: entry)
                await MainActor.run {
                    loadedMemos = memos
                    hasLoaded = true
                }
            }
        }
        withAnimation(.easeInOut(duration: 0.22)) {
            isExpanded.toggle()
        }
    }

    // MARK: Formatters

    private var weekdayLabel: String {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f.string(from: entry.date).uppercased()
    }

    private var monthDayLabel: String {
        let f = DateFormatter()
        f.dateFormat = "MM.dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f.string(from: entry.date)
    }

    private var memoCountLabel: String {
        let n = entry.memoCount
        let key = n == 1 ? "today.timeline.memoCount.one" : "today.timeline.memoCount.other"
        let fallback = n == 1 ? "1 MEMO" : "\(n) MEMOS"
        let format = NSLocalizedString(key, value: fallback, comment: "Memo count chip")
        return String(format: format, n)
    }

    private var accessibilityLabel: String {
        let summaryText = entry.summary.flatMap { $0.isEmpty ? nil : $0 } ?? memoCountLabel
        return "\(entry.dateString), \(summaryText)"
    }
}
