import Foundation

// MARK: - MemoMarkdown

/// Hand-rolled lightweight Markdown parser for memo bodies (Markdown M1).
///
/// Scope is deliberately card-sized — the subset a 16pt serif card can carry
/// without shouting: emphasis, inline code, lists, task lists, quotes, links,
/// wikilinks, dividers, fenced code. Headings of any level collapse into a
/// single "card heading" tier. Tables, images and raw HTML are *never*
/// parsed; unknown syntax falls through as literal text, so no memo can
/// render worse than today's plain-text path.
///
/// Pure render-layer, like `CJKTextPolish`: parsing NEVER feeds back into
/// the vault. Unmatched delimiters stay literal (`**oops` renders as-is).
public enum MemoMarkdown {

    // MARK: - Model

    /// A styled slice of inline text. Flags compose (bold + italic + strike).
    public struct InlineRun: Equatable {
        public var text: String
        public var bold: Bool
        public var italic: Bool
        public var strike: Bool
        public var code: Bool
        /// External destination for `[text](url)`.
        public var linkURL: URL?
        /// Target slug for `[[slug]]` / `[[slug|display]]`; `text` holds the display form.
        public var wikilinkSlug: String?

        public init(
            text: String,
            bold: Bool = false,
            italic: Bool = false,
            strike: Bool = false,
            code: Bool = false,
            linkURL: URL? = nil,
            wikilinkSlug: String? = nil
        ) {
            self.text = text
            self.bold = bold
            self.italic = italic
            self.strike = strike
            self.code = code
            self.linkURL = linkURL
            self.wikilinkSlug = wikilinkSlug
        }

        /// True when the run carries no styling at all.
        public var isPlain: Bool {
            !bold && !italic && !strike && !code && linkURL == nil && wikilinkSlug == nil
        }
    }

    public struct ListItem: Equatable {
        public var runs: [InlineRun]
        public init(runs: [InlineRun]) { self.runs = runs }
    }

    public struct TaskItem: Equatable {
        public var done: Bool
        public var runs: [InlineRun]
        public init(done: Bool, runs: [InlineRun]) {
            self.done = done
            self.runs = runs
        }
    }

    public enum Block: Equatable {
        case paragraph([InlineRun])
        /// `#`–`######` all collapse to this single tier (design: 标题降维).
        case heading([InlineRun])
        case bullets([ListItem])
        case ordered(start: Int, items: [ListItem])
        case tasks([TaskItem])
        /// Consecutive `>` lines merged; embedded newlines preserved.
        case quote([InlineRun])
        case codeBlock(String)
        case divider
    }

    public struct Document: Equatable {
        public let blocks: [Block]
        /// True when the source contained no markdown at all — renderers can
        /// take their existing plain-`Text` fast path and look identical to
        /// the pre-markdown app.
        public let isPlain: Bool
    }

    // MARK: - Cache

    /// Parse results keyed by source text. Memo bodies are immutable once
    /// written, so cache entries can never go stale; scrolling the Today
    /// feed re-parses nothing.
    private final class DocumentBox {
        let document: Document
        init(_ document: Document) { self.document = document }
    }

    private static let cache: NSCache<NSString, DocumentBox> = {
        let c = NSCache<NSString, DocumentBox>()
        c.countLimit = 512
        return c
    }()

    public static func cachedParse(_ text: String) -> Document {
        let key = text as NSString
        if let hit = cache.object(forKey: key) { return hit.document }
        let doc = parse(text)
        cache.setObject(DocumentBox(doc), forKey: key)
        return doc
    }

    // MARK: - Block parsing

