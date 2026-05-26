import SwiftUI

// MARK: - DayOrbView
//
// Signature "Day Orb" — a radial-gradient sphere with amber halo, inner
// shadow, and a signal count readout. Place it in the Today header or
// sidebar as a visual anchor for today's memo density.

struct DayOrbView: View {
    let signalCount: Int
    var size: CGFloat = 140
    var haloOpacity: CGFloat = 0.15

    @State private var breatheScale: CGFloat = 1.0
    @State private var pulse: Bool = false
    @State private var previous: Int = 0

    var body: some View {
        ZStack {
            halo
            if pulse { pulseHalo }
            orb
        }
        .frame(width: size + 32, height: size + 32)
        .scaleEffect(breatheScale)
        .onChange(of: signalCount) { new in
            if new > previous {
                pulse = true
                withAnimation(.easeOut(duration: 0.6)) { }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 650_000_000)
                    pulse = false
                }
            }
            previous = new
        }
        // Drop shadow: two-layer stack matching the glass card recipe
        .shadow(color: Color(hex: "2D1E0A").opacity(0.08), radius: 4, x: 0, y: 2)
        .shadow(color: Color(hex: "2D1E0A").opacity(0.14), radius: 28, x: 0, y: 12)
        .onAppear {
            withAnimation(
                .easeInOut(duration: 4).repeatForever(autoreverses: true)
            ) {
                // Amplitude ×0.7 relative to the original ±0.05 range → ±0.035
                breatheScale = 1.035
            }
        }
    }

    // MARK: - Pulse Halo

    // One-shot amber ring that expands and fades when signalCount increments.
    private var pulseHalo: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        Color(red: 232/255, green: 151/255, blue: 77/255).opacity(pulse ? 0.55 : 0),
                        Color.clear
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: (size / 2) + 16
                )
            )
            .frame(width: size + 32, height: size + 32)
            .blur(radius: 12)
            .scaleEffect(pulse ? 1.18 : 1.0)
            .opacity(pulse ? 1 : 0)
            .animation(.easeOut(duration: 0.6), value: pulse)
            .allowsHitTesting(false)
    }

    // MARK: - Halo

    // Blurred radial gradient that bleeds +16pt past the orb edge on every side.
    private var halo: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        Color(red: 232/255, green: 151/255, blue: 77/255).opacity(haloOpacity),
                        Color.clear
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: (size / 2) + 16
                )
            )
            .frame(width: size + 32, height: size + 32)
            .blur(radius: 16)
            .allowsHitTesting(false)
    }

    // MARK: - Orb

    private var orb: some View {
        ZStack {
            orbFill
            innerShadowLayer
            orbBorder
            orbContent
        }
        .frame(width: size, height: size)
    }

    // Radial gradient fill — all stop opacities ×0.5 vs original spec for a lighter orb.
    private var orbFill: some View {
        Circle()
            .fill(
                RadialGradient(
                    stops: [
                        .init(color: Color.white.opacity(0.425), location: 0),
                        .init(color: Color(red: 255/255, green: 206/255, blue: 140/255).opacity(0.2), location: 0.4),
                        .init(color: Color(red: 168/255, green: 84/255, blue: 27/255).opacity(0.1), location: 0.8),
                        .init(color: Color(red: 168/255, green: 84/255, blue: 27/255).opacity(0.025), location: 1)
                    ],
                    center: UnitPoint(x: 0.35, y: 0.30),
                    startRadius: 0,
                    endRadius: size * 0.5
                )
            )
    }

    // Simulated inner shadows using a semi-transparent overlay with offset
    // to mimic the bottom-right inner shadow from capture.jsx:393-395.
    private var innerShadowLayer: some View {
        ZStack {
            // Top-left inner highlight (light from upper-left per gradient center)
            Circle()
                .fill(Color.white.opacity(0.18))
                .blur(radius: size * 0.08)
                .offset(x: -size * 0.15, y: -size * 0.15)
                .blendMode(.overlay)

            // Bottom-right inner shadow (depth/concavity cue)
            Circle()
                .fill(Color(hex: "5D3000").opacity(0.12))
                .blur(radius: size * 0.12)
                .offset(x: size * 0.12, y: size * 0.12)
                .blendMode(.multiply)
        }
        .clipShape(Circle())
    }

    // 0.5pt white-60% inner border per spec
    private var orbBorder: some View {
        Circle()
            .strokeBorder(Color.white.opacity(0.60), lineWidth: 0.5)
    }

    // MARK: - Content

    private var orbContent: some View {
        VStack(spacing: 2) {
            Text("\(signalCount)")
                .font(DSFonts.spaceGrotesk(size: size * 0.36, weight: .semibold))
                .tracking(-2)
                .foregroundColor(DSColor.amberDeep)
                .contentTransition(.numericText())
                .animation(.snappy, value: signalCount)

            Text("SIGNALS TODAY")
                .font(DSFonts.jetBrainsMono(size: 9, weight: .medium))
                .tracking(1.4)
                .foregroundColor(DSColor.amberDeep)
                .opacity(0.7)
        }
    }
}

// MARK: - Preview

#Preview("Day Orb — 0 signals") {
    ZStack {
        AmbientBackground()
        DayOrbView(signalCount: 0)
    }
}

#Preview("Day Orb — 12 signals") {
    ZStack {
        AmbientBackground()
        DayOrbView(signalCount: 12)
    }
}

#Preview("Day Orb — small (120pt)") {
    ZStack {
        AmbientBackground()
        DayOrbView(signalCount: 5, size: 120)
    }
}
