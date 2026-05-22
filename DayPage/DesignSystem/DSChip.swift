import SwiftUI

// MARK: - DSChip
//
// Capsule-shaped data/label container. Replaces the legacy `FieldChip`,
// `TimeChip` and `StatusBadge` from Components.swift (v1 black-and-white
// Material era).

enum DSChipKind {
    /// Default — glass fill, neutral ink (most common: tags, hashtags).
    case neutral
    /// Active amber state — for "selected" / "filter applied" chips.
    case active
    /// Solid amber pill — used for primary chip-shaped CTAs.
    case primary
    /// Subtle outlined — for "Optional" / "Post-MVP" markers.
    case ghost
    /// Mono / data chip — for timestamps, file sizes, counts.
    case mono

    fileprivate var fontProvider: () -> Font {
        switch self {
        case .neutral, .active, .primary, .ghost: return { DSType.labelSM }
        case .mono:                                 return { DSType.mono10 }
        }
    }

    fileprivate var foreground: Color {
        switch self {
        case .neutral: return DSColor.inkPrimary
        case .active:  return DSColor.amberDeep
        case .primary: return Color.white
        case .ghost:   return DSColor.inkSubtle
        case .mono:    return DSColor.inkMuted
        }
    }

    fileprivate var background: Color {
        switch self {
        case .neutral: return DSColor.glassLo
        case .active:  return DSColor.amberSoft
        case .primary: return DSColor.amberDeep
        case .ghost:   return Color.clear
        case .mono:    return DSColor.glassLo
        }
    }

    fileprivate var stroke: Color? {
        switch self {
        case .ghost:  return DSColor.glassRim
        case .active: return DSColor.amberRim
        default:      return nil
        }
    }
}

struct DSChip: View {
    let label: String
    var icon: String? = nil
    var kind: DSChipKind = .neutral
    var onTap: (() -> Void)? = nil

    var body: some View {
        let content = HStack(spacing: DSSpacing.xs) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
            }
            Text(label)
                .font(kind.fontProvider())
                .textCase(kind == .mono ? .uppercase : nil)
                .tracking(kind == .mono ? 0.8 : 0)
        }
        .foregroundColor(kind.foreground)
        .padding(.horizontal, DSSpacing.sm)
        .padding(.vertical, 4)
        .background(kind.background, in: Capsule())
        .overlay(
            Group {
                if let stroke = kind.stroke {
                    Capsule().strokeBorder(stroke, lineWidth: 0.5)
                }
            }
        )

        if let onTap {
            Button(action: onTap) { content }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        } else {
            content
        }
    }
}
