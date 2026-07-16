import SwiftUI
import DayPageModels

// MARK: - MarkdownBodyView

/// Renders a memo body's lightweight Markdown (`MemoMarkdown`) in the app's
/// museum voice — serif prose, amber ink, mono for code. This is the single
/// "ink engine" surface: inline markdown, `[[wikilinks]]` and compiled entity
/// mentions all land in one AttributedString pass, so the three legacy
/// ad-hoc rich-text paths (entity ink / WikilinkBodyText / plain Text) can
/// converge here over time.
///
/// Render-only: never writes back to the vault. When the source contains no
/// markdown at all (`Document.isPlain`), rendering degrades to the exact
/// plain-`Text` look the app shipped before markdown existed.
struct MarkdownBodyView: View {

    let document: MemoMarkdown.Document
    /// Original source — used for the plain fast path.
    private let sourceText: String

    /// Base body point size; emphasis derives from it (code ≈ 0.82×).
    var bodySize: CGFloat = 16
    /// Additive line spacing inside a block (card 2 / detail 8).
    var lineSpacing: CGFloat = 2
    /// Vertical rhythm between blocks.
    var blockSpacing: CGFloat = 10
    /// When false, links render styled but inert (Today cards live inside
    /// tap/swipe surfaces — a live link would steal the card tap).
    var linksActive: Bool = true
    /// Compiled entity mentions to ink (MemoDetail passes these).
    var entitySlugs: [String] = []
    var entityDisplayNames: [String: String] = [:]

    init(
        text: String,
        bodySize: CGFloat = 16,
        lineSpacing: CGFloat = 2,
        blockSpacing: CGFloat = 10,
        linksActive: Bool = true,
        entitySlugs: [String] = [],
        entityDisplayNames: [String: String] = [:]
    ) {
        self.sourceText = text
        self.document = MemoMarkdown.cachedParse(text)
        self.bodySize = bodySize
        self.lineSpacing = lineSpacing
        self.blockSpacing = blockSpacing
        self.linksActive = linksActive
        self.entitySlugs = entitySlugs
        self.entityDisplayNames = entityDisplayNames
    }

