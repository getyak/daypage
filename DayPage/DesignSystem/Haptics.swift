import UIKit

// MARK: - Haptic Tokens

@MainActor
enum Haptics {
    // Quiet confirmation for low-stakes taps (toggle, pin, navigate).
    static func tapConfirm() { HapticFeedback.light() }
    // Medium weight for commits that persist data (save, send, record).
    static func commit()     { HapticFeedback.medium() }
    // Warning pulse for destructive or irreversible actions.
    static func warn()       { HapticFeedback.warning() }
    // Success chime for completed async operations (compilation, upload).
    static func success()    { HapticFeedback.success() }
    // Selection tick for moving between discrete options (tabs, segmented
    // controls, calendar cells) — the system scrubbing feel, not an impact.
    static func selection()  { HapticFeedback.selection() }

    // MARK: - 5-Level Composer Haptic Ladder

    /// Feather-light tap — dock keys, ambient touches.
    static func soft() {
        HapticFeedback.soft()
    }

    /// Crisp rigid impact with variable intensity (0.0–1.0).
    /// Use intensity 0.3 for caret-first-appear; 1.0 for hard confirms.
    static func rigid(intensity: CGFloat = 1.0) {
        HapticFeedback.rigid(intensity: intensity)
    }

    /// Medium-weight impact — attach actions, confirm gestures.
    static func medium() {
        HapticFeedback.medium()
    }

    /// Light impact — remove / cancel actions.
    static func light() {
        HapticFeedback.light()
    }

    /// Success notification — memo saved, operation completed.
    static func successNotification() {
        HapticFeedback.success()
    }

    /// Warning notification — recording too short, error conditions.
    static func warningNotification() {
        HapticFeedback.warning()
    }
}
