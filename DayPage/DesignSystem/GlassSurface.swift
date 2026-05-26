import SwiftUI

// MARK: - Ambient Background
//
// Warm cream base (DSColor.bgWarm / #FAF7F2) with four slow-drifting amber
// blobs that breathe beneath glass surfaces. Honors Reduce Motion by keeping
// blobs at their base offsets (no animation). Drift cycle: ~16s, autoreverses.

struct AmbientBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = false

    var body: some View {
        ZStack {
            DSColor.bgWarm.ignoresSafeArea()

            // Top-left peach highlight — drifts down-right
            Circle()
                .fill(Color(hex: "E8974D").opacity(0.55))
                .frame(width: 360, height: 360)
                .blur(radius: 80)
                .offset(x: drift ? -42 : -60, y: drift ? -72 : -100)

            // Top-right warm yellow — drifts left-down
            Circle()
                .fill(Color(hex: "FFCE8C").opacity(0.55))
                .frame(width: 320, height: 320)
                .blur(radius: 80)
                .offset(x: drift ? 118 : 140, y: drift ? -28 : -50)

            // Center-left deep amber — drifts right-up
            Circle()
                .fill(Color(hex: "A8541B").opacity(0.32))
                .frame(width: 420, height: 420)
                .blur(radius: 80)
                .offset(x: drift ? 4 : -20, y: drift ? 222 : 200)

            // Bottom-right warm rust — drifts left-up
            Circle()
                .fill(Color(hex: "D98D54").opacity(0.40))
                .frame(width: 300, height: 300)
                .blur(radius: 80)
                .offset(x: drift ? 76 : 100, y: drift ? 324 : 300)
        }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 16).repeatForever(autoreverses: true),
            value: drift
        )
        .allowsHitTesting(false)
        .onAppear { drift = true }
    }
}

// MARK: - Glass Disc (small button surface)
//
// A 44pt translucent coin used for the input dock side buttons and any
// other circular floating control. Same recipe as LiquidGlassCard but
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
