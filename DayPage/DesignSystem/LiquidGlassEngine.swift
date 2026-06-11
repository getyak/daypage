import SwiftUI

// MARK: - Liquid Glass Engine (dual-track)
//
// Single dispatch point that routes every glass surface to either the
// iOS 26 native Liquid Glass API (`.glassEffect`) or — on iOS 16–25 — the
// hand-built warm "faux glass" recipe already shipped in Surfaces.swift /
// GlassSurface.swift.
//
// Callers never branch on OS version themselves: they just say
// `.dpGlass(.control, in: Capsule())` and the right implementation is
// selected at runtime. This keeps the 19 existing call sites stable while
// letting the *material* upgrade underneath them.
//
// Warm-amber brand: native Liquid Glass is neutral by default, so every
// native surface is tinted with DSColor.amberSoft to preserve the
// "Japanese-museum cream" language.

/// Semantic role of a glass surface — picks the native variant and the
/// faux-glass tone used as the iOS 16–25 fallback.
enum GlassRole {
    case control   // dock buttons, floating controls → interactive
    case panel     // sheets, drawers, menus
    case pill      // chips, tags, badges
    case toast     // transient hints

    /// Faux-glass tone for the legacy fallback path.
    var fallbackTone: GlassTone {
        switch self {
        case .control, .toast, .panel, .pill: return .hi
        }
    }
}

extension View {
    /// Dual-track Liquid Glass background.
    ///
    /// - iOS 26+ → native `.glassEffect()`, warm-tinted; `.control` is interactive.
    /// - iOS 16–25 → existing faux-glass (warm fill + ultraThinMaterial + rim).
    /// - Reduce Transparency (either path) → opaque warm fill so text stays legible.
    @ViewBuilder
    func dpGlass<S: Shape & InsettableShape>(
        _ role: GlassRole,
        in shape: S
    ) -> some View {
        if #available(iOS 26.0, *) {
            modifier(NativeGlassModifier(role: role, shape: shape))
        } else {
            modifier(LegacyGlassModifier(role: role, shape: shape))
        }
    }
}

// MARK: - Native (iOS 26)

@available(iOS 26.0, *)
private struct NativeGlassModifier<S: Shape & InsettableShape>: ViewModifier {
    let role: GlassRole
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(role.fallbackTone.fill.opacity(0.96), in: shape)
                .overlay(shape.strokeBorder(role.fallbackTone.rim, lineWidth: 0.5))
        } else {
            switch role {
            case .control:
                content.glassEffect(
                    .regular.tint(DSColor.amberSoft).interactive(),
                    in: shape
                )
            case .panel, .pill, .toast:
                content.glassEffect(
                    .regular.tint(DSColor.amberSoft),
                    in: shape
                )
            }
        }
    }
}

// MARK: - Legacy fallback (iOS 16–25)

/// Re-uses the warm faux-glass recipe from GlassSurfaceModifier so the
/// pre-26 experience is byte-for-byte the current shipped look.
private struct LegacyGlassModifier<S: Shape & InsettableShape>: ViewModifier {
    let role: GlassRole
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(role.fallbackTone.fill.opacity(0.96), in: shape)
                .overlay(shape.strokeBorder(role.fallbackTone.rim, lineWidth: 0.5))
        } else {
            content
                .background(role.fallbackTone.fill)
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(role.fallbackTone.rim, lineWidth: 0.5))
        }
    }
}
