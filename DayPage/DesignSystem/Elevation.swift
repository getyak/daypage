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
// All tiers share the same warm ink color (#2D1E0A) used by GlassSurface.swift.

enum DSElevation {
    case flat
    case glass
    case floating

    // Warm ink — matches the #2D1E0A used by GlassSurface.swift shadows.
    fileprivate var inkColor: Color {
        Color(.sRGB, red: 45/255, green: 30/255, blue: 10/255, opacity: 1.0)
    }
}

struct ElevationModifier: ViewModifier {
    let tier: DSElevation

    func body(content: Content) -> some View {
        switch tier {
        case .flat:
            content
        case .glass:
            // Matches LiquidGlassCard's existing two-layer ambient shadow.
            content
                .shadow(color: tier.inkColor.opacity(0.04), radius: 1,  x: 0, y: 1)
                .shadow(color: tier.inkColor.opacity(0.08), radius: 24, x: 0, y: 8)
        case .floating:
            // Stronger lift for sheets/drawers — used by Sidebar and Feedback panel.
            content
                .shadow(color: tier.inkColor.opacity(0.06), radius: 2,  x: 0, y: 1)
                .shadow(color: tier.inkColor.opacity(0.14), radius: 32, x: 0, y: 12)
        }
    }
}

extension View {
    /// Apply a DayPage elevation tier (flat / glass / floating).
    func elevation(_ tier: DSElevation) -> some View {
        modifier(ElevationModifier(tier: tier))
    }
}
