import SwiftUI
import UIKit
import DayPageModels

/// One measured text layout for collapsed and expanded cards. The complete
/// attributed document is retained; UILabel owns visual-line truncation.
struct MemoReadingText: UIViewRepresentable {
    let text: String
    var expanded = false
    var lineLimit = 6
    var onOverflow: (Bool) -> Void = { _ in }
    @Environment(\.sizeCategory) private var sizeCategory

    func makeUIView(context: Context) -> MemoReadingLabel {
        let label = MemoReadingLabel()
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.backgroundColor = .clear
        label.lineBreakMode = .byTruncatingTail
        label.isAccessibilityElement = true
        return label
    }

    func updateUIView(_ label: MemoReadingLabel, context: Context) {
        label.overflowChanged = onOverflow
        label.updateDocument(text: text, category: sizeCategory.uiCategory, expanded: expanded, budget: lineLimit)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MemoReadingLabel, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return uiView.readingSize(width: width)
    }
}

final class MemoReadingLabel: UILabel {
    var expanded = false
    var budget = 6
    var generation = 0
    var lastMeasurement: String?
    var overflowChanged: (Bool) -> Void = { _ in }
    private var source: String?
    private var category: UIContentSizeCategory?

    func updateDocument(text: String, category: UIContentSizeCategory, expanded: Bool, budget: Int) {
        let documentChanged = source != text || self.category != category
        guard documentChanged || self.expanded != expanded || self.budget != budget else { return }
        generation += 1
        lastMeasurement = nil
        if documentChanged {
            source = text
            self.category = category
            attributedText = MemoReadingDocument.attributed(text, category: category)
            accessibilityLabel = attributedText?.string
        }
        self.expanded = expanded
        self.budget = budget
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override var intrinsicContentSize: CGSize {
        var size = super.intrinsicContentSize
        size.width = UIView.noIntrinsicMetric
        return size
    }

    func readingSize(width: CGFloat) -> CGSize {
        preferredMaxLayoutWidth = width
        numberOfLines = expanded ? 0 : effectiveBudget(width: width)
        let measured = sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        // A one-line UILabel reports its natural unwrapped width. SwiftUI's
        // proposed width remains the boundary for both preview and full text.
        return CGSize(width: width, height: ceil(measured.height))
    }

    func effectiveBudget(width: CGFloat) -> Int {
        budget == 6 && width < 290 ? 5 : budget
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, let attributedText else { return }
        let lines = effectiveBudget(width: bounds.width)
        let key = "\(generation)/\(bounds.width)/\(lines)"
        guard lastMeasurement != key else { return }
        lastMeasurement = key
        let result = MemoReadingMetrics.measure(attributedText, width: bounds.width, lines: lines)
        let token = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == token else { return }
            self.overflowChanged(result.overflows)
        }
    }
}

enum MemoReadingMetrics {
    struct Measurement {
        let fullHeight: CGFloat
        let previewHeight: CGFloat
        var overflows: Bool { fullHeight > previewHeight + 0.5 }
    }

    /// These labels are measurement objects only, never hidden copies in the
    /// SwiftUI or accessibility hierarchy.
    static func measure(_ text: NSAttributedString, width: CGFloat, lines: Int) -> Measurement {
        let label = UILabel()
        label.attributedText = text
        label.lineBreakMode = .byTruncatingTail
        label.numberOfLines = 0
        let size = CGSize(width: max(1, width), height: .greatestFiniteMagnitude)
        let full = label.sizeThatFits(size).height
        label.numberOfLines = max(1, lines)
        return Measurement(fullHeight: full, previewHeight: label.sizeThatFits(size).height)
    }
}

enum MemoReadingDocument {
    static func source(for memo: Memo) -> String {
        // Read-only presentation body first (#884 follow-up): an exact
        // generated media-only placeholder set presents as empty here — the
        // media rows render separately and the raw body stays untouched for
        // editing, copy and export. Transcripts still append after it.
        var parts = [MemoAttachmentPresentation.displayBody(for: memo).trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }
        for attachment in memo.attachments where attachment.kind == "audio" {
            guard let transcript = attachment.transcript?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !transcript.isEmpty, !parts.contains(transcript) else { continue }
            parts.append(transcript)
        }
        return parts.joined(separator: "\n\n")
    }

