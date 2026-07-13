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

    /// Perceived thickness of the faux-glass material (iOS 16–25 track).
    ///
    /// Native Liquid Glass (iOS 26) modulates blur radius by surface size for
    /// free; the legacy path can't animate a numeric blur, but SwiftUI's system
    /// materials form a discrete thickness scale we can map roles onto so a chip
    /// no longer reads exactly as thick as a full-screen sheet. Larger surfaces
    /// (panels/sheets) get a denser material; transient chips/toasts stay light.
    var fallbackMaterial: Material {
        switch self {
        case .panel:            return .thinMaterial      // sheets, drawers, body cards — denser
        case .control:          return .thinMaterial      // dock/floating controls — mid
        case .pill, .toast:     return .ultraThinMaterial // chips, tags, hints — lightest (unchanged)
        }
    }
}

extension View {
    /// Dual-track Liquid Glass background.
    ///
    /// - iOS 26+ → native `.glassEffect()`, warm-tinted; `.control` is interactive.
    /// - iOS 16–25 → existing faux-glass (warm fill + ultraThinMaterial + rim).
    /// - Reduce Transparency (either path) → opaque warm fill so text stays legible.
    ///
    /// - Parameter tint: optional surface tint that overrides the default
    ///   `amberSoft` (native) / `role.fallbackTone.fill` (legacy). Pass a
    ///   semantic colour (e.g. `DSColor.errorSoft`) when a surface must keep
    ///   its own meaning — error / warning / success banners — while still
    ///   routing through the glass engine. `nil` keeps the warm-cream default.
    @ViewBuilder
    func dpGlass<S: Shape & InsettableShape>(
        _ role: GlassRole,
        in shape: S,
        tint: Color? = nil
    ) -> some View {
        if #available(iOS 26.0, *) {
            modifier(NativeGlassModifier(role: role, shape: shape, tint: tint))
        } else {
            modifier(LegacyGlassModifier(role: role, shape: shape, tint: tint))
        }
    }
}

// MARK: - Native (iOS 26)

@available(iOS 26.0, *)
private struct NativeGlassModifier<S: Shape & InsettableShape>: ViewModifier {
    let role: GlassRole
    let shape: S
    var tint: Color?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Native glass tint — semantic override or the warm-amber brand default.
    private var glassTint: Color { tint ?? DSColor.amberSoft }
    /// Reduce-Transparency opaque fill — semantic override or warm fallback tone.
    private var opaqueFill: Color { (tint ?? role.fallbackTone.fill).opacity(0.96) }

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(opaqueFill, in: shape)
                .overlay(shape.strokeBorder(role.fallbackTone.rim, lineWidth: 0.5))
        } else {
            switch role {
            case .control:
                content.glassEffect(
                    .regular.tint(glassTint).interactive(),
                    in: shape
                )
            case .panel, .pill, .toast:
                content.glassEffect(
                    .regular.tint(glassTint),
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
    var tint: Color?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Faux-glass base fill — semantic override or the role's warm tone.
    private var baseFill: Color { tint ?? role.fallbackTone.fill }

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(baseFill.opacity(0.96), in: shape)
                .overlay(shape.strokeBorder(role.fallbackTone.rim, lineWidth: 0.5))
        } else {
            content
                .background(baseFill)
                .background(role.fallbackMaterial, in: shape)
                .overlay(shape.strokeBorder(role.fallbackTone.rim, lineWidth: 0.5))
        }
    }
}
