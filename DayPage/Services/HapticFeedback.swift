import UIKit

enum HapticFeedback {

    // MARK: - Impact

    static func light() {
        impact(.light)
    }

    static func medium() {
        impact(.medium)
    }

    static func heavy() {
        impact(.heavy)
    }

    static func soft() {
        impact(.soft)
    }

    static func rigid(intensity: CGFloat = 1.0) {
        let generator = UIImpactFeedbackGenerator(style: .rigid)
        generator.prepare()
        generator.impactOccurred(intensity: intensity)
    }

    static func impact(style: UIImpactFeedbackGenerator.FeedbackStyle) {
        impact(style)
    }

    // MARK: - Notification

    static func success() {
        notification(.success)
    }

    static func warning() {
        notification(.warning)
    }

    static func error() {
        notification(.error)
    }

    // MARK: - Private

    private static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }

    private static func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(type)
    }
}