    public static func parse(_ text: String) -> Document {
        var blocks: [Block] = []

        var paragraphLines: [String] = []
        var quoteLines: [String] = []
        var bulletItems: [ListItem] = []
        var orderedItems: [ListItem] = []
        var orderedStart = 1
        var taskItems: [TaskItem] = []
        var codeLines: [String] = []
        var inCodeFence = false

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(.paragraph(parseInline(paragraphLines.joined(separator: "\n"))))
            paragraphLines.removeAll()
        }
        func flushQuote() {
            guard !quoteLines.isEmpty else { return }
            blocks.append(.quote(parseInline(quoteLines.joined(separator: "\n"))))
            quoteLines.removeAll()
        }
        func flushBullets() {
            guard !bulletItems.isEmpty else { return }
            blocks.append(.bullets(bulletItems))
            bulletItems.removeAll()
        }
        func flushOrdered() {
            guard !orderedItems.isEmpty else { return }
            blocks.append(.ordered(start: orderedStart, items: orderedItems))
            orderedItems.removeAll()
        }
        func flushTasks() {
            guard !taskItems.isEmpty else { return }
            blocks.append(.tasks(taskItems))
            taskItems.removeAll()
        }
        /// Flush every open container except the one being appended to.
        func flushAll(except keep: BlockKind? = nil) {
            if keep != .paragraph { flushParagraph() }
            if keep != .quote { flushQuote() }
            if keep != .bullets { flushBullets() }
            if keep != .ordered { flushOrdered() }
            if keep != .tasks { flushTasks() }
        }

        for rawLine in text.components(separatedBy: "\n") {
            // Fenced code: swallow everything until the closing fence.
            let fenceCheck = rawLine.trimmingCharacters(in: .whitespaces)
            if fenceCheck.hasPrefix("```") {
                if inCodeFence {
                    blocks.append(.codeBlock(codeLines.joined(separator: "\n")))
                    codeLines.removeAll()
                    inCodeFence = false
                } else {
                    flushAll()
                    inCodeFence = true
                }
                continue
            }
            if inCodeFence {
                codeLines.append(rawLine)
                continue
            }

            // Block markers tolerate up to 3 leading spaces (CommonMark).
            let line = dropLeadingSpaces(rawLine, max: 3)

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushAll()
                continue
            }

            if isDivider(line) {
                flushAll()
                blocks.append(.divider)
                continue
            }

            if let content = headingContent(line) {
                flushAll()
                blocks.append(.heading(parseInline(content)))
                continue
            }

            if line.hasPrefix(">") {
                flushAll(except: .quote)
                var content = String(line.dropFirst())
                if content.hasPrefix(" ") { content = String(content.dropFirst()) }
                quoteLines.append(content)
                continue
            }

            if let (done, content) = taskContent(line) {
                flushAll(except: .tasks)
                taskItems.append(TaskItem(done: done, runs: parseInline(content)))
                continue
            }

            if let content = bulletContent(line) {
                flushAll(except: .bullets)
                bulletItems.append(ListItem(runs: parseInline(content)))
                continue
            }

            if let (number, content) = orderedContent(line) {
                flushAll(except: .ordered)
                if orderedItems.isEmpty { orderedStart = number }
                orderedItems.append(ListItem(runs: parseInline(content)))
                continue
            }

