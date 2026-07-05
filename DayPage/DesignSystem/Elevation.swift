import SwiftUI

// MARK: - DSElevation
//
// Three elevation tiers that pair with the Liquid Glass surface family.
// Use these instead of inline `.shadow(...)` calls so the shadow stack
// stays consistent (warm-amber ink, low-opacity, two-layer for depth).
//
//   .flat      → no shadow (nested rows, chips inside a card)
//   .glass     → default Liquid Glass card shadow (matches v4 spec)
//   .floating  → sheets, drawers, modals — stronger drop
//
// Light scheme shares the warm ink color (#2D1E0A) used by GlassSurface.swift.
// Dark scheme switches to black at higher opacity (tokens.json dark.elevation):
// warm-brown shadows are invisible against dark charcoal canvases.

enum DSElevation {
    case flat
    case glass
    case floating
}

struct ElevationModifier: ViewModifier {
    let tier: DSElevation
    @Environment(\.colorScheme) private var colorScheme

    // Warm ink in light mode; pure black in dark mode.
    private var ink: Color {
        colorScheme == .dark
            ? .black
            : Color(.sRGB, red: 45/255, green: 30/255, blue: 10/255, opacity: 1.0)
    }

    // Dark canvases swallow low-opacity shadows — boost per dark.elevation.
    private func alpha(_ light: Double, _ dark: Double) -> Double {
        colorScheme == .dark ? dark : light
    }

    func body(content: Content) -> some View {
        switch tier {
        case .flat:
            content
        case .glass:
            // Matches LiquidGlassCard's existing two-layer ambient shadow.
            content
                .shadow(color: ink.opacity(alpha(0.04, 0.32)), radius: 1,  x: 0, y: 1)
                .shadow(color: ink.opacity(alpha(0.08, 0.42)), radius: 24, x: 0, y: 8)
        case .floating:
            // Stronger lift for sheets/drawers — used by Sidebar and Feedback panel.
            content
                .shadow(color: ink.opacity(alpha(0.06, 0.36)), radius: 2,  x: 0, y: 1)
                .shadow(color: ink.opacity(alpha(0.14, 0.55)), radius: 32, x: 0, y: 12)
        }
    }
}

extension View {
    /// Apply a DayPage elevation tier (flat / glass / floating).
    func elevation(_ tier: DSElevation) -> some View {
        modifier(ElevationModifier(tier: tier))
    }
}
