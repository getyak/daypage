import SwiftUI

// MARK: - OnThisDayCard

struct OnThisDayCard: View {

    let entry: OnThisDayEntry
    let onDismiss: () -> Void
    let onTap: (OnThisDayEntry) -> Void

    var body: some View {
        Button {
            onTap(entry)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    // "ON THIS DAY · N YEAR(S) AGO" label
                    Text(headerLabel)
                        .labelText()
                        .foregroundColor(DSColor.accentAmber)
                    Spacer()
                    // Dismiss X
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(DSColor.onBackgroundMuted)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                }

                // Preview text (2 lines)
                Text(entry.preview.isEmpty ? "查看那一天的记录" : entry.preview)
                    .bodyText()
                    .foregroundColor(DSColor.onBackgroundPrimary)
                    .lineLimit(2)

                // "翻开那天 →" link
                HStack {
                    Spacer()
                    Text("翻开那天 →")
                        .captionText()
                        .foregroundColor(DSColor.accentAmber)
                }
            }
            .padding(DSSpacing.cardInner)
            .background(DSColor.accentSoft)
            .overlay(
                RoundedRectangle(cornerRadius: DSSpacing.radiusCard)
                    .stroke(DSColor.accentBorder, lineWidth: 1)
            )
            .cornerRadius(DSSpacing.radiusCard)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
    }

    // MARK: - Helpers

    private var headerLabel: String {
        if let years = entry.yearsAgo {
            return "ON THIS DAY · \(years) YEAR\(years == 1 ? "" : "S") AGO"
        } else if let days = entry.daysAgo {
            return "ON THIS DAY · \(days) DAYS AGO"
        }
        return "ON THIS DAY"
    }
}
