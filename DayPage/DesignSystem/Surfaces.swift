import SwiftUI

// MARK: - GlassTone

/// Opacity tier for every Liquid Glass surface.
/// Maps to DSColor.glassStd / glassHi / glassLo from the v4 palette.
enum GlassTone {
    case std       // 62 % — default body cards
    case hi        // 85 % — sheets, pills, panel menus
    case lo        // 35 % — nested rows, secondary chips
    case amberHero // Deep-amber hero (Daily Page card, non-glass)

    var fill: Color {
        switch self {
        case .std:       return DSColor.glassStd
        case .hi:        return DSColor.glassHi
        case .lo:        return DSColor.glassLo
        case .amberHero: return Color(hex: "5D3000").opacity(0.92)
        }
    }

    var rim: Color {
        switch self {
        case .std, .lo:  return DSColor.glassRim
        case .hi:        return DSColor.glassRimD
        case .amberHero: return DSColor.amberRim
        }
    }
}

// MARK: - LiquidGlassCard

/// Translucent warm-amber pane — the core v4 card surface.
/// Layers: warm tint → ultraThinMaterial (blur 28, saturate 160 %)
/// → top inner highlight → 0.5 pt hairline → soft drop-shadow stack.
struct LiquidGlassCard: ViewModifier {
    var cornerRadius: CGFloat = DSRadius.lg
    var tone: GlassTone = .std

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        Group {
            if case .amberHero = tone {
                // Deep-amber hero is an opaque, non-glass surface (Daily Page
                // card). Keep the original solid recipe — routing it through
                // the glass engine would wash out its intentional density.
                content
                    .background(shape.fill(tone.fill))
            } else {
                // std / hi / lo glass tones route through the dual-track engine
                // (#771): iOS 26 → native Liquid Glass tinted with the tone's
                // own fill (preserving the std/hi/lo brightness hierarchy);
                // iOS 16–25 → warm faux-glass. The wet-glass highlight and the
                // per-tone hairline below are kept as the bespoke outer shell.
                content
                    .dpGlass(.panel, in: shape, tint: tone.fill)
            }
        }
        .overlay(
            // Top inner highlight — gives the "wet glass" rim.
            shape.strokeBorder(
                LinearGradient(
                    colors: [DSColor.glassEdge, Color.clear],
                    startPoint: .top,
                    endPoint: .center
                ),
                lineWidth: 0.6
            )
        )
        .overlay(
            // 0.5 pt hairline around the full perimeter (per-tone).
            shape.strokeBorder(tone.rim, lineWidth: 0.5)
        )
        .clipShape(shape)
        .shadow(color: Color(hex: "2D1E0A").opacity(0.04), radius: 1, x: 0, y: 1)
        .shadow(color: Color(hex: "2D1E0A").opacity(0.08), radius: 24, x: 0, y: 8)
    }
}

// MARK: - SolidCard

/// Museum-aesthetic content-first card: a plain opaque white surface with a
/// 0.5 pt hairline and a whisper of shadow. Replaces Liquid Glass on memo
/// cards so the content (text + photo) reads cleanly against the warm canvas.
/// Matches the design token: surface-white #FFF, radius 14, hairline border.
struct SolidCard: ViewModifier {
    var cornerRadius: CGFloat = DSRadius.md

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(DSColor.surfaceWhite)
            )
            .overlay(
                // Adaptive hairline — the static borderSubtle beige reads as a
                // glowing outline against the dark-scheme charcoal canvas.
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(DSColor.inkFaint, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: Color(hex: "2D1E0A").opacity(0.04), radius: 1, x: 0, y: 1)
    }
}

// MARK: - LiquidGlassPill

/// Fully-rounded pill surface (cornerRadius 999, tone .hi).
/// Use for action chips, tags, and badge-style controls.
struct LiquidGlassPill: ViewModifier {
    func body(content: Content) -> some View {
        content
            .modifier(LiquidGlassCard(cornerRadius: DSRadius.pill, tone: .hi))
    }
}

// MARK: - LiquidGlassPanel

/// Panel surface used for expanded TabBar menus and drawers (tone .hi).
struct LiquidGlassPanel: ViewModifier {
    var cornerRadius: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .modifier(LiquidGlassCard(cornerRadius: cornerRadius, tone: .hi))
    }
}

// MARK: - View extensions

extension View {
    /// iOS 26-style Liquid Glass card — the default card surface.
    func liquidGlassCard(cornerRadius: CGFloat = DSRadius.lg, tone: GlassTone = .std) -> some View {
        modifier(LiquidGlassCard(cornerRadius: cornerRadius, tone: tone))
    }

    /// Fully-rounded Liquid Glass pill (cornerRadius 999, tone .hi).
    func liquidGlassPill() -> some View {
        modifier(LiquidGlassPill())
    }

    /// Expanded-menu panel surface (tone .hi).
    func liquidGlassPanel(cornerRadius: CGFloat = 20) -> some View {
        modifier(LiquidGlassPanel(cornerRadius: cornerRadius))
    }

    /// Museum-aesthetic content-first white card (surface-white + hairline).
    func solidCard(cornerRadius: CGFloat = DSRadius.md) -> some View {
        modifier(SolidCard(cornerRadius: cornerRadius))
    }
}
