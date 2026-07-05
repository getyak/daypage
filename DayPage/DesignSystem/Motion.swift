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
    // Press feedback on buttons/chips — quick settle, no visible wobble.
    // Previously duplicated inline as spring(0.25, 0.8–0.85) across
    // DSButton / PressableCardModifier.
    static let press: Animation = .spring(response: 0.25, dampingFraction: 0.85)
    // Panel / card entrance that scales or rises into place (recording panel,
    // popovers, send-confirm settle). Slightly snappier than `spring`. Pair with
    // `.dsAnimation(Motion.panel, value:)` so translation/scale honors Reduce Motion.
    static let panel: Animation = .spring(response: 0.32, dampingFraction: 0.85)
    // Banner slide-in/out (AppBanner, error banners). Soft, well-damped settle
    // for a notification dropping into or out of view. Honors Reduce Motion via
    // `.dsAnimation`.
    static let bannerSlide: Animation = .spring(response: 0.55, dampingFraction: 0.88)
    // Disclosure expand / collapse (thread cards, list reorder). A well-damped
    // settle for content that grows or moves into place. Because the disclosure
    // shifts position (`.move` transition / list reorder), pair with
    // `.dsAnimation(Motion.expand, value:)` or `respectReduceMotion` so it
    // honors Reduce Motion. Previously duplicated inline as spring(0.3, 0.82).
    static let expand: Animation = .spring(response: 0.3, dampingFraction: 0.82)
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
    // Sustained ambient pulse (e.g. recording indicator). Slower than `spring`
    // so the ring breathes calmly without feeling jittery; meant to be paired
    // with `.repeatForever(autoreverses: true)` at the call site.
    static let sustain: Animation = .easeInOut(duration: 0.8)
    // Near-instant tick used for high-frequency visual updates such as the
    // live waveform bars — short enough that consecutive frames don't queue.
    static let instant: Animation = .easeOut(duration: 0.05)

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
