import SwiftUI

// MARK: - SpotlightStripView (US-014)
//
// Horizontal chip bar shown above the TextField in the composing card.
// Data comes from ComposerContextProvider.chips; tapping a chip inserts
// its content into the draft text or pending location.

struct SpotlightStripView: View {

    let chips: [ContextChip]
    /// Called with new text to append into draft.
    var onInsertText: (String) -> Void
    /// Called with a Location to set as pending location.
    var onInsertLocation: (Memo.Location) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chips) { chip in
                    SpotlightChip(chip: chip) {
                        Haptics.soft()
                        applyChip(chip)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    private func applyChip(_ chip: ContextChip) {
        switch chip {
        case .weather(let temp, let condition):
            let text = condition.isEmpty ? temp : "\(temp) \(condition)"
            onInsertText(text)
        case .location(let short):
            let loc = Memo.Location(name: short, lat: nil, lng: nil)
            onInsertLocation(loc)
        case .timeRitual(let emoji, let text):
            onInsertText("\(emoji) \(text)")
        case .lastMemoTail(let snippet):
            onInsertText("> \(snippet)")
        case .smartPaste(let value):
            onInsertText(value)
        }
    }
}

// MARK: - SpotlightChip

private struct SpotlightChip: View {

    let chip: ContextChip
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                chipIcon
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(DSColor.inkMuted)
                Text(chipLabel)
                    .font(DSType.labelSM)
                    .foregroundStyle(DSColor.inkPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .liquidGlassPill()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(chipAccessibilityLabel)
    }

    @ViewBuilder
    private var chipIcon: some View {
        switch chip {
        case .weather:
            Image(systemName: "cloud.sun")
        case .location:
            Image(systemName: "mappin")
        case .timeRitual(let emoji, _):
            Text(emoji)
                .font(.system(size: 12))
        case .lastMemoTail:
            Image(systemName: "text.quote")
        case .smartPaste:
            Image(systemName: "doc.on.clipboard")
        }
    }

    private var chipLabel: String {
        switch chip {
        case .weather(let temp, let condition):
            return condition.isEmpty ? temp : "\(temp) \(condition)"
        case .location(let short):
            return short
        case .timeRitual(_, let text):
            return text
        case .lastMemoTail(let snippet):
            let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            let preview = String(trimmed.prefix(20))
            return trimmed.count > 20 ? "\(preview)…" : preview
        case .smartPaste(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let preview = String(trimmed.prefix(18))
            return trimmed.count > 18 ? "\(preview)…" : preview
        }
    }

    private var chipAccessibilityLabel: String {
        switch chip {
        case .weather(let temp, let condition):
            return "插入天气：\(temp) \(condition)"
        case .location(let short):
            return "插入位置：\(short)"
        case .timeRitual(_, let text):
            return "插入时间：\(text)"
        case .lastMemoTail(let snippet):
            return "引用上一条：\(snippet.prefix(20))"
        case .smartPaste(let value):
            return "粘贴：\(value.prefix(20))"
        }
    }
}