    var body: some View {
        if document.isPlain {
            // Identical to the pre-markdown rendering path — entity ink
            // still applies so MemoDetail keeps its amber mentions.
            Text(inked(AttributedString(CJKTextPolish.polish(sourceText))))
                .font(DSFonts.serif(size: bodySize, relativeTo: .body))
                .foregroundColor(DSColor.inkPrimary)
                .lineSpacing(lineSpacing)
        } else {
            VStack(alignment: .leading, spacing: blockSpacing) {
                ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
        }
    }

    // MARK: - Blocks

    @ViewBuilder
    private func blockView(_ block: MemoMarkdown.Block) -> some View {
        switch block {
        case .paragraph(let runs):
            Text(attributed(runs))
                .lineSpacing(lineSpacing)

        case .heading(let runs):
            // 标题降维: every #-level lands on one quiet card-heading tier.
            Text(attributed(runs, baseWeight: .semibold, size: bodySize + 2.5))
                .lineSpacing(lineSpacing)
                .padding(.top, 4)

        case .bullets(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("–")
                            .font(DSFonts.serif(size: bodySize, relativeTo: .body))
                            .foregroundColor(DSColor.inkMuted)
                        Text(attributed(item.runs))
                            .lineSpacing(lineSpacing)
                    }
                }
            }

        case .ordered(let start, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(start + index).")
                            .font(DSFonts.jetBrainsMono(size: bodySize * 0.75, relativeTo: .caption))
                            .foregroundColor(DSColor.inkMuted)
                            .frame(minWidth: 18, alignment: .trailing)
                        Text(attributed(item.runs))
                            .lineSpacing(lineSpacing)
                    }
                }
            }

        case .tasks(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 10) {
                        taskBox(done: item.done)
                            // Optically centers the 15pt box against the
                            // first line of 16pt serif text.
                            .padding(.top, bodySize * 0.22)
                        Text(attributed(item.runs, dimmed: item.done))
                            .lineSpacing(lineSpacing)
                    }
                }
            }

        case .quote(let runs):
            Text(attributed(runs, forceItalic: true, dimmed: true))
                .lineSpacing(lineSpacing)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(DSColor.amberRim)
                        .frame(width: 2)
                }

        case .codeBlock(let code):
            Text(code)
                .font(DSFonts.jetBrainsMono(size: bodySize * 0.8, relativeTo: .callout))
                .foregroundColor(DSColor.inkPrimary)
                .lineSpacing(3)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DSColor.surfaceSunken)
                )

        case .divider:
            Rectangle()
                .fill(DSColor.inkFaint)
                .frame(height: 0.5)
                .padding(.horizontal, 24)
                .padding(.vertical, 4)
        }
    }

    private func taskBox(done: Bool) -> some View {
        ZStack {
            if done {
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .fill(DSColor.amberAccent)
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
            } else {
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .strokeBorder(DSColor.inkMuted, lineWidth: 1.5)
            }
        }
        .frame(width: 15, height: 15)
        .accessibilityLabel(done
            ? NSLocalizedString("markdown.task.done", value: "已完成", comment: "Markdown task checkbox — done")
            : NSLocalizedString("markdown.task.todo", value: "未完成", comment: "Markdown task checkbox — not done"))
    }

    // MARK: - Inline assembly

    /// Builds one styled AttributedString from inline runs, then lays the
    /// entity ink over the assembled block.
    private func attributed(
        _ runs: [MemoMarkdown.InlineRun],
        baseWeight: Font.Weight = .regular,
        size: CGFloat? = nil,
        forceItalic: Bool = false,
        dimmed: Bool = false
    ) -> AttributedString {
        let pointSize = size ?? bodySize
        var out = AttributedString()

        for run in runs {
            var piece = AttributedString(CJKTextPolish.polish(run.text))

            if run.code {
                piece.font = DSFonts.jetBrainsMono(size: pointSize * 0.82, relativeTo: .callout)
                piece.backgroundColor = DSColor.surfaceSunken
                piece.foregroundColor = DSColor.inkPrimary
            } else {
                // Serif has no true bold face — semibold is the loudest the
                // card is allowed to get. Italic overrides weight (single
                // italic face), matching DSFonts.serif's own resolution.
                let weight: Font.Weight = run.bold ? .semibold : baseWeight
                piece.font = DSFonts.serif(
                    size: pointSize,
                    weight: weight,
                    italic: run.italic || forceItalic,
                    relativeTo: .body
                )
                piece.foregroundColor = (run.strike || dimmed)
                    ? DSColor.inkSecondary
                    : DSColor.inkPrimary
                if run.strike {
                    piece.strikethroughStyle = Text.LineStyle(pattern: .solid, color: nil)
                }
            }

            if let url = run.linkURL {
                if linksActive { piece.link = url }
                piece.foregroundColor = DSColor.accentOnBg
                piece.underlineStyle = Text.LineStyle(pattern: .solid, color: DSColor.amberRim)
            }

            if let slug = run.wikilinkSlug {
                if linksActive, let url = Self.entityURL(for: slug) {
                    piece.link = url
                }
                piece.foregroundColor = DSColor.accentOnBg
                piece.underlineStyle = Text.LineStyle(
                    pattern: .solid,
                    color: DSColor.amberAccent.opacity(0.5)
                )
            }

            out += piece
        }

        return inked(out)
    }

    // MARK: - Entity ink (merged from MemoDetailView, issue #835)

    /// Lays compiled entity mentions over an assembled block as quiet
    /// amber-underlined links. Never stomps an explicit markdown link.
    private func inked(_ input: AttributedString) -> AttributedString {
        guard !entitySlugs.isEmpty else { return input }
        var attr = input

        for slug in entitySlugs where !slug.isEmpty {
            // Latin slugs may appear verbatim or space-separated; CJK prose
            // is matched via the wiki page's display name (resolved async by
            // the host view). First variant that matches wins.
            var terms = [slug, slug.replacingOccurrences(of: "-", with: " ")]
            if let display = entityDisplayNames[slug], !display.isEmpty {
                terms.insert(display, at: 0)
            }
            for term in terms {
                var matched = false
                var searchStart = attr.startIndex
                while searchStart < attr.endIndex,
                      let r = attr[searchStart...].range(
                        of: term,
                        options: [.caseInsensitive, .diacriticInsensitive]
                      ) {
                    matched = true
                    searchStart = r.upperBound
                    // Skip ranges that already carry a link (markdown link /
                    // wikilink / earlier entity) — first ink wins.
                    guard attr[r].link == nil else { continue }
                    if linksActive {
                        attr[r].link = Self.entityURL(for: slug)
                    }
                    attr[r].underlineStyle = Text.LineStyle(
                        pattern: .solid,
                        color: DSColor.amberAccent.opacity(0.5)
                    )
                    // Links default to tint blue — keep journal ink.
                    attr[r].foregroundColor = DSColor.inkPrimary
                }
                if matched { break }
            }
        }
        return attr
    }

    /// Same scheme MemoDetailView registered for entity taps — wikilinks and
    /// entity ink both route through the host's `openURL` handler.
    private static func entityURL(for slug: String) -> URL? {
        let encoded = slug.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? slug
        return URL(string: "daypage-entity://o?s=\(encoded)")
    }
}
