import SwiftUI
import UIKit

// MARK: - MarkdownEditor
//
// WYSIWYG markdown editing cabin (Typora line-reveal model). The vault text
// stays markdown, but the editor *conceals* syntax characters — `**`, `~~`,
// backticks, brackets — so prose reads fully rendered. Only the line the
// caret sits on reveals its raw syntax (in receded amber) for editing;
// leave the line and it collapses back to rendered form. Semantic markers
// (list dashes, task boxes, quote bars, dividers) stay visible everywhere —
// they carry meaning, not noise.
//
// UITextView because the experience needs what TextEditor cannot give on
// iOS 16/17: attribute-level concealment, selection APIs for the format
// bar, and smart-return list continuation.
//
// CJK IME safety: while `markedTextRange` is non-nil (pinyin composition in
// flight) the highlighter never touches the storage — restyling mid-
// composition breaks the IME. The pass re-runs when composition commits.

/// Bridges the SwiftUI format bar (hosted by the parent view, right under
/// the editor) to the live coordinator.
@MainActor
final class MarkdownEditorController: ObservableObject {
    weak var coordinator: MarkdownEditor.Coordinator?
    func perform(_ action: MarkdownFormatBar.Action) {
        coordinator?.perform(action)
    }
}

struct MarkdownEditor: UIViewRepresentable {

