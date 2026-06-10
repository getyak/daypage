import SwiftUI
import UIKit

// MARK: - Motion Tokens
//
// Tokens are the canonical animation curves used across the app.
// To honor the system "Reduce Motion" accessibility setting, prefer
// `.dsAnimation(...)` on the call site (or use `Motion.respectReduceMotion(_:)`)
// rather than `withAnimation(Motion.spring)` directly — the helper
// downgrades to an instant `.linear(duration: 0.001)` when the user
// has Reduce Motion enabled in Settings → Accessibility.

enum Motion {
    // Quick opacity transitions (toasts, overlays).
    static let fade: Animation = .easeOut(duration: 0.18)
    // Elements entering from below (sheets, cards appearing).
    static let rise: Animation = .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.24)
    // Horizontal panel and drawer transitions.
    static let slide: Animation = .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.28)
    // Interactive controls with elastic settle (buttons, toggles).
    static let spring: Animation = .spring(response: 0.35, dampingFraction: 0.8)
    // High-frequency counters (word/char count) that update on EVERY keystroke.
    // A 0.35s spring here stacks and re-interrupts faster than the user types,
    // starving the main thread and making typing feel "sticky". This curve is
    // short enough that consecutive keystrokes never overlap their animations,
    // so the count nudges quietly without ever fighting the text input.
    static let countTick: Animation = .easeOut(duration: 0.12)
    // Sheet / card dismiss — matches system dismiss feel.
    static let dismiss: Animation = .easeOut(duration: 0.22)
    // Breathing / pulsing ambient indicator (slow in-out).
    static let breathing: Animation = .easeInOut(duration: 1.8).repeatForever(autoreverses: true)
    // Back-swipe navigation gesture following deceleration.
    static let swipeBack: Animation = .timingCurve(0.4, 0.0, 0.2, 1, duration: 0.30)

    // MARK: - Reduce-Motion Helpers

    /// Returns the given animation, or a near-instant equivalent when the
    /// user has enabled "Reduce Motion" in iOS Settings → Accessibility.
    static func respectReduceMotion(_ base: Animation) -> Animation {
        UIAccessibility.isReduceMotionEnabled
            ? .linear(duration: 0.001)
            : base
    }
}

extension View {
    /// Apply a DayPage animation that automatically respects the
    /// user's Reduce Motion accessibility setting. Use this in place of
    /// `.animation(Motion.xxx, value:)` for any motion that involves
    /// translation, scale, or parallax (i.e. could cause vestibular
    /// discomfort). Pure opacity fades may keep using the raw token.
    func dsAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
        self.animation(Motion.respectReduceMotion(animation), value: value)
    }
}
