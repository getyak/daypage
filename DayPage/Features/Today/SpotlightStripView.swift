import SwiftUI
import UIKit

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
        case .location(let short, let lat, let lng):
            // Carry coordinates through; previously dropped to nil/nil and
            // degraded memos vs. the explicit "fetch location" button.
            let loc = Memo.Location(name: short, lat: lat, lng: lng)
            onInsertLocation(loc)
        case .timeRitual(let emoji, let text):
            onInsertText("\(emoji) \(text)")
        case .lastMemoTail(let snippet):
            onInsertText("> \(snippet)")
        case .smartPaste:
            // Read pasteboard contents only on explicit user tap. The chip
            // builder upstream never pre-reads the string (would trigger the
            // iOS "Pasted from <other app>" privacy banner on every render).
            let raw = UIPasteboard.general.string ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            onInsertText(String(trimmed.prefix(100)))
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
        case .location(let short, _, _):
            return short
        case .timeRitual(_, let text):
            return text
        case .lastMemoTail(let snippet):
            let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            let preview = String(trimmed.prefix(20))
            return trimmed.count > 20 ? "\(preview)…" : preview
        case .smartPaste:
            // Static label — never previews pasteboard content (privacy).
            return "剪贴板"
        }
    }

    private var chipAccessibilityLabel: String {
        switch chip {
        case .weather(let temp, let condition):
            return "插入天气：\(temp) \(condition)"
        case .location(let short, _, _):
            return "插入位置：\(short)"
        case .timeRitual(_, let text):
            return "插入时间：\(text)"
        case .lastMemoTail(let snippet):
            return "引用上一条：\(snippet.prefix(20))"
        case .smartPaste:
            return "粘贴剪贴板内容"
        }
    }
}