    @Binding var text: String
    /// Content-driven height, measured by the coordinator and clamped to
    /// [minHeight, maxHeight]; the host applies it via `.frame(height:)`.
    @Binding var measuredHeight: CGFloat
    var controller: MarkdownEditorController? = nil
    var minHeight: CGFloat = 160
    var maxHeight: CGFloat = 380
    var autoFocus: Bool = true

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.backgroundColor = .clear
        tv.tintColor = UIColor(DSColor.accentOnBg)
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        tv.keyboardDismissMode = .interactive
        tv.alwaysBounceVertical = false
        // Red spell-check squiggles and smart-dash substitution ("--" → "—")
        // both fight markdown; autocorrect itself stays on.
        tv.spellCheckingType = .no
        tv.smartDashesType = .no
        tv.delegate = context.coordinator
        tv.accessibilityIdentifier = "memo.detail.body.editor"
        tv.text = text
        context.coordinator.textView = tv
        controller?.coordinator = context.coordinator
        // Open reading-order: caret at the document start, view at the top.
        tv.selectedRange = NSRange(location: 0, length: 0)
        context.coordinator.applyHighlight()
        DispatchQueue.main.async {
            context.coordinator.updateHeight()
            if autoFocus { tv.becomeFirstResponder() }
            tv.setContentOffset(.zero, animated: false)
        }
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.parent = self
        controller?.coordinator = context.coordinator
        if tv.text != text, tv.markedTextRange == nil {
            tv.text = text
            context.coordinator.applyHighlight()
            context.coordinator.updateHeight()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownEditor
        weak var textView: UITextView?
        /// Line range currently revealed (raw syntax shown). Tracked so
        /// caret moves only trigger a restyle when the line changes.
        private var revealedLine: NSRange = NSRange(location: NSNotFound, length: 0)

        init(_ parent: MarkdownEditor) {
            self.parent = parent
        }

        // MARK: UITextViewDelegate

        func textViewDidChange(_ tv: UITextView) {
            // Never restyle or sync while the CJK IME is composing.
            guard tv.markedTextRange == nil else { return }
            parent.text = tv.text
            applyHighlight()
            updateHeight()
        }

        func textViewDidChangeSelection(_ tv: UITextView) {
            guard tv.markedTextRange == nil else { return }
            // Typora line-reveal: moving the caret to another line re-renders
            // the one it left and un-conceals the one it entered.
            let line = (tv.text as NSString).lineRange(for: tv.selectedRange)
            if line != revealedLine {
                applyHighlight()
            }
        }

        func textView(
            _ tv: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText replacement: String
        ) -> Bool {
            // Smart list continuation on return.
            guard replacement == "\n", tv.markedTextRange == nil else { return true }
            let ns = tv.text as NSString
            guard range.location <= ns.length else { return true }
            let lineRange = ns.lineRange(for: NSRange(location: range.location, length: 0))
            let line = ns.substring(with: lineRange)
            guard let marker = MarkdownEditor.continuationMarker(for: line) else { return true }

            let content = (line as NSString).substring(from: min(marker.length, (line as NSString).length))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if content.isEmpty {
                // Return on an empty item exits the list: remove the marker.
                let markerRange = NSRange(location: lineRange.location, length: marker.length)
                tv.textStorage.replaceCharacters(in: markerRange, with: "")
                tv.selectedRange = NSRange(location: markerRange.location, length: 0)
                afterProgrammaticEdit()
            } else {
                tv.insertText("\n" + marker.next)
            }
            return false
        }

        // MARK: Highlight + height

        func applyHighlight() {
            guard let tv = textView, tv.markedTextRange == nil else { return }
            let reveal = (tv.text as NSString).lineRange(for: tv.selectedRange)
            revealedLine = reveal
            MarkdownSyntaxHighlighter.apply(to: tv.textStorage, revealing: reveal)
            // Reset typing attributes so characters typed after a styled run
            // start from the base ink instead of inheriting bold/mono.
            tv.typingAttributes = MarkdownSyntaxHighlighter.baseAttributes()
        }

        func updateHeight() {
            guard let tv = textView, tv.bounds.width > 0 else { return }
            let fit = tv.sizeThatFits(
                CGSize(width: tv.bounds.width, height: .greatestFiniteMagnitude)
            ).height
            let clamped = min(max(fit, parent.minHeight), parent.maxHeight)
            guard abs(clamped - parent.measuredHeight) > 1 else { return }
            let target = self
            DispatchQueue.main.async {
                target.parent.measuredHeight = clamped
            }
        }

        // MARK: Format actions (invoked via MarkdownEditorController)

        func perform(_ action: MarkdownFormatBar.Action) {
            switch action {
            case .bold:   wrapSelection(prefix: "**", suffix: "**")
            case .italic: wrapSelection(prefix: "*", suffix: "*")
            case .strike: wrapSelection(prefix: "~~", suffix: "~~")
            case .code:   wrapSelection(prefix: "`", suffix: "`")
            case .bullet: toggleLinePrefix("- ")
            case .task:   toggleLinePrefix("- [ ] ")
            case .quote:  toggleLinePrefix("> ")
            }
        }

        /// Wraps the selection (or an empty cursor) in a delimiter pair.
        /// `insertText` keeps the native undo stack intact.
        private func wrapSelection(prefix: String, suffix: String) {
            guard let tv = textView, tv.markedTextRange == nil else { return }
            let sel = tv.selectedRange
            let ns = tv.text as NSString
            let inner = sel.length > 0 ? ns.substring(with: sel) : ""
            tv.insertText(prefix + inner + suffix)
            tv.selectedRange = NSRange(
                location: sel.location + (prefix as NSString).length,
                length: sel.length
            )
            Haptics.soft()
            // insertText already fired textViewDidChange; the cursor move
            // above needs one more typing-attributes reset.
            applyHighlight()
        }

        /// Toggles a line prefix ("- ", "- [ ] ", "> ") on every line the
        /// selection touches. Lines are processed bottom-up so earlier
        /// mutations never shift later ranges.
        private func toggleLinePrefix(_ prefix: String) {
            guard let tv = textView, tv.markedTextRange == nil else { return }
            let ns = tv.text as NSString
            let sel = tv.selectedRange
            let block = ns.lineRange(for: sel)

            var lineRanges: [NSRange] = []
            var cursor = block.location
            while cursor < NSMaxRange(block) {
                let lr = ns.lineRange(for: NSRange(location: cursor, length: 0))
                lineRanges.append(lr)
                if NSMaxRange(lr) == cursor { break }
                cursor = NSMaxRange(lr)
            }
            if lineRanges.isEmpty { lineRanges = [block] }

            var caretDelta = 0
            let prefixLen = (prefix as NSString).length
            for lr in lineRanges.reversed() {
                let line = ns.substring(with: lr)
                if line.hasPrefix(prefix) {
                    tv.textStorage.replaceCharacters(
                        in: NSRange(location: lr.location, length: prefixLen),
                        with: ""
                    )
                    if lr.location <= sel.location { caretDelta -= prefixLen }
                } else {
                    tv.textStorage.replaceCharacters(
                        in: NSRange(location: lr.location, length: 0),
                        with: prefix
                    )
                    if lr.location <= sel.location { caretDelta += prefixLen }
                }
            }
            let newLocation = max(0, min(sel.location + caretDelta, (tv.text as NSString).length))
            tv.selectedRange = NSRange(location: newLocation, length: 0)
            Haptics.soft()
            afterProgrammaticEdit()
        }

        /// textStorage mutations bypass the delegate — sync + restyle manually.
        private func afterProgrammaticEdit() {
            guard let tv = textView else { return }
            parent.text = tv.text
            applyHighlight()
            updateHeight()
        }
    }

