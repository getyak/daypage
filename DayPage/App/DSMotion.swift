import SwiftUI

// MARK: - DS Animation constants

extension Animation {
    /// Spring animation matching --motion-spring token (response ~0.32s, damping 0.78).
    static var dsSpring: Animation {
        .spring(response: 0.32, dampingFraction: 0.78)
    }

    /// Standard ease-out for most transitions (~280ms).
    static var dsEaseOut: Animation {
        .easeOut(duration: DSTokens.Motion.medium)
    }

    /// Sheet / drawer presentation animation.
    static var dsSheet: Animation {
        .spring(response: 0.36, dampingFraction: 0.82)
    }
}

// MARK: - Reduce-motion helpers

extension Animation {
    /// Returns `.linear(duration: 0.01)` when the user has enabled Reduce Motion,
    /// otherwise returns `self`.
    func reducedIfNeeded(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: 0.01) : self
    }
}

/// View modifier that picks an animation respecting `accessibilityReduceMotion`.
struct DSAnimated: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation

    func body(content: Content) -> some View {
        content.animation(animation.reducedIfNeeded(reduceMotion), value: reduceMotion)
    }
}

extension View {
    /// Applies a DS animation constant, degrading to near-instant linear when
    /// the user has enabled Reduce Motion.
    func dsAnimated(_ animation: Animation = .dsSpring) -> some View {
        modifier(DSAnimated(animation: animation))
    }
}