    static func attributed(_ text: String, category: UIContentSizeCategory) -> NSAttributedString {
        let traits = UITraitCollection(preferredContentSizeCategory: category)
        let metrics = UIFontMetrics(forTextStyle: .body)
        let size = metrics.scaledValue(for: 17, compatibleWith: traits)
        let leading = metrics.scaledValue(for: 26, compatibleWith: traits)
        let paragraphGap = metrics.scaledValue(for: 10, compatibleWith: traits)
        let output = NSMutableAttributedString(string: "")

        func font(_ run: MemoMarkdown.InlineRun) -> UIFont {
            if run.code {
                return UIFont(name: DSFonts.mono, size: size * 0.85)
                    ?? .monospacedSystemFont(ofSize: size * 0.85, weight: .regular)
            }
            return DSFonts.serifUIFont(size: size, weight: run.bold ? .semibold : .regular, italic: run.italic)
        }

        func paragraph(_ runs: [MemoMarkdown.InlineRun], prefix: String = "", suffix: String = "", indent: Bool = false) {
            if output.length > 0 { output.append(NSAttributedString(string: "\n")) }
            let start = output.length
            let style = NSMutableParagraphStyle()
            style.minimumLineHeight = leading
            style.maximumLineHeight = leading
            style.paragraphSpacing = paragraphGap
            style.lineBreakMode = .byWordWrapping
            if indent { style.headIndent = metrics.scaledValue(for: 22, compatibleWith: traits) }
            let base: [NSAttributedString.Key: Any] = [
                .font: DSFonts.serifUIFont(size: size, weight: .regular),
                .foregroundColor: UIColor(DSColor.inkPrimary)
            ]
            output.append(NSAttributedString(string: prefix, attributes: base))
            for run in runs {
                var attrs = base
                attrs[.font] = font(run)
                if run.linkURL != nil || run.wikilinkSlug != nil {
                    attrs[.foregroundColor] = UIColor(DSColor.readingAccent)
                }
                if run.strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                output.append(NSAttributedString(string: run.text, attributes: attrs))
            }
            output.append(NSAttributedString(string: suffix, attributes: base))
            output.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: output.length - start))
        }

        for block in MemoMarkdown.cachedParse(text).blocks {
            switch block {
            case .paragraph(let runs): paragraph(runs)
            case .heading(_, let runs):
                paragraph(runs.map { var run = $0; run.bold = true; return run })
            case .quote(let runs): paragraph(runs, prefix: "“", suffix: "”")
            case .bullets(let items):
                for item in items { paragraph(item.runs, prefix: "•  ", indent: true) }
            case .ordered(let start, let items):
                for (index, item) in items.enumerated() { paragraph(item.runs, prefix: "\(start + index). ", indent: true) }
            case .tasks(let items):
                for item in items { paragraph(item.runs, prefix: item.done ? "☑  " : "☐  ", indent: true) }
            case .codeBlock(let value): paragraph([.init(text: value, code: true)])
            case .divider: paragraph([.init(text: "—")])
            }
        }
        return output
    }
}

private extension ContentSizeCategory {
    var uiCategory: UIContentSizeCategory {
        switch self {
        case .extraSmall: return .extraSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .extraLarge: return .extraLarge
        case .extraExtraLarge: return .extraExtraLarge
        case .extraExtraExtraLarge: return .extraExtraExtraLarge
        case .accessibilityMedium: return .accessibilityMedium
        case .accessibilityLarge: return .accessibilityLarge
        case .accessibilityExtraLarge: return .accessibilityExtraLarge
        case .accessibilityExtraExtraLarge: return .accessibilityExtraExtraLarge
        case .accessibilityExtraExtraExtraLarge: return .accessibilityExtraExtraExtraLarge
        @unknown default: return .large
        }
    }
}

/// A card passes the existing UIKit bridge down only to its read-only areas.
/// Photos, audio and disclosure controls keep native hit testing.
struct MemoCardInteraction {
    let isActive: Binding<Bool>
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat, CGFloat) -> Void
    let onCancelled: () -> Void
    let onTap: () -> Void
    let onPressChanged: (Bool) -> Void

    var bridge: HorizontalPanGesture {
        HorizontalPanGesture(isActive: isActive, onChanged: onChanged, onEnded: onEnded,
                             onCancelled: onCancelled, onTap: onTap, onPressChanged: onPressChanged, isEnabled: true)
    }
}