    // MARK: - List continuation

    /// Detects a list marker at the start of `line` and returns its UTF-16
    /// length plus the marker the *next* line should start with. Checked
    /// task boxes continue unchecked — a new item is always still to-do.
    static func continuationMarker(for line: String) -> (length: Int, next: String)? {
        let ns = line as NSString

        if let m = taskMarkerRegex.firstMatch(
            in: line, range: NSRange(location: 0, length: ns.length)
        ) {
            return (m.range.length, "- [ ] ")
        }
        if let m = bulletMarkerRegex.firstMatch(
            in: line, range: NSRange(location: 0, length: ns.length)
        ) {
            return (m.range.length, ns.substring(with: m.range))
        }
        if let m = orderedMarkerRegex.firstMatch(
            in: line, range: NSRange(location: 0, length: ns.length)
        ) {
            let digits = ns.substring(with: m.range(at: 1))
            let punct = ns.substring(with: m.range(at: 2))
            let next = (Int(digits) ?? 0) + 1
            return (m.range.length, "\(next)\(punct) ")
        }
        return nil
    }

    private static let taskMarkerRegex = try! NSRegularExpression(
        pattern: #"^[-*] \[[ xX]\] "#
    )
    private static let bulletMarkerRegex = try! NSRegularExpression(
        pattern: #"^[-*+] "#
    )
    private static let orderedMarkerRegex = try! NSRegularExpression(
        pattern: #"^(\d{1,3})([.)]) "#
    )
}

// MARK: - MarkdownFormatBar

/// The format row docked to the bottom of the editing cabin — quiet SF
/// Symbol glyphs over the cabin's own surface, separated by a hairline.
/// Actions land on the editor's coordinator via MarkdownEditorController.
struct MarkdownFormatBar: View {

    enum Action: CaseIterable {
        case bold, italic, strike, code, bullet, task, quote

        var symbol: String {
            switch self {
            case .bold:   return "bold"
            case .italic: return "italic"
            case .strike: return "strikethrough"
            case .code:   return "chevron.left.forwardslash.chevron.right"
            case .bullet: return "list.bullet"
            case .task:   return "checklist"
            case .quote:  return "text.quote"
            }
        }

        var a11yLabel: String {
            switch self {
            case .bold:   return NSLocalizedString("markdown.bar.bold", value: "加粗", comment: "Format bar")
            case .italic: return NSLocalizedString("markdown.bar.italic", value: "斜体", comment: "Format bar")
            case .strike: return NSLocalizedString("markdown.bar.strike", value: "删除线", comment: "Format bar")
            case .code:   return NSLocalizedString("markdown.bar.code", value: "行内代码", comment: "Format bar")
            case .bullet: return NSLocalizedString("markdown.bar.bullet", value: "列表", comment: "Format bar")
            case .task:   return NSLocalizedString("markdown.bar.task", value: "任务清单", comment: "Format bar")
            case .quote:  return NSLocalizedString("markdown.bar.quote", value: "引用", comment: "Format bar")
            }
        }
    }

