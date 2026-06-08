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
    var onTap: (() -> Void)? = nil
    /// Flip this bool to trigger a one-shot capture-reward glow pulse (scale 1.0→1.10→1.0).
    /// Only fires when a new memo is added; caller is responsible for only toggling on additions.
    var pulseToggle: Bool = false
    /// Fraction of the current day elapsed (0 at local midnight, 1.0 at next midnight).
    var dayProgress: CGFloat = 0
    /// Time-of-day accent color driving the halo and orb fill (dawn → midday → dusk → night).
    var timeTint: Color = DSColor.accentAmber

    @State private var breatheScale: CGFloat = 1.0
    @State private var pulse: Bool = false
    @State private var previous: Int = 0
    @State private var isPressed: Bool = false
    @State private var countPop: CGFloat = 1.0
    @State private var invitePulse: Bool = false
    @State private var capturePulse: Bool = false
    @State private var previousTier: Int = 0
    @State private var tierUpGlow: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func tier(for count: Int) -> Int {
        switch count {
        case 0:     return 0
        case 1:     return 1
        case 2...4: return 2
        case 5...9: return 3
        default:    return 4
        }
    }

    private var accessibilityLabelText: String {
        let pct = Int(dayProgress * 100)
        let dayPart = "\(pct)% of the day elapsed"
        if signalCount == 0 { return "Day orb, no signals yet, \(dayPart)" }
        let word = signalCount == 1 ? "signal" : "signals"
        let status = readoutLabel.lowercased()
        return "Day orb, \(signalCount) \(word) today, \(status), \(dayPart)"
    }

    var body: some View {
        ZStack {
            if signalCount == 0 { inviteHalo }
            halo
            if pulse { pulseHalo }
            if tierUpGlow { tierUpHalo }
            orb
            dayProgressArc
        }
        .frame(width: size + 32, height: size + 32)
        .scaleEffect(isPressed ? breatheScale * 0.94 : breatheScale)
        .scaleEffect(capturePulse ? 1.10 : 1.0)
        .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.55), value: capturePulse)
        .onChange(of: pulseToggle) { _ in
            guard !reduceMotion else { return }
            Task { @MainActor in
                capturePulse = true
                try? await Task.sleep(nanoseconds: 250_000_000)
                capturePulse = false
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPressed {
                        Haptics.soft()
                        withAnimation(.spring(response: 0.2, dampingFraction: 0.6)) {
                            isPressed = true
                        }
                    }
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) {
                        isPressed = false
                    }
                    onTap?()
                }
        )
        .onChange(of: signalCount) { new in
            let newTier = tier(for: new)
            if new > previous {
                Haptics.success()
                pulse = true
                if !reduceMotion {
                    withAnimation(.spring(response: 0.18, dampingFraction: 0.5)) {
                        countPop = 1.25
                    }
                }
                Task { @MainActor in
                    if !reduceMotion {
                        try? await Task.sleep(nanoseconds: 180_000_000)
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                            countPop = 1.0
                        }
                    }
                    try? await Task.sleep(nanoseconds: 650_000_000)
                    pulse = false
                }

                if newTier > previousTier && newTier >= 2 {
                    Haptics.medium()
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 80_000_000)
                        Haptics.success()
                    }
                    if !reduceMotion {
                        tierUpGlow = true
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 700_000_000)
                            tierUpGlow = false
                        }
                    }
                }
            }
            if new > 0 { invitePulse = false }
            previous = new
            previousTier = newTier
        }
        // Drop shadow: two-layer stack matching the glass card recipe
        .shadow(color: Color(hex: "2D1E0A").opacity(0.08), radius: 4, x: 0, y: 2)
        .shadow(color: Color(hex: "2D1E0A").opacity(0.14), radius: 28, x: 0, y: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityHint("Activates to start writing today's note")
        .accessibilityAction { onTap?() }
        .onAppear {
            withAnimation(
                .easeInOut(duration: 4).repeatForever(autoreverses: true)
            ) {
                // Amplitude ×0.7 relative to the original ±0.05 range → ±0.035
                breatheScale = 1.035
            }
            guard signalCount == 0, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                invitePulse = true
            }
        }
    }

    // MARK: - Day Progress Arc

    // Thin arc around the orb outer edge filling from 0 (midnight) to 1.0 (next midnight).
    // Stroke tracks timeTint so the arc always harmonizes with the halo and orb fill.
    // A small glowing dot sits at the arc's leading edge for at-a-glance time remaining.
    private var dayProgressArc: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: dayProgress)
                .stroke(
                    timeTint.opacity(0.65),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: size + 6, height: size + 6)
                .animation(reduceMotion ? nil : .linear(duration: 1), value: dayProgress)
                .allowsHitTesting(false)

            if dayProgress > 0.01 {
                Circle()
                    .fill(timeTint)
                    .frame(width: 5, height: 5)
                    .shadow(color: timeTint.opacity(0.8), radius: 3, x: 0, y: 0)
                    .offset(y: -(size + 6) / 2)
                    .rotationEffect(.degrees(360 * dayProgress - 90))
                    .animation(reduceMotion ? nil : .linear(duration: 1), value: dayProgress)
                    .allowsHitTesting(false)
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

    // MARK: - Tier-Up Halo

    // Brighter, larger one-shot ring fired only on tier boundary crossings.
    // Scaled up relative to pulseHalo: +24pt endRadius, 0.7 peak opacity, 1.28× scale.
    private var tierUpHalo: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        Color(red: 232/255, green: 151/255, blue: 77/255).opacity(tierUpGlow ? 0.7 : 0),
                        Color.clear
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: (size / 2) + 40
                )
            )
            .frame(width: size + 80, height: size + 80)
            .blur(radius: 14)
            .scaleEffect(tierUpGlow ? 1.28 : 1.0)
            .opacity(tierUpGlow ? 1 : 0)
            .animation(.easeOut(duration: 0.7), value: tierUpGlow)
            .allowsHitTesting(false)
    }

    // MARK: - Invite Halo

    // Looping amber glow-pulse shown only when signalCount == 0 to signal tappability.
    // Uses the restrained amberAccent (#A8541B) rather than the hot peach (#E8974D)
    // so the halo reads as warm light bleeding through paper, not a glowing blob. (#590)
    private var inviteHalo: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        timeTint.opacity(invitePulse ? 0.18 : 0.08),
                        Color.clear
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: (size / 2) + 16
                )
            )
            .frame(width: size + 32, height: size + 32)
            .blur(radius: 16)
            .scaleEffect(invitePulse ? 1.12 : 0.95)
            .animation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true), value: invitePulse)
            .allowsHitTesting(false)
    }

    // MARK: - Halo

    // Blurred radial gradient that bleeds +16pt past the orb edge on every side.
    // amberAccent (#A8541B) for a warmer, less saturated bleed than the old peach. (#590)
    private var halo: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        timeTint.opacity(haloOpacity),
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
                        .init(color: timeTint.opacity(0.1), location: 0.8),
                        .init(color: timeTint.opacity(0.025), location: 1)
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

    private var readoutLabel: String {
        switch signalCount {
        case 0:        return NSLocalizedString("orb.readout.tapToBegin", comment: "")
        case 1:        return NSLocalizedString("orb.readout.signalToday", comment: "")
        case 2...4:    return NSLocalizedString("orb.readout.building", comment: "")
        case 5...9:    return NSLocalizedString("orb.readout.richDay", comment: "")
        default:       return NSLocalizedString("orb.readout.packed", comment: "")
        }
    }

    private var orbContent: some View {
        Group {
            if signalCount == 0 {
                VStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: size * 0.22, weight: .light))
                        .foregroundColor(DSColor.amberDeep)
                        .scaleEffect(invitePulse ? 1.12 : 1.0)
                        .opacity(invitePulse ? 1.0 : 0.7)
                        .animation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true), value: invitePulse)

                    Text(readoutLabel)
                        .font(DSFonts.jetBrainsMono(size: 9, weight: .medium))
                        .tracking(1.4)
                        .foregroundColor(DSColor.amberDeep)
                        .opacity(0.7)
                }
            } else {
                VStack(spacing: 2) {
                    Text("\(signalCount)")
                        .font(DSFonts.spaceGrotesk(size: size * 0.36, weight: .semibold))
                        .tracking(-2)
                        .foregroundColor(DSColor.amberDeep)
                        .modifier(OrbNumericTextTransition(value: Double(signalCount), reduceMotion: reduceMotion))
                        .animation(.snappy, value: signalCount)
                        .scaleEffect(countPop)

                    Text(readoutLabel)
                        .font(DSFonts.jetBrainsMono(size: 9, weight: .medium))
                        .tracking(1.4)
                        .foregroundColor(DSColor.amberDeep)
                        .opacity(tierUpGlow ? 1.0 : 0.7)
                        .scaleEffect(tierUpGlow ? 1.12 : 1.0)
                        .shadow(color: DSColor.accentAmber.opacity(tierUpGlow ? 0.9 : 0), radius: tierUpGlow ? 6 : 0)
                        .animation(.easeOut(duration: 0.35), value: tierUpGlow)
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.25), value: readoutLabel)
                }
            }
        }
    }
}

// MARK: - OrbNumericTextTransition

private struct OrbNumericTextTransition: ViewModifier {
    let value: Double
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content
                .contentTransition(reduceMotion ? .identity : .numericText(value: value))
        } else {
            content
                .contentTransition(.identity)
        }
    }
}

// MARK: - Preview

#Preview("Day Orb — 0 signals (invite state)") {
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
