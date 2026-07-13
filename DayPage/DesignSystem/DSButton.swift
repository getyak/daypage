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

/// Container shape for a DS button. The app's real CTAs are a mix of
/// full-width rounded rects (Onboarding) and content-hugging pills
/// (Welcome "开始 · Begin") — the shape is a knob so a single style can
/// express both without callers hand-rolling the surface.
enum DSButtonShape {
    /// Rounded rectangle at `DSRadius.md` (default, screen-level CTAs).
    case roundedRect
    /// Fully-rounded capsule pill (hero / inline pill CTAs).
    case capsule
}

/// How the button sizes horizontally.
enum DSButtonLayout {
    /// Stretch to `maxWidth: .infinity` (default — full-width CTA).
    case expand
    /// Hug the label width (pill buttons, inline actions).
    case hug
}

// Shared surface geometry so every concrete style resolves shape/layout the
// same way (and callers can override the label font to avoid a size change
// when migrating an existing button).
private struct DSButtonSurface {
    let size: DSButtonSize
    let shape: DSButtonShape
    let layout: DSButtonLayout
    let font: Font?

    @ViewBuilder
    func clipShape<V: View>(_ view: V) -> some View {
        switch shape {
        case .roundedRect:
            view.clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
        case .capsule:
            view.clipShape(Capsule())
        }
    }

    @ViewBuilder
    func background(_ fill: Color) -> some View {
        switch shape {
        case .roundedRect:
            RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous).fill(fill)
        case .capsule:
            Capsule().fill(fill)
        }
    }

    var resolvedFont: Font { font ?? size.font }
    var maxWidth: CGFloat? { layout == .expand ? .infinity : nil }
}

// MARK: - Primary (solid amber)

struct DSPrimaryButtonStyle: ButtonStyle {
    var size: DSButtonSize = .medium
    var shape: DSButtonShape = .roundedRect
    var layout: DSButtonLayout = .expand
    var font: Font? = nil
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let surface = DSButtonSurface(size: size, shape: shape, layout: layout, font: font)
        return configuration.label
            .font(surface.resolvedFont)
            .foregroundColor(isEnabled ? Color.white : Color.white.opacity(0.55))
            .frame(maxWidth: surface.maxWidth)
            .frame(height: size.height)
            .padding(.horizontal, size.horizontalPadding)
            .background(surface.background(isEnabled ? DSColor.amberDeep : DSColor.inkSubtle))
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(Motion.respectReduceMotion(Motion.press),
                       value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

// MARK: - Secondary (glass outlined)

struct DSSecondaryButtonStyle: ButtonStyle {
    var size: DSButtonSize = .medium
    var shape: DSButtonShape = .roundedRect
    var layout: DSButtonLayout = .expand
    var font: Font? = nil
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let surface = DSButtonSurface(size: size, shape: shape, layout: layout, font: font)
        // Secondary button surface routed through the dual-track engine
        // (#771): iOS 26 → interactive native glass; iOS 16–25 → warm
        // faux-glass. The engine supplies the hairline rim. `.pill` role when
        // the shape is a capsule keeps the faux-glass material thickness right.
        let base = configuration.label
            .font(surface.resolvedFont)
            .foregroundColor(isEnabled ? DSColor.inkPrimary : DSColor.inkSubtle)
            .frame(maxWidth: surface.maxWidth)
            .frame(height: size.height)
            .padding(.horizontal, size.horizontalPadding)
        return Group {
            switch shape {
            case .roundedRect:
                base.dpGlass(.control, in: RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
            case .capsule:
                base.dpGlass(.control, in: Capsule())
                    .clipShape(Capsule())
            }
        }
        .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
        .animation(Motion.respectReduceMotion(Motion.press),
                   value: configuration.isPressed)
        .contentShape(Rectangle())
    }
}

// MARK: - Ghost (text-only, minimal)

struct DSGhostButtonStyle: ButtonStyle {
    var size: DSButtonSize = .medium
    var layout: DSButtonLayout = .hug
    var font: Font? = nil
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let surface = DSButtonSurface(size: size, shape: .roundedRect, layout: layout, font: font)
        return configuration.label
            .font(surface.resolvedFont)
            .foregroundColor(isEnabled
                ? (configuration.isPressed ? DSColor.accentOnBg : DSColor.inkMuted)
                : DSColor.inkSubtle)
            .frame(maxWidth: surface.maxWidth)
            .frame(minHeight: 44)
            .padding(.horizontal, size.horizontalPadding)
            .contentShape(Rectangle())
    }
}

// MARK: - Destructive

struct DSDestructiveButtonStyle: ButtonStyle {
    var size: DSButtonSize = .medium
    var shape: DSButtonShape = .roundedRect
    var layout: DSButtonLayout = .expand
    var font: Font? = nil
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let surface = DSButtonSurface(size: size, shape: shape, layout: layout, font: font)
        return configuration.label
            .font(surface.resolvedFont)
            .foregroundColor(isEnabled ? Color.white : Color.white.opacity(0.55))
            .frame(maxWidth: surface.maxWidth)
            .frame(height: size.height)
            .padding(.horizontal, size.horizontalPadding)
            .background(surface.background(isEnabled ? DSColor.errorRed : DSColor.inkSubtle))
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(Motion.respectReduceMotion(Motion.press),
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
            .animation(Motion.respectReduceMotion(Motion.press),
                       value: configuration.isPressed)
    }
}

// MARK: - ButtonStyle sugar

extension ButtonStyle where Self == DSPrimaryButtonStyle {
    static var dsPrimary: DSPrimaryButtonStyle { .init() }
    static func dsPrimary(
        size: DSButtonSize = .medium,
        shape: DSButtonShape = .roundedRect,
        layout: DSButtonLayout = .expand,
        font: Font? = nil
    ) -> DSPrimaryButtonStyle { .init(size: size, shape: shape, layout: layout, font: font) }
}

extension ButtonStyle where Self == DSSecondaryButtonStyle {
    static var dsSecondary: DSSecondaryButtonStyle { .init() }
    static func dsSecondary(
        size: DSButtonSize = .medium,
        shape: DSButtonShape = .roundedRect,
        layout: DSButtonLayout = .expand,
        font: Font? = nil
    ) -> DSSecondaryButtonStyle { .init(size: size, shape: shape, layout: layout, font: font) }
}

extension ButtonStyle where Self == DSGhostButtonStyle {
    static var dsGhost: DSGhostButtonStyle { .init() }
    static func dsGhost(
        size: DSButtonSize = .medium,
        layout: DSButtonLayout = .hug,
        font: Font? = nil
    ) -> DSGhostButtonStyle { .init(size: size, layout: layout, font: font) }
}

extension ButtonStyle where Self == DSDestructiveButtonStyle {
    static var dsDestructive: DSDestructiveButtonStyle { .init() }
    static func dsDestructive(
        size: DSButtonSize = .medium,
        shape: DSButtonShape = .roundedRect,
        layout: DSButtonLayout = .expand,
        font: Font? = nil
    ) -> DSDestructiveButtonStyle { .init(size: size, shape: shape, layout: layout, font: font) }
}

extension ButtonStyle where Self == DSIconChipButtonStyle {
    static var dsIconChip: DSIconChipButtonStyle { .init() }
}
