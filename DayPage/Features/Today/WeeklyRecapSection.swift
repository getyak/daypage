import SwiftUI

// MARK: - WeeklyRecapSection

/// "本周回顾" — appears at the bottom of the Today timeline once today's raw
/// memos finish rendering. Lists this week's already-compiled day pages
/// (Monday → yesterday) in newest-first order. Tapping a card opens
/// `DayDetailView` for that date.
///
/// Phase 1 design language:
/// - A thin labelled separator visually divides "now" (raw memos above) from
///   "memory" (compiled summaries below). Scrolling down becomes a metaphor:
///   the further you scroll, the further back in time and the more compressed
///   the representation. Phase 2/3 will collapse last week / last month / last
///   year into single coarser-grained cards below this section.
/// - Cards stay quieter than `DailyPageEntryCard` (the brutalist black
///   "today is ready" hero). Recap cards use the surface-container palette so
///   they read as "settled history" rather than active state.
struct WeeklyRecapSection: View {

    let entries: [WeeklyRecapEntry]
    let onTapEntry: (String) -> Void

    var body: some View {
        if entries.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 12) {
                sectionDivider
                ForEach(entries) { entry in
                    WeeklyRecapDayCard(entry: entry) {
                        onTapEntry(entry.dateString)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 8)
        }
    }

    private var sectionDivider: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(DSColor.outlineVariant)
                .frame(height: 1)
                .frame(maxWidth: 24)
            Text("THIS WEEK")
                .sectionLabelStyle()
                .foregroundColor(DSColor.onSurfaceVariant)
            Rectangle()
                .fill(DSColor.outlineVariant)
                .frame(height: 1)
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - WeeklyRecapDayCard

/// One compiled-day card inside `WeeklyRecapSection`.
///
/// Layout:
/// - Left rail: weekday label (MON / TUE / ...) + month-day in mono.
/// - Right column: summary preview, capped at 2 lines.
/// - Trailing chevron suggests "tap to drill down".
private struct WeeklyRecapDayCard: View {

    let entry: WeeklyRecapEntry
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 14) {
                dateRail
                summaryColumn
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DSColor.onSurfaceVariant)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DSColor.surfaceContainer)
            .cornerRadius(DSSpacing.radiusCard)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
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
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            } else {
                Text("Daily page compiled.")
                    .bodySMStyle()
                    .foregroundColor(DSColor.onSurfaceVariant)
                    .italic()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var accessibilityLabel: String {
        let summaryText = entry.summary.flatMap { $0.isEmpty ? nil : $0 } ?? "已编译"
        return "\(entry.dateString)，\(summaryText)"
    }
}