    let onAction: (Action) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(Action.allCases.enumerated()), id: \.offset) { _, action in
                Button {
                    onAction(action)
                } label: {
                    Image(systemName: action.symbol)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(DSColor.inkSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pressScale(scale: 0.9,
                            animation: .spring(response: 0.2, dampingFraction: 0.7))
                .accessibilityLabel(action.a11yLabel)
            }
        }
        .padding(.horizontal, 6)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(DSColor.inkFaint)
                .frame(height: 0.5)
                .padding(.horizontal, 10)
        }
    }
}

// MARK: - MarkdownSyntaxHighlighter

/// In-place NSAttributedString styling for the WYSIWYG editor. Content takes
/// its rendered style everywhere; syntax characters are *concealed*
/// (zero-size, clear) except on the revealed line, where they show in
/// receded amber for editing. Attribute-only writes — the string is never
/// mutated, so the selection and IME state survive every pass untouched.
enum MarkdownSyntaxHighlighter {

    // MARK: Palette / fonts (resolved per pass so trait changes track)

    private struct Ink {
        let body = UIColor(DSColor.inkPrimary)
        let secondary = UIColor(DSColor.inkSecondary)
        let muted = UIColor(DSColor.inkMuted)
        let accent = UIColor(DSColor.accentOnBg)
        let syntax = UIColor(DSColor.accentOnBg).withAlphaComponent(0.55)
        let codeBackground = UIColor(DSColor.surfaceSunken)

