import UIKit

// MARK: - Haptic Tokens

enum Haptics {
    // Quiet confirmation for low-stakes taps (toggle, pin, navigate).
    static func tapConfirm() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    // Medium weight for commits that persist data (save, send, record).
    static func commit()     { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    // Warning pulse for destructive or irreversible actions.
    static func warn()       { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    // Success chime for completed async operations (compilation, upload).
    static func success()    { UINotificationFeedbackGenerator().notificationOccurred(.success) }

    // MARK: - 5-Level Composer Haptic Ladder

    /// Feather-light tap — dock keys, ambient touches.
    static func soft() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    /// Crisp rigid impact with variable intensity (0.0–1.0).
    /// Use intensity 0.3 for caret-first-appear; 1.0 for hard confirms.
    static func rigid(intensity: CGFloat = 1.0) {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: intensity)
    }

    /// Medium-weight impact — attach actions, confirm gestures.
    static func medium() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Light impact — remove / cancel actions.
    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Success notification — memo saved, operation completed.
    static func successNotification() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Warning notification — recording too short, error conditions.
    static func warningNotification() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}
