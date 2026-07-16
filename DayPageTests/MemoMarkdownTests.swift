import Testing
import Foundation
import DayPageModels

/// Unit tests for the hand-rolled memo markdown parser (Markdown M1).
///
/// The invariant that matters most: NOTHING can render worse than the
/// plain-text path. Unmatched delimiters, malformed links and unknown syntax
/// must all fall through as literal text, and a markdown-free memo must take
/// the `isPlain` fast path so the app looks identical to pre-markdown builds.
@Suite("MemoMarkdown")
struct MemoMarkdownTests {

    // MARK: - Plain fast path

    @Test("markdown-free text is a single plain paragraph")
    func plainText() {
        let doc = MemoMarkdown.parse("清迈第三周，决定提前办签证。\n移民局周五只开到 15:30")
        #expect(doc.isPlain)
        #expect(doc.blocks.count == 1)
        guard case .paragraph(let runs) = doc.blocks[0] else {
            Issue.record("expected paragraph")
            return
        }
        #expect(runs == [MemoMarkdown.InlineRun(text: "清迈第三周，决定提前办签证。\n移民局周五只开到 15:30")])
    }

    @Test("empty input yields an empty plain document")
    func emptyInput() {
        let doc = MemoMarkdown.parse("")
        #expect(doc.isPlain)
        #expect(doc.blocks.isEmpty)
    }

    @Test("hashtag without space is NOT a heading")
    func hashtagIsNotHeading() {
        let doc = MemoMarkdown.parse("#nomad 生活")
        #expect(doc.isPlain)
    }

    // MARK: - Inline emphasis

    @Test("bold, italic, strike, code parse into styled runs")
    func inlineStyles() {
        let runs = MemoMarkdown.parseInline("把**签证**办了，*或许*吧，~~算了~~，用 `grab`")
        #expect(runs.contains(MemoMarkdown.InlineRun(text: "签证", bold: true)))
        #expect(runs.contains(MemoMarkdown.InlineRun(text: "或许", italic: true)))
        #expect(runs.contains(MemoMarkdown.InlineRun(text: "算了", strike: true)))
        #expect(runs.contains(MemoMarkdown.InlineRun(text: "grab", code: true)))
    }

    @Test("bold + italic compose on the same run")
    func nestedEmphasis() {
        let runs = MemoMarkdown.parseInline("***both***")
        #expect(runs.contains(MemoMarkdown.InlineRun(text: "both", bold: true, italic: true)))
    }

    @Test("unmatched delimiters demote to literal text")
    func unmatchedDelimiters() {
        let runs = MemoMarkdown.parseInline("2**3 = 8，价格 5*6")
        let joined = runs.map(\.text).joined()
        #expect(joined == "2**3 = 8，价格 5*6")
        let allPlain = runs.allSatisfy(\.isPlain)
        #expect(allPlain)
    }

    @Test("unclosed backtick stays literal")
    func unclosedBacktick() {
        let runs = MemoMarkdown.parseInline("用了 `grab 叫车")
        #expect(runs.map(\.text).joined() == "用了 `grab 叫车")
    }

