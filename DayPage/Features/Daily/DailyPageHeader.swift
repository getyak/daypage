import SwiftUI

// MARK: - DailyPageHeader

/// Legacy header section for DailyPageView — date title, weekday, summary, metadata chips.
/// Extracted from DailyPageView (US-023).
struct DailyPageHeader: View {

    let model: DailyPageModel
    let rawMemos: [Memo]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main date title — "APRIL 14" (month + day only, all caps)
            Text(monthDay(model.dateString))
                .displayLGStyle()
                .foregroundColor(DSColor.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .padding(.bottom, 4)

            // Weekday + year subtitle — "Sunday, 2026"
            Text(weekdayYear(model.dateString))
                .captionText()
                .foregroundColor(DSColor.onSurfaceVariant)
                .padding(.bottom, 24)

            // Summary with left border
            if !model.summary.isEmpty {
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(DSColor.primary)
                        .frame(width: 2)
                    Text(CJKTextPolish.polish(model.summary))
                        .font(DSType.serifBody18)
                        .foregroundColor(DSColor.onSurface)
                        .lineSpacing(6)
                        .padding(.leading, 16)
                        .padding(.vertical, 4)
                }
                .padding(.bottom, 20)
            }

            // Metadata chips row
            HStack(spacing: 8) {
                metaChip("\(model.entriesCount) entries")
                if model.locations.count > 0 {
                    metaChip("\(model.locations.count) locations")
                }
                voiceChip
            }
        }
    }

    // MARK: - Chips

    private func metaChip(_ text: String) -> some View {
        Text(text.uppercased())
            .monoLabelStyle(size: 11)
            .foregroundColor(DSColor.onSurfaceVariant)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(DSColor.surfaceContainer)
            .cornerRadius(0)
    }

    private var voiceChip: some View {
        let allAttachments = rawMemos.flatMap { $0.attachments }
        let audioAttachments = allAttachments.filter { $0.kind == "audio" }
        let durations = audioAttachments.compactMap { $0.duration }
        let totalSeconds: Double = durations.reduce(0, +)
        if totalSeconds <= 0 { return AnyView(EmptyView()) }
        let t = Int(totalSeconds)
        let label = "🎙️ \(String(format: "%02d:%02d", t / 60, t % 60))"
        return AnyView(metaChip(label))
    }

    // MARK: - Date helpers

    private func monthDay(_ dateString: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        guard let date = parser.date(from: dateString) else { return dateString }
        let f = DateFormatter()
        f.dateFormat = "MMMM d"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date).uppercased()
    }

    private func weekdayYear(_ dateString: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        guard let date = parser.date(from: dateString) else { return "" }
        let f = DateFormatter()
        f.dateFormat = "EEEE, yyyy"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }
}