        let bodyFont = DSFonts.serifUIFont(size: 16)
        let boldFont = DSFonts.serifUIFont(size: 16, weight: .semibold)
        let italicFont = DSFonts.serifUIFont(size: 16, italic: true)
        let headingFont = DSFonts.serifUIFont(size: 18.5, weight: .semibold)
        let monoFont = UIFont(name: "JetBrainsMono-Regular", size: 13)
            ?? UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let monoSmallFont = UIFont(name: "JetBrainsMono-Regular", size: 12)
            ?? UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        /// Typora-style concealment: syntax characters shrink to nothing and
        /// go clear. The string is untouched, so ranges and the caret map
        /// stay valid — the characters just stop taking up space.
        let conceal: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 0.001),
            .foregroundColor: UIColor.clear,
        ]
    }

    static func baseAttributes() -> [NSAttributedString.Key: Any] {
        let ink = Ink()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 6
        return [
            .font: ink.bodyFont,
            .foregroundColor: ink.body,
            .paragraphStyle: paragraph,
        ]
    }

    // MARK: Entry point

    /// `revealing` — line range (usually the caret's line) whose syntax stays
    /// visible; everywhere else syntax conceals to rendered prose.
    static func apply(to storage: NSTextStorage, revealing reveal: NSRange? = nil) {
        let ink = Ink()
        let text = storage.string as NSString
        let full = NSRange(location: 0, length: text.length)

        storage.beginEditing()
        storage.setAttributes(baseAttributes(), range: full)

        var inFence = false
        text.enumerateSubstrings(in: full, options: [.byLines, .substringNotRequired]) { _, lineRange, enclosingRange, _ in
            let line = text.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let revealed = isRevealed(enclosingRange, reveal: reveal)

            if trimmed.hasPrefix("```") {
                storage.addAttributes(
                    [.font: ink.monoSmallFont, .foregroundColor: ink.muted],
                    range: lineRange
                )
                inFence.toggle()
                return
            }
            if inFence {
                storage.addAttributes(
                    [.font: ink.monoFont, .foregroundColor: ink.body,
                     .backgroundColor: ink.codeBackground],
                    range: lineRange
                )
                return
            }

            styleBlockMarkers(
                line: line, lineRange: lineRange,
                storage: storage, ink: ink, revealed: revealed
            )
            styleInline(
                line: line, lineRange: lineRange,
                storage: storage, ink: ink, revealed: revealed
            )
        }
        storage.endEditing()
    }

    private static func isRevealed(_ enclosingRange: NSRange, reveal: NSRange?) -> Bool {
        guard let reveal else { return false }
        if NSIntersectionRange(enclosingRange, reveal).length > 0 { return true }
        // Zero-length caret ranges (empty line / document end) intersect nothing.
        return NSLocationInRange(reveal.location, enclosingRange)
            || reveal.location == NSMaxRange(enclosingRange)
    }

    // MARK: Block markers
    //
    // Semantic markers (list dash, task box, quote bar, divider) stay visible
    // on every line — they carry meaning. Only heading hashes conceal: the
    // larger semibold face already says "heading".

    private static func styleBlockMarkers(
        line: String, lineRange: NSRange, storage: NSTextStorage, ink: Ink, revealed: Bool
    ) {
        let ns = line as NSString
        let local = NSRange(location: 0, length: ns.length)
        func global(_ r: NSRange) -> NSRange {
            NSRange(location: lineRange.location + r.location, length: r.length)
        }

        if let m = headingRegex.firstMatch(in: line, range: local) {
            storage.addAttributes([.font: ink.headingFont], range: lineRange)
            // Hashes + trailing space conceal off-line, mono amber on-line.
            let marker = NSRange(location: 0, length: m.range(at: 1).length + 1)
            storage.addAttributes(
                revealed
                    ? [.font: ink.monoSmallFont, .foregroundColor: ink.syntax]
                    : ink.conceal,
                range: global(marker)
            )
            return
        }
        if dividerRegex.firstMatch(in: line, range: local) != nil {
            storage.addAttributes(
                [.font: ink.monoSmallFont, .foregroundColor: ink.muted],
                range: lineRange
            )
            return
        }
        if let m = quoteRegex.firstMatch(in: line, range: local) {
            storage.addAttributes(
                [.font: ink.italicFont, .foregroundColor: ink.secondary],
                range: lineRange
            )
            storage.addAttributes(
                [.foregroundColor: ink.syntax],
                range: global(m.range(at: 1))
            )
            return
        }
        if let m = taskRegex.firstMatch(in: line, range: local) {
            storage.addAttributes(
                [.font: ink.monoFont, .foregroundColor: ink.accent],
                range: global(m.range(at: 1))
            )
            // Checked items dim their content — same read as the card.
            if ns.substring(with: m.range(at: 2)).lowercased() == "x" {
                let contentStart = m.range.length
                if contentStart < ns.length {
                    storage.addAttributes(
                        [.foregroundColor: ink.secondary],
                        range: global(NSRange(location: contentStart, length: ns.length - contentStart))
                    )
                }
            }
            return
        }
        if let m = bulletRegex.firstMatch(in: line, range: local) {
            storage.addAttributes(
                [.foregroundColor: ink.accent],
                range: global(m.range(at: 1))
            )
            return
        }
        if let m = orderedRegex.firstMatch(in: line, range: local) {
            storage.addAttributes(
                [.font: ink.monoFont, .foregroundColor: ink.syntax],
                range: global(m.range(at: 1))
            )
        }
    }

    // MARK: Inline spans

    private static func styleInline(
        line: String, lineRange: NSRange, storage: NSTextStorage, ink: Ink, revealed: Bool
    ) {
        let ns = line as NSString
        let local = NSRange(location: 0, length: ns.length)
        var consumed: [NSRange] = []
        func global(_ r: NSRange) -> NSRange {
            NSRange(location: lineRange.location + r.location, length: r.length)
        }
        func overlapsConsumed(_ r: NSRange) -> Bool {
            consumed.contains { NSIntersectionRange($0, r).length > 0 }
        }
        /// Delimiters: receded amber on the revealed line, gone elsewhere.
        func delimiterAttrs(mono: Bool) -> [NSAttributedString.Key: Any] {
            if revealed {
                var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: ink.syntax]
                if mono { attrs[.font] = ink.monoFont }
                return attrs
            }
            return ink.conceal
        }

        // Spans: (regex, delimiter UTF-16 length on each side, content attrs).
        // Delimiters are fixed-width, so their ranges derive from the match
        // range arithmetically — group 1 is always the content.
        // Code claims its range first: no emphasis inside `code`.
        let spans: [(NSRegularExpression, Int, Bool, [NSAttributedString.Key: Any])] = [
            (codeSpanRegex, 1, true, [
                .font: ink.monoFont,
                .foregroundColor: ink.body,
                .backgroundColor: ink.codeBackground,
            ]),
            (boldRegex, 2, false, [.font: ink.boldFont]),
            (italicRegex, 1, false, [.font: ink.italicFont]),
            (strikeRegex, 2, false, [
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .strikethroughColor: ink.secondary,
                .foregroundColor: ink.secondary,
            ]),
        ]
        for (regex, delimLen, monoDelims, contentAttrs) in spans {
            regex.enumerateMatches(in: line, range: local) { m, _, _ in
                guard let m, !overlapsConsumed(m.range) else { return }
                consumed.append(m.range)
                storage.addAttributes(contentAttrs, range: global(m.range(at: 1)))
                let head = NSRange(location: m.range.location, length: delimLen)
                let tail = NSRange(location: NSMaxRange(m.range) - delimLen, length: delimLen)
                let attrs = delimiterAttrs(mono: monoDelims)
                storage.addAttributes(attrs, range: global(head))
                storage.addAttributes(attrs, range: global(tail))
            }
        }

        // Wikilinks: [[slug]] shows just the amber slug when concealed.
        wikilinkRegex.enumerateMatches(in: line, range: local) { m, _, _ in
            guard let m, !overlapsConsumed(m.range) else { return }
            consumed.append(m.range)
            let attrs = delimiterAttrs(mono: false)
            let head = NSRange(location: m.range.location, length: 2)
            let tail = NSRange(location: NSMaxRange(m.range) - 2, length: 2)
            storage.addAttributes(attrs, range: global(head))
            storage.addAttributes(attrs, range: global(tail))
            storage.addAttributes(
                [.foregroundColor: ink.accent,
                 .underlineStyle: NSUnderlineStyle.single.rawValue,
                 .underlineColor: UIColor(DSColor.amberRim)],
                range: global(m.range(at: 1))
            )
        }

        // Links: [label](url) collapses to just the amber label off-line.
        linkRegex.enumerateMatches(in: line, range: local) { m, _, _ in
            guard let m, !overlapsConsumed(m.range) else { return }
            consumed.append(m.range)
            let label = m.range(at: 1)
            let attrs = delimiterAttrs(mono: false)
            let head = NSRange(location: m.range.location, length: label.location - m.range.location)
            let tail = NSRange(location: NSMaxRange(label), length: NSMaxRange(m.range) - NSMaxRange(label))
            storage.addAttributes(attrs, range: global(head))
            storage.addAttributes(attrs, range: global(tail))
            storage.addAttributes(
                [.foregroundColor: ink.accent,
                 .underlineStyle: NSUnderlineStyle.single.rawValue,
                 .underlineColor: UIColor(DSColor.amberRim)],
                range: global(label)
            )
        }
    }

    // MARK: Regexes (group 1 = content everywhere)

    private static let headingRegex = try! NSRegularExpression(pattern: #"^(#{1,6}) \S"#)
    private static let dividerRegex = try! NSRegularExpression(pattern: #"^-{3,}\s*$"#)
    private static let quoteRegex = try! NSRegularExpression(pattern: #"^(> ?)"#)
    private static let taskRegex = try! NSRegularExpression(pattern: #"^([-*] \[([ xX])\] )"#)
    private static let bulletRegex = try! NSRegularExpression(pattern: #"^([-*+] )"#)
    private static let orderedRegex = try! NSRegularExpression(pattern: #"^(\d{1,3}[.)] )"#)

    private static let codeSpanRegex = try! NSRegularExpression(
        pattern: #"`([^`\n]+)`"#
    )
    private static let boldRegex = try! NSRegularExpression(
        pattern: #"\*\*([^*\n]+?)\*\*"#
    )
    private static let italicRegex = try! NSRegularExpression(
        pattern: #"(?<!\*)\*(?!\*)([^*\n]+?)(?<!\*)\*(?!\*)"#
    )
    private static let strikeRegex = try! NSRegularExpression(
        pattern: #"~~([^~\n]+?)~~"#
    )
    private static let wikilinkRegex = try! NSRegularExpression(
        pattern: #"\[\[([^\]\n]+?)\]\]"#
    )
    private static let linkRegex = try! NSRegularExpression(
        pattern: #"\[([^\]\n]+?)\]\((?:https?|mailto)[^)\n]*\)"#
    )
}
