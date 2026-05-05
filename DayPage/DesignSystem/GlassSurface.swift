import SwiftUI

// MARK: - Liquid Glass Card Modifier
//
// V4 design language — iOS 26 Liquid Glass. Apply to any container that
// should read as a translucent warm-amber pane floating above the page.
// Layers: warm tint → ultraThinMaterial → top-edge highlight → hairline rim
// → soft drop shadow stack.

enum GlassTone {
    case standard   // Default body cards
    case elevated   // Sheets, hero cards, Daily Page
    case recessed   // Nested rows, secondary chips
    case amberHero  // Deep amber Daily Page card

    var fill: Color {
        switch self {
        case .standard:  return DSColor.glassStd
        case .elevated:  return DSColor.glassHi
        case .recessed:  return DSColor.glassLo
        case .amberHero: return Color(hex: "5D3000").opacity(0.92)
        }
    }

    var rim: Color {
        switch self {
        case .standard, .recessed: return DSColor.glassRim
        case .elevated:            return DSColor.glassRimD
        case .amberHero:           return DSColor.amberRim
        }
    }
}

struct LiquidGlassCard: ViewModifier {
    var cornerRadius: CGFloat = 18
    var tone: GlassTone = .standard

    func body(content: Content) -> some View {
        content
            .background(tone.fill)
            .background(.ultraThinMaterial)
            .overlay(
                // Top-edge wet highlight — gives the surface its glass "rim".
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [DSColor.glassEdge, Color.clear],
                            startPoint: .top,
                            endPoint: .center
                        ),
                        lineWidth: 0.6
                    )
            )
            .overlay(
                // Hairline ink rim around the entire perimeter.
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(tone.rim, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: Color(hex: "2D1E0A").opacity(0.04), radius: 1, x: 0, y: 1)
            .shadow(color: Color(hex: "2D1E0A").opacity(0.08), radius: 24, x: 0, y: 8)
    }
}

extension View {
    /// Apply iOS 26-style Liquid Glass card surface.
    func liquidGlassCard(cornerRadius: CGFloat = 18, tone: GlassTone = .standard) -> some View {
        modifier(LiquidGlassCard(cornerRadius: cornerRadius, tone: tone))
    }
}

// MARK: - Ambient Background
//
// Four blurred amber light blobs over a warm cream page. Creates the
// "refraction" canvas that makes glass surfaces visibly translucent. Use
// as the bottom layer of every full-screen view.

struct AmbientBackground: View {
    var body: some View {
        ZStack {
            DSColor.bgWarm.ignoresSafeArea()

            // Top-left peach highlight
            Circle()
                .fill(Color(hex: "E8974D").opacity(0.55))
                .frame(width: 360, height: 360)
                .blur(radius: 80)
                .offset(x: -60, y: -100)

            // Top-right warm yellow
            Circle()
                .fill(Color(hex: "FFCE8C").opacity(0.55))
                .frame(width: 320, height: 320)
                .blur(radius: 80)
                .offset(x: 140, y: -50)

            // Center-left deep amber
            Circle()
                .fill(Color(hex: "A8541B").opacity(0.32))
                .frame(width: 420, height: 420)
                .blur(radius: 80)
                .offset(x: -20, y: 200)

            // Bottom-right warm rust
            Circle()
                .fill(Color(hex: "D98D54").opacity(0.40))
                .frame(width: 300, height: 300)
                .blur(radius: 80)
                .offset(x: 100, y: 300)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Glass Disc (small button surface)
//
// A 44pt translucent coin used for the input dock side buttons and any
// other circular floating control. Same recipe as `LiquidGlassCard` but
// shaped as a circle.

struct GlassDisc: ViewModifier {
    var size: CGFloat = 44

    func body(content: Content) -> some View {
        content
            .frame(width: size, height: size)
            .background(DSColor.glassStd)
            .background(.ultraThinMaterial, in: Circle())
            .overlay(
                Circle()
                    .strokeBorder(DSColor.glassEdge, lineWidth: 0.6)
            )
            .overlay(
                Circle()
                    .strokeBorder(DSColor.glassRim, lineWidth: 0.5)
            )
            .clipShape(Circle())
            .shadow(color: Color(hex: "2D1E0A").opacity(0.05), radius: 1, x: 0, y: 1)
            .shadow(color: Color(hex: "2D1E0A").opacity(0.10), radius: 14, x: 0, y: 6)
    }
}

extension View {
    func glassDisc(size: CGFloat = 44) -> some View {
        modifier(GlassDisc(size: size))
    }
}

// MARK: - Amber Glow Halo
//
// Decorative warm halo placed behind a hero element (e.g. Daily Page
// card, Day Orb in the sidebar). Adds the characteristic Liquid Glass
// internal-light look without darkening the underlying surface.

struct AmberHalo: View {
    var size: CGFloat = 200
    var intensity: Double = 0.55

    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        Color(hex: "E8974D").opacity(intensity),
                        Color(hex: "A8541B").opacity(intensity * 0.6),
                        Color.clear
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: size / 2
                )
            )
            .frame(width: size, height: size)
            .blur(radius: 24)
            .allowsHitTesting(false)
    }
}
