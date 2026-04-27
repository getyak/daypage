import SwiftUI

// MARK: - Global Corner Radius Override
// All DS components use cornerRadius(0). UIKit bridging views should also
// have their layer.cornerRadius set to 0 at init.

// MARK: - Primary Stamp Button

struct PrimaryStampButton: View {
    let title: String
    let action: () -> Void
    var isEnabled: Bool = true

    var body: some View {
        Button(action: action) {
            Text(title)
                .sectionLabelStyle()
                .foregroundColor(DSColor.onPrimary)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(isEnabled ? DSColor.primary : DSColor.onSurfaceVariant)
                .cornerRadius(0)
        }
        .disabled(!isEnabled)
    }
}

// MARK: - Secondary Outline Button

struct SecondaryOutlineButton: View {
    let title: String
    let action: () -> Void
    var isEnabled: Bool = true

    var body: some View {
        Button(action: action) {
            Text(title)
                .sectionLabelStyle()
                .foregroundColor(isEnabled ? DSColor.primary : DSColor.onSurfaceVariant)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(DSColor.surface)
                .cornerRadius(0)
                .overlay(
                    Rectangle()
                        .stroke(isEnabled ? DSColor.primary : DSColor.outlineVariant, lineWidth: 1)
                )
        }
        .disabled(!isEnabled)
    }
}

// MARK: - Field Chip

struct FieldChip: View {
    let label: String
    let value: String
    var onTap: (() -> Void)?

    var body: some View {
        Button(action: { onTap?() }) {
            HStack(spacing: 4) {
                Text(label)
                    .monoLabelStyle(size: 9)
                    .foregroundColor(DSColor.onSurfaceVariant)
                Text(value)
                    .monoLabelStyle(size: 9)
                    .foregroundColor(DSColor.onSurface)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(DSColor.surfaceContainerHigh)
            .cornerRadius(0)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Time Chip

struct TimeChip: View {
    let time: String

    var body: some View {
        Text(time)
            .monoLabelStyle(size: 10)
            .foregroundColor(DSColor.onSurfaceVariant)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(DSColor.surfaceContainer)
            .cornerRadius(0)
    }
}

// MARK: - Section Heading with Horizontal Rule

struct SectionHeading: View {
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .sectionLabelStyle()
                .foregroundColor(DSColor.onSurface)
                .fixedSize()
            Rectangle()
                .fill(DSColor.outlineVariant)
                .frame(height: 1)
        }
    }
}

// MARK: - Wikilink Text

struct WikilinkText: View {
    let text: String
    var onTap: (() -> Void)?

    var body: some View {
        Text(text)
            .bodySMStyle()
            .foregroundColor(DSColor.amberArchival)
            .underline(false)
            .onTapGesture { onTap?() }
    }
}

// MARK: - Wikilink Body Text

/// 渲染可能包含 [[slug]] 或 [[slug|显示名称]] 维基链接的文本块。
/// 维基链接以琥珀色渲染；点击任何维基链接都会触发第一个
/// 找到的链接的回调，这对于大多数单实体段落来说已经足够。
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
                    .foregroundColor(DSColor.amberArchival)
            } else {
                return acc + Text(seg.content)
                    .font(.custom("Inter-Regular", size: 15))
                    .foregroundColor(DSColor.onSurface)
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

// MARK: - Status Badge

enum BadgeStyle {
    case verified    // black bg / white text
    case metadata    // gray bg / gray text
}

struct StatusBadge: View {
    let label: String
    let style: BadgeStyle

    var body: some View {
        Text(label)
            .monoLabelStyle(size: 9)
            .foregroundColor(style == .verified ? DSColor.onPrimary : DSColor.onSurfaceVariant)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(style == .verified ? DSColor.primary : DSColor.surfaceContainerHigh)
            .cornerRadius(0)
    }
}

// MARK: - Card Container (surface-container with optional left border)

struct CardContainer<Content: View>: View {
    let content: () -> Content
    var leadingBorderColor: Color?

    var body: some View {
        HStack(spacing: 0) {
            if let borderColor = leadingBorderColor {
                Rectangle()
                    .fill(borderColor)
                    .frame(width: 4)
            }
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(DSColor.surfaceContainer)
        }
        .cornerRadius(0)
    }
}