            flushAll(except: .paragraph)
            paragraphLines.append(rawLine)
        }

        if inCodeFence {
            // Unclosed fence at EOF — still render what was captured.
            blocks.append(.codeBlock(codeLines.joined(separator: "\n")))
        }
        flushAll()

        // Plain fast path: exactly one unstyled paragraph that reproduces
        // the source verbatim.
        var isPlain = false
        if blocks.count == 1,
           case .paragraph(let runs) = blocks[0],
           runs.count == 1,
           runs[0].isPlain,
           runs[0].text == text {
            isPlain = true
        }
        if blocks.isEmpty { isPlain = true }

        return Document(blocks: blocks, isPlain: isPlain)
    }

    private enum BlockKind { case paragraph, quote, bullets, ordered, tasks }

    private static func dropLeadingSpaces(_ line: String, max: Int) -> String {
        var count = 0
        for ch in line {
            if ch == " " && count < max { count += 1 } else { break }
        }
        return count > 0 ? String(line.dropFirst(count)) : line
    }

    private static func isDivider(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return false }
        return trimmed.allSatisfy { $0 == "-" }
    }

    /// `# Title` … `###### Title` → "Title". `#tag` (no space) is NOT a
    /// heading — hashtags survive as prose.
    private static func headingContent(_ line: String) -> String? {
        guard line.hasPrefix("#") else { return nil }
        var hashes = 0
        for ch in line {
            if ch == "#" { hashes += 1 } else { break }
        }
        guard hashes <= 6 else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.hasPrefix(" ") else { return nil }
        let content = rest.trimmingCharacters(in: .whitespaces)
        return content.isEmpty ? nil : content
    }

    /// `- [ ] text` / `- [x] text` (also `*` marker, case-insensitive x).
    private static func taskContent(_ line: String) -> (done: Bool, content: String)? {
        guard line.hasPrefix("- [") || line.hasPrefix("* [") else { return nil }
        let afterMarker = line.dropFirst(2) // "[x] …"
        guard afterMarker.count >= 3 else { return nil }
        let chars = Array(afterMarker.prefix(4))
        guard chars[0] == "[", chars[2] == "]" else { return nil }
        let done: Bool
        switch chars[1] {
        case " ": done = false
        case "x", "X": done = true
        default: return nil
        }
        guard chars.count >= 4, chars[3] == " " else {
            // "- [x]" with no trailing text still counts, as an empty item.
            let rest = afterMarker.dropFirst(3)
            return rest.isEmpty ? (done, "") : nil
        }
        return (done, String(afterMarker.dropFirst(4)))
    }

    /// `- text` / `* text` / `+ text`.
    private static func bulletContent(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            let content = String(line.dropFirst(2))
            return content.isEmpty ? nil : content
        }
        return nil
    }

    /// `1. text` / `12) text` — up to 3 digits.
    private static func orderedContent(_ line: String) -> (number: Int, content: String)? {
        var digits = ""
        var index = line.startIndex
        while index < line.endIndex, line[index].isNumber, digits.count < 3 {
            digits.append(line[index])
            index = line.index(after: index)
        }
        guard !digits.isEmpty, index < line.endIndex else { return nil }
        let punct = line[index]
        guard punct == "." || punct == ")" else { return nil }
        index = line.index(after: index)
        guard index < line.endIndex, line[index] == " " else { return nil }
        index = line.index(after: index)
        let content = String(line[index...])
        guard !content.isEmpty, let number = Int(digits) else { return nil }
        return (number, content)
    }

    // MARK: - Inline parsing

    /// Two-phase inline parser: tokenize, then pair emphasis delimiters.
    /// Unmatched delimiters demote to literal text — `**oops` never styles
    /// the rest of the line.
    public static func parseInline(_ text: String) -> [InlineRun] {
        guard !text.isEmpty else { return [] }

        // Phase 1 — tokenize.
        enum Tok {
            case text(String)
            case delim(Delim)
            case code(String)
            case link(label: String, url: URL)
            case wikilink(slug: String, display: String)
        }
        enum Delim { case bold, italic, strike }

        let chars = Array(text)
        var toks: [Tok] = []
        var buf = ""
        func flushBuf() {
            if !buf.isEmpty { toks.append(.text(buf)); buf = "" }
        }
        /// First index of `target` starting at `from`, or nil.
        func find(_ target: Character, from: Int) -> Int? {
            var i = from
            while i < chars.count {
                if chars[i] == target { return i }
                i += 1
            }
            return nil
        }

        var i = 0
        while i < chars.count {
            let c = chars[i]

            // Backslash escape for syntax characters.
            if c == "\\", i + 1 < chars.count, "*~`[".contains(chars[i + 1]) {
                buf.append(chars[i + 1])
                i += 2
                continue
            }

            if c == "`" {
                if let close = find("`", from: i + 1) {
                    flushBuf()
                    toks.append(.code(String(chars[(i + 1)..<close])))
                    i = close + 1
                } else {
                    buf.append(c)
                    i += 1
                }
                continue
            }

            if c == "*" {
                flushBuf()
                if i + 1 < chars.count, chars[i + 1] == "*" {
                    toks.append(.delim(.bold))
                    i += 2
                } else {
                    toks.append(.delim(.italic))
                    i += 1
                }
                continue
            }

            if c == "~", i + 1 < chars.count, chars[i + 1] == "~" {
                flushBuf()
                toks.append(.delim(.strike))
                i += 2
                continue
            }

            if c == "[" {
                if i + 1 < chars.count, chars[i + 1] == "[" {
                    // [[slug]] / [[slug|display]] — no ']' inside.
                    if let firstClose = find("]", from: i + 2),
                       firstClose + 1 < chars.count, chars[firstClose + 1] == "]" {
                        let inner = String(chars[(i + 2)..<firstClose])
                        if !inner.isEmpty {
                            let parts = inner.split(separator: "|", maxSplits: 1)
                            let slug = String(parts[0]).trimmingCharacters(in: .whitespaces)
                            let display = parts.count > 1
                                ? String(parts[1]).trimmingCharacters(in: .whitespaces)
                                : slug
                            if !slug.isEmpty {
                                flushBuf()
                                toks.append(.wikilink(slug: slug, display: display))
                                i = firstClose + 2
                                continue
                            }
                        }
                    }
                } else if let closeBracket = find("]", from: i + 1),
                          closeBracket + 1 < chars.count, chars[closeBracket + 1] == "(",
                          let closeParen = find(")", from: closeBracket + 2) {
                    let label = String(chars[(i + 1)..<closeBracket])
                    let urlString = String(chars[(closeBracket + 2)..<closeParen])
                    // Require an explicit scheme so "[a](b)" prose survives.
                    if !label.isEmpty,
                       let url = URL(string: urlString),
                       let scheme = url.scheme?.lowercased(),
                       ["http", "https", "mailto"].contains(scheme) {
                        flushBuf()
                        toks.append(.link(label: label, url: url))
                        i = closeParen + 1
                        continue
                    }
                }
                buf.append(c)
                i += 1
                continue
            }

            buf.append(c)
            i += 1
        }
        flushBuf()

        // Phase 2 — pair delimiters; demote unmatched ones to literal text.
        var boldOpen: Int?
        var italicOpen: Int?
        var strikeOpen: Int?
        var matched = Set<Int>()
        for (idx, tok) in toks.enumerated() {
            guard case .delim(let kind) = tok else { continue }
            switch kind {
            case .bold:
                if let open = boldOpen { matched.insert(open); matched.insert(idx); boldOpen = nil }
                else { boldOpen = idx }
            case .italic:
                if let open = italicOpen { matched.insert(open); matched.insert(idx); italicOpen = nil }
                else { italicOpen = idx }
            case .strike:
                if let open = strikeOpen { matched.insert(open); matched.insert(idx); strikeOpen = nil }
                else { strikeOpen = idx }
            }
        }

        // Phase 3 — walk tokens with active style flags, building runs.
        var runs: [InlineRun] = []
        var bold = false, italic = false, strike = false
        func appendText(_ s: String) {
            guard !s.isEmpty else { return }
            // Merge with the previous run when styles are identical.
            if var last = runs.last,
               last.code == false, last.linkURL == nil, last.wikilinkSlug == nil,
               last.bold == bold, last.italic == italic, last.strike == strike {
                last.text += s
                runs[runs.count - 1] = last
            } else {
                runs.append(InlineRun(text: s, bold: bold, italic: italic, strike: strike))
            }
        }
        for (idx, tok) in toks.enumerated() {
            switch tok {
            case .text(let s):
                appendText(s)
            case .delim(let kind):
                if matched.contains(idx) {
                    switch kind {
                    case .bold: bold.toggle()
                    case .italic: italic.toggle()
                    case .strike: strike.toggle()
                    }
                } else {
                    switch kind {
                    case .bold: appendText("**")
                    case .italic: appendText("*")
                    case .strike: appendText("~~")
                    }
                }
            case .code(let s):
                runs.append(InlineRun(text: s, code: true))
            case .link(let label, let url):
                runs.append(InlineRun(
                    text: label, bold: bold, italic: italic, strike: strike, linkURL: url
                ))
            case .wikilink(let slug, let display):
                runs.append(InlineRun(
                    text: display, bold: bold, italic: italic, strike: strike, wikilinkSlug: slug
                ))
            }
        }
        return runs
    }
}
