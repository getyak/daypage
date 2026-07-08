import SwiftUI

// MARK: - Ambient Background
//
// Default: pure cream base (DSColor.bgWarm / #FAF7F2) — clean paper feel.
// Amber blobs are available for debug inspection via UserDefaults key
// "debug.ambientBlobs" (default false).

struct AmbientBackground: View {
    @AppStorage("debug.ambientBlobs") private var showBlobs: Bool = false

    var body: some View {
        ZStack {
            DSColor.bgWarm.ignoresSafeArea()

            if showBlobs {
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
        }
        .allowsHitTesting(false)
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
            // Core glass sandwich routed through the dual-track engine (#771):
            // iOS 26 → interactive native glass; iOS 16–25 → warm faux-glass.
            // The engine supplies its own hairline rim, so the bespoke
            // glassEdge/glassRim double-stroke is dropped to avoid doubling up.
            .dpGlass(.control, in: Circle())
            .clipShape(Circle())
            .elevation(.glass)
    }
}

extension View {
    func glassDisc(size: CGFloat = 44) -> some View {
        modifier(GlassDisc(size: size))
    }
}
