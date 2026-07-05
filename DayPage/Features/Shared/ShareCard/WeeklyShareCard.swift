import SwiftUI
import DayPageServices

// MARK: - WeeklyShareCard (Issue #10 · 2026-07-03)
//
// A SwiftUI view that lays out a warm-cream, portrait "share card" for a
// WeeklyRecapOutput. Rendered off-screen via `ImageRenderer` inside
// `WeeklyShareCard.render(...)` and handed to the standard iOS share
// sheet by MarkdownExportService. The card is intentionally quiet —
// headline, 3 keyword chips, moodNotes as a single paragraph, and a
// small footer — so it reads like a journal cover.

struct WeeklyShareCard: View {

    let output: WeeklyRecapOutput

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("DAYPAGE · WEEKLY")
                    .font(.system(.footnote, design: .monospaced))
                    .tracking(2)
                    .foregroundColor(DSColor.inkMuted)
                Text(output.isoWeek)
                    .font(DSFonts.serif(size: 40, weight: .regular))
                    .foregroundColor(DSColor.inkPrimary)
                Text(output.dateRange)
                    .font(DSType.labelSM)
                    .foregroundColor(DSColor.inkMuted)
            }

            if !output.keywords.isEmpty {
                HStack(spacing: 8) {
                    ForEach(output.keywords.prefix(4), id: \.self) { keyword in
                        Text(keyword)
                            .font(DSType.labelSM)
                            .foregroundColor(DSColor.accentOnBg)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(DSColor.amberSoft))
                    }
                    Spacer()
                }
            }

            if !output.moodNotes.isEmpty {
                Text(output.moodNotes)
                    .font(DSFonts.serif(size: 20, weight: .regular))
                    .foregroundColor(DSColor.inkPrimary)
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let top = output.highlights.first {
                VStack(alignment: .leading, spacing: 6) {
                    Text("HIGHLIGHT")
                        .font(.system(.caption2, design: .monospaced))
                        .tracking(1.6)
                        .foregroundColor(DSColor.inkMuted)
                    Text(top)
                        .font(DSFonts.serif(size: 18, weight: .regular))
                        .foregroundColor(DSColor.inkPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            HStack(alignment: .firstTextBaseline) {
                Text("每天的碎片，织成一周的故事")
                    .font(DSType.labelSM)
                    .foregroundColor(DSColor.inkSubtle)
                Spacer()
                Text("daypage")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(DSColor.accentOnBg)
            }
        }
        .padding(28)
        .frame(width: 900, height: 1600)
        .background(DSColor.backgroundWarm)
    }

    /// Renders the card off-screen and returns a `UIImage`. Uses
    /// `ImageRenderer` (iOS 16+) so we get consistent color + font
    /// resolution across devices.
    @MainActor
    static func render(output: WeeklyRecapOutput) -> UIImage? {
        let card = WeeklyShareCard(output: output)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        return renderer.uiImage
    }
}
