import SwiftUI

// MARK: - Components.swift (slimmed)
//
// This file used to host the v1 Material black-and-white component set
// (PrimaryStampButton, SecondaryOutlineButton, FieldChip, TimeChip,
// CardContainer, SectionHeading, SurfaceElevatedShadow). Those structs
// had no external callers and conflicted with the v4 Liquid Glass +
// warm-amber language, so they were removed during the design-system
// converge sweep. The replacements live under DesignSystem/Components/:
//
//   PrimaryStampButton  → Button { … }.buttonStyle(.dsPrimary)
//   SecondaryOutlineBtn → Button { … }.buttonStyle(.dsSecondary)
//   FieldChip / TimeChip → DSChip(label:, icon:, kind:)
//   CardContainer       → ZStack { … }.liquidGlassCard()
//   SectionHeading      → use DSType.sectionLabel directly
//   SurfaceElevatedShadow → .elevation(.glass)
//
// The three structs below survived because they have live callers in
// Archive / Daily / Entity views. They have been rewritten on top of
// DS tokens so their visual language matches the rest of the app.

// MARK: - Status Badge

enum BadgeStyle {
    case verified
    case metadata
}

struct StatusBadge: View {
    let label: String
    let style: BadgeStyle

    var body: some View {
        DSChip(
            label: label,
            kind: style == .verified ? .primary : .mono
        )
    }
}

// MARK: - Wikilink Text (single-link inline)

struct WikilinkText: View {
    let text: String
    var onTap: (() -> Void)?

    var body: some View {
        Text(text)
            .bodySMStyle()
            .foregroundColor(DSColor.amberAccent)
            .onTapGesture { onTap?() }
    }
}

// MARK: - Wikilink Body Text
//
// Renders a paragraph that may contain [[slug]] or [[slug|display]]
// wiki-links. Links render in amber; tapping any of them triggers the
// callback with the *first* link's inner slug — sufficient for
// single-entity paragraphs which is the common case.

struct WikilinkBodyText: View {
    let text: String
    let onWikilinkTap: (String) -> Void

    private struct Segment {
        let content: String
        let isLink: Bool
        let inner: String
    }

    private var segments: [Segment] {
        var result: [Segment] = []
        let pattern = try? NSRegularExpression(pattern: #"\[\[([^\]]+)\]\]"#)
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = pattern?.matches(in: text, range: fullRange) ?? []
        var lastEnd = text.startIndex

        for match in matches {
            guard let matchRange = Range(match.range, in: text),
                  let innerRange = Range(match.range(at: 1), in: text) else { continue }
            let inner = String(text[innerRange])
            let before = String(text[lastEnd ..< matchRange.lowerBound])
            if !before.isEmpty { result.append(Segment(content: before, isLink: false, inner: "")) }
            let displayName = inner.contains("|")
                ? String(inner.split(separator: "|", maxSplits: 1).last ?? Substring(inner))
                : inner.replacingOccurrences(of: "-", with: " ").capitalized
            result.append(Segment(content: "[[" + displayName + "]]", isLink: true, inner: inner))
            lastEnd = matchRange.upperBound
        }
        let tail = String(text[lastEnd...])
        if !tail.isEmpty { result.append(Segment(content: tail, isLink: false, inner: "")) }
        return result
    }

    private var firstLinkInner: String? {
        segments.first(where: { $0.isLink })?.inner
    }

    var body: some View {
        let rendered = segments.reduce(Text("")) { acc, seg in
            if seg.isLink {
                return acc + Text(seg.content)
                    .font(.custom("Inter-Medium", size: 15))
                    .foregroundColor(DSColor.amberAccent)
            } else {
                return acc + Text(seg.content)
                    .font(.custom("Inter-Regular", size: 15))
                    .foregroundColor(DSColor.inkPrimary)
            }
        }

        if let linkInner = firstLinkInner {
            rendered
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onTapGesture { onWikilinkTap(linkInner) }
        } else {
            rendered
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
