import SwiftUI

// MARK: - OnThisDayCard

struct OnThisDayCard: View {

    let entry: OnThisDayEntry
    let onDismiss: () -> Void
    let onTap: (OnThisDayEntry) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            Haptics.tapConfirm()
            onTap(entry)
        } label: {
            cardContent
        }
        .buttonStyle(OnThisDayPressStyle(reduceMotion: reduceMotion))
        .padding(.horizontal, 20)
        // Single accessible element: card body + dismiss action
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityCardLabel)
        .accessibilityHint("翻开那天")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Dismiss")) {
            onDismiss()
        }
        // 44pt dismiss overlay wins hit-testing over the card button
        .overlay(alignment: .topTrailing) {
            dismissButton
                .padding(.trailing, 2)
                .padding(.top, 2)
        }
    }

    // MARK: - Subviews

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(headerLabel)
                    .labelText()
                    .foregroundColor(DSColor.accentAmber)
                Spacer()
                // Spacer reserves room for the 44pt dismiss overlay
                Color.clear.frame(width: 44, height: 24)
            }

            Text(entry.preview.isEmpty ? "查看那一天的记录" : entry.preview)
                .bodyText()
                .foregroundColor(DSColor.onBackgroundPrimary)
                .lineLimit(2)

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

    private var dismissButton: some View {
        Button {
            Haptics.soft()
            onDismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DSColor.onBackgroundMuted)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss")
        .accessibilityIdentifier("onthisday-dismiss")
        .zIndex(1)
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

    private var accessibilityCardLabel: String {
        let preview = entry.preview.isEmpty ? "查看那一天的记录" : entry.preview
        return "\(headerLabel), \(preview)"
    }
}

// MARK: - OnThisDayPressStyle

private struct OnThisDayPressStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect((!reduceMotion && configuration.isPressed) ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.94 : 1)
            .animation(
                reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7),
                value: configuration.isPressed
            )
    }
}