    @Test("backslash escapes syntax characters")
    func escapes() {
        let runs = MemoMarkdown.parseInline(#"\*not italic\*"#)
        #expect(runs.map(\.text).joined() == "*not italic*")
        let allPlain = runs.allSatisfy(\.isPlain)
        #expect(allPlain)
    }

    // MARK: - Links

    @Test("markdown link with scheme parses; schemeless stays prose")
    func links() {
        let good = MemoMarkdown.parseInline("看 [攻略](https://example.com/a) 吧")
        #expect(good.contains(where: {
            $0.text == "攻略" && $0.linkURL?.absoluteString == "https://example.com/a"
        }))

        let prose = MemoMarkdown.parseInline("清单 [A](见附件) 在桌上")
        let noLinks = prose.allSatisfy { $0.linkURL == nil }
        #expect(noLinks)
        #expect(prose.map(\.text).joined() == "清单 [A](见附件) 在桌上")
    }

    @Test("wikilink with and without display name")
    func wikilinks() {
        let runs = MemoMarkdown.parseInline("和 [[naomi|Naomi]] 在 [[chiang-mai]] 见面")
        #expect(runs.contains(where: { $0.wikilinkSlug == "naomi" && $0.text == "Naomi" }))
        #expect(runs.contains(where: { $0.wikilinkSlug == "chiang-mai" && $0.text == "chiang-mai" }))
    }

    // MARK: - Block structure

    @Test("task list parses done state and groups consecutive items")
    func taskList() {
        let doc = MemoMarkdown.parse("- [x] TM.30 回执\n- [ ] 照片两张")
        #expect(doc.blocks.count == 1)
        guard case .tasks(let items) = doc.blocks[0] else {
            Issue.record("expected tasks block")
            return
        }
        #expect(items.count == 2)
        #expect(items[0].done)
        #expect(!items[1].done)
        #expect(items[0].runs.map(\.text).joined() == "TM.30 回执")
    }

    @Test("bullets and ordered lists group; ordered keeps start number")
    func lists() {
        let doc = MemoMarkdown.parse("- 甲\n- 乙\n\n3. 丙\n4. 丁")
        #expect(doc.blocks.count == 2)
        guard case .bullets(let bullets) = doc.blocks[0],
              case .ordered(let start, let items) = doc.blocks[1] else {
            Issue.record("expected bullets + ordered")
            return
        }
        #expect(bullets.count == 2)
        #expect(start == 3)
        #expect(items.count == 2)
    }

    @Test("consecutive quote lines merge into one block")
    func quoteMerge() {
        let doc = MemoMarkdown.parse("> 第一行\n> 第二行")
        #expect(doc.blocks.count == 1)
        guard case .quote(let runs) = doc.blocks[0] else {
            Issue.record("expected quote")
            return
        }
        #expect(runs.map(\.text).joined() == "第一行\n第二行")
    }

    @Test("all heading levels collapse to the single card-heading tier")
    func headingCollapse() {
        let doc = MemoMarkdown.parse("# 大\n\n### 小")
        #expect(doc.blocks.count == 2)
        for block in doc.blocks {
            guard case .heading = block else {
                Issue.record("expected heading, got \(block)")
                return
            }
        }
    }

    @Test("divider requires 3+ dashes on their own line")
    func divider() {
        let doc = MemoMarkdown.parse("上文\n\n---\n\n下文")
        #expect(doc.blocks.contains(.divider))
        // "--" 不是分隔线
        #expect(!MemoMarkdown.parse("--").blocks.contains(.divider))
    }

    @Test("code fence captures raw lines; unclosed fence still renders")
    func codeFence() {
        let doc = MemoMarkdown.parse("```\nlet a = 1\n**not bold**\n```")
        #expect(doc.blocks == [.codeBlock("let a = 1\n**not bold**")])

        let unclosed = MemoMarkdown.parse("```\nlet b = 2")
        #expect(unclosed.blocks == [.codeBlock("let b = 2")])
    }

    @Test("blank lines split paragraphs; single newlines stay inside one")
    func paragraphSplitting() {
        let doc = MemoMarkdown.parse("甲\n乙\n\n丙")
        #expect(doc.blocks.count == 2)
        guard case .paragraph(let first) = doc.blocks[0] else {
            Issue.record("expected paragraph")
            return
        }
        #expect(first.map(\.text).joined() == "甲\n乙")
    }

    @Test("mixed document parses in order")
    func mixedDocument() {
        let source = """
        决定把**签证**提前办。

        - [x] 回执
        - 移民局周五 15:30 关门

        > 代办 800฿

        ---

        *先续签再说。*
        """
        let doc = MemoMarkdown.parse(source)
        #expect(!doc.isPlain)
        var kinds: [String] = []
        for block in doc.blocks {
            switch block {
            case .paragraph: kinds.append("p")
            case .heading: kinds.append("h")
            case .bullets: kinds.append("ul")
            case .ordered: kinds.append("ol")
            case .tasks: kinds.append("task")
            case .quote: kinds.append("q")
            case .codeBlock: kinds.append("code")
            case .divider: kinds.append("hr")
            }
        }
        #expect(kinds == ["p", "task", "ul", "q", "hr", "p"])
    }

    @Test("cached parse returns identical documents")
    func cacheConsistency() {
        let text = "**cache** me"
        #expect(MemoMarkdown.cachedParse(text) == MemoMarkdown.parse(text))
        #expect(MemoMarkdown.cachedParse(text) == MemoMarkdown.cachedParse(text))
    }
}
