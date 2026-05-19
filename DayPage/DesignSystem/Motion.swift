import SwiftUI

// MARK: - Motion Tokens

enum Motion {
    // Quick opacity transitions (toasts, overlays).
    static let fade: Animation = .easeOut(duration: 0.18)
    // Elements entering from below (sheets, cards appearing).
    static let rise: Animation = .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.24)
    // Horizontal panel and drawer transitions.
    static let slide: Animation = .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.28)
    // Interactive controls with elastic settle (buttons, toggles).
    static let spring: Animation = .spring(response: 0.35, dampingFraction: 0.8)
    // Sheet / card dismiss — matches system dismiss feel.
    static let dismiss: Animation = .easeOut(duration: 0.22)
    // Breathing / pulsing ambient indicator (slow in-out).
    static let breathing: Animation = .easeInOut(duration: 1.8).repeatForever(autoreverses: true)
    // Back-swipe navigation gesture following deceleration.
    static let swipeBack: Animation = .timingCurve(0.4, 0.0, 0.2, 1, duration: 0.30)
}
