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
        // Single accessible element: card body + dismiss action. R6 — explicit
        // .ignore so VoiceOver reads only the composed label below; inner
        // Text nodes would otherwise double-up "ON THIS DAY · 1 YEAR AGO".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityCardLabel)
        .accessibilityHint(NSLocalizedString(
            "onthisday.card.accessibility.hint",
            value: "点击查看完整 memo",
            comment: "VoiceOver hint for the On This Day card tap"
        ))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text(NSLocalizedString(
            "onthisday.card.accessibility.action.dismiss",
            value: "关闭今日回忆",
            comment: "VoiceOver custom action label for dismissing the On This Day card"
        ))) {
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

            Text(entry.preview.isEmpty
                 ? NSLocalizedString("onthisday.card.preview.empty",
                                     value: "查看那一天的记录",
                                     comment: "Fallback preview text when the on-this-day candidate has no body")
                 : entry.preview)
                .bodyText()
                .foregroundColor(DSColor.onBackgroundPrimary)
                .lineLimit(2)

            HStack {
                Spacer()
                Text(NSLocalizedString("onthisday.card.cta",
                                       value: "翻开那天 →",
                                       comment: "Trailing CTA on the On This Day card"))
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
        .accessibilityLabel(NSLocalizedString(
            "onthisday.card.dismiss.accessibility.label",
            value: "关闭今日回忆",
            comment: "VoiceOver label for the On This Day card dismiss button"
        ))
        .accessibilityHint(NSLocalizedString(
            "onthisday.card.dismiss.accessibility.hint",
            value: "今日不再显示",
            comment: "VoiceOver hint for the On This Day card dismiss button"
        ))
        .accessibilityIdentifier("onthisday-dismiss")
        .zIndex(1)
    }

    // MARK: - Helpers

    private var headerLabel: String {
        if let years = entry.yearsAgo {
            return "ON THIS DAY · \(years) YEAR\(years == 1 ? "" : "S") AGO"
        } else if let days = entry.daysAgo {
            return "ON THIS DAY · \(Self.relativeSpan(days: days))"
        }
        return "ON THIS DAY"
    }

    /// Renders a day-count as natural, grammatically-correct relative copy for the
    /// uppercase header (e.g. 180 → "6 MONTHS AGO", 30 → "1 MONTH AGO", 1 → "1 DAY AGO").
    /// Clean multiples of 30 days collapse to months so the card reads naturally
    /// instead of the awkward "180 DAYS AGO".
    static func relativeSpan(days: Int) -> String {
        if days >= 30, days % 30 == 0 {
            let months = days / 30
            return "\(months) MONTH\(months == 1 ? "" : "S") AGO"
        }
        return "\(days) DAY\(days == 1 ? "" : "S") AGO"
    }

    private var accessibilityCardLabel: String {
        let preview = entry.preview.isEmpty
            ? NSLocalizedString("onthisday.card.preview.empty",
                                value: "查看那一天的记录",
                                comment: "Fallback preview text when the on-this-day candidate has no body")
            : entry.preview
        let template = NSLocalizedString(
            "onthisday.card.accessibility.label",
            value: "时光胶囊：%@ — %@",
            comment: "Composed VoiceOver label for On This Day card: %1$@=relative date, %2$@=snippet"
        )
        return String(format: template, headerLabel, preview)
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
