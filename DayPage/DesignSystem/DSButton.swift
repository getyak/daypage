import SwiftUI

// MARK: - DSButtonStyle
//
// Canonical button styles for the v4 Liquid Glass + warm-amber language.
// Use `Button(...) { ... }.buttonStyle(.dsPrimary)` (etc.) — the underlying
// implementations honor `isEnabled`, press-state scaling, Reduce Motion,
// and the 44pt minimum touch target.

enum DSButtonSize {
    /// Compact 36pt height — used inline (chips, popovers).
    case small
    /// Default 44pt height — primary screen-level CTAs.
    case medium
    /// Tall 52pt height — hero CTAs on Auth / Onboarding.
    case large

    fileprivate var height: CGFloat {
        switch self {
        case .small:  return 36
        case .medium: return 44
        case .large:  return 52
        }
    }

    fileprivate var horizontalPadding: CGFloat {
        switch self {
        case .small:  return DSSpacing.md
        case .medium: return DSSpacing.xl
        case .large:  return DSSpacing.xl2
        }
    }

    fileprivate var font: Font {
        switch self {
        case .small:  return DSType.labelSM
        case .medium: return DSType.titleSM
        case .large:  return DSType.titleSM
        }
    }
}

// MARK: - Primary (solid amber)

struct DSPrimaryButtonStyle: ButtonStyle {
    var size: DSButtonSize = .medium
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(size.font)
            .foregroundColor(isEnabled ? Color.white : Color.white.opacity(0.55))
            .frame(maxWidth: .infinity)
            .frame(height: size.height)
            .padding(.horizontal, size.horizontalPadding)
            .background(
                RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                    .fill(isEnabled ? DSColor.amberDeep : DSColor.inkSubtle)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(Motion.respectReduceMotion(.spring(response: 0.25, dampingFraction: 0.85)),
                       value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

// MARK: - Secondary (glass outlined)

struct DSSecondaryButtonStyle: ButtonStyle {
    var size: DSButtonSize = .medium
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(size.font)
            .foregroundColor(isEnabled ? DSColor.inkPrimary : DSColor.inkSubtle)
            .frame(maxWidth: .infinity)
            .frame(height: size.height)
            .padding(.horizontal, size.horizontalPadding)
            // Secondary button surface routed through the dual-track engine
            // (#771): iOS 26 → interactive native glass; iOS 16–25 → warm
            // faux-glass. The engine supplies the hairline rim.
            .dpGlass(.control, in: RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(Motion.respectReduceMotion(.spring(response: 0.25, dampingFraction: 0.85)),
                       value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

// MARK: - Ghost (text-only, minimal)

struct DSGhostButtonStyle: ButtonStyle {
    var size: DSButtonSize = .medium
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(size.font)
            .foregroundColor(isEnabled
                ? (configuration.isPressed ? DSColor.amberAccent : DSColor.inkMuted)
                : DSColor.inkSubtle)
            .frame(minHeight: 44)
            .padding(.horizontal, size.horizontalPadding)
            .contentShape(Rectangle())
    }
}

// MARK: - Destructive

struct DSDestructiveButtonStyle: ButtonStyle {
    var size: DSButtonSize = .medium
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(size.font)
            .foregroundColor(isEnabled ? Color.white : Color.white.opacity(0.55))
            .frame(maxWidth: .infinity)
            .frame(height: size.height)
            .padding(.horizontal, size.horizontalPadding)
            .background(
                RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                    .fill(isEnabled ? DSColor.errorRed : DSColor.inkSubtle)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(Motion.respectReduceMotion(.spring(response: 0.25, dampingFraction: 0.85)),
                       value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

// MARK: - Icon chip (36pt circular glass toolbar buttons)

/// Press feedback for the circular glass icon chips in toolbars (☰ / 🔍).
/// The chip itself (glassSurface + Circle clip) is drawn by the label;
/// this style only adds the touch response: a small scale dip plus an
/// ink deepen so every tap reads as acknowledged.
struct DSIconChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .opacity(configuration.isPressed ? 0.75 : 1.0)
            .animation(Motion.respectReduceMotion(.spring(response: 0.25, dampingFraction: 0.85)),
                       value: configuration.isPressed)
    }
}

// MARK: - ButtonStyle sugar

extension ButtonStyle where Self == DSPrimaryButtonStyle {
    static var dsPrimary: DSPrimaryButtonStyle { .init() }
    static func dsPrimary(size: DSButtonSize) -> DSPrimaryButtonStyle { .init(size: size) }
}

extension ButtonStyle where Self == DSSecondaryButtonStyle {
    static var dsSecondary: DSSecondaryButtonStyle { .init() }
    static func dsSecondary(size: DSButtonSize) -> DSSecondaryButtonStyle { .init(size: size) }
}

extension ButtonStyle where Self == DSGhostButtonStyle {
    static var dsGhost: DSGhostButtonStyle { .init() }
    static func dsGhost(size: DSButtonSize) -> DSGhostButtonStyle { .init(size: size) }
}

extension ButtonStyle where Self == DSDestructiveButtonStyle {
    static var dsDestructive: DSDestructiveButtonStyle { .init() }
    static func dsDestructive(size: DSButtonSize) -> DSDestructiveButtonStyle { .init(size: size) }
}

extension ButtonStyle where Self == DSIconChipButtonStyle {
    static var dsIconChip: DSIconChipButtonStyle { .init() }
}
