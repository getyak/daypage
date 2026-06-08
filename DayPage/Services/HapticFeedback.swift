import UIKit

@MainActor
enum HapticFeedback {

    // MARK: - Cached Generators

    private static var impactGenerators: [UIImpactFeedbackGenerator.FeedbackStyle: UIImpactFeedbackGenerator] = [:]
    private static var notificationGenerator = UINotificationFeedbackGenerator()
    private static var warmedUp = false

    // MARK: - Warm-up

    /// Pre-warms the Taptic Engine so the first haptic fires without latency.
    /// Call once at launch and again on scenePhase → .active.
    static func warmUp() {
        let styles: [UIImpactFeedbackGenerator.FeedbackStyle] = [.soft, .light, .medium, .rigid]
        for style in styles {
            generator(for: style).prepare()
        }
        notificationGenerator.prepare()
    }

    // MARK: - Impact

    static func light() {
        fire(style: .light)
    }

    static func medium() {
        fire(style: .medium)
    }

    static func heavy() {
        fire(style: .heavy)
    }

    static func soft() {
        fire(style: .soft)
    }

    static func rigid(intensity: CGFloat = 1.0) {
        let gen = generator(for: .rigid)
        gen.impactOccurred(intensity: intensity)
        gen.prepare()
    }

    static func impact(style: UIImpactFeedbackGenerator.FeedbackStyle) {
        fire(style: style)
    }

    // MARK: - Notification

    static func success() {
        notificationGenerator.notificationOccurred(.success)
        notificationGenerator.prepare()
    }

    static func warning() {
        notificationGenerator.notificationOccurred(.warning)
        notificationGenerator.prepare()
    }

    static func error() {
        notificationGenerator.notificationOccurred(.error)
        notificationGenerator.prepare()
    }

    // MARK: - Private

    private static func generator(for style: UIImpactFeedbackGenerator.FeedbackStyle) -> UIImpactFeedbackGenerator {
        if let existing = impactGenerators[style] {
            return existing
        }
        let gen = UIImpactFeedbackGenerator(style: style)
        impactGenerators[style] = gen
        return gen
    }

    private static func fire(style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let gen = generator(for: style)
        gen.impactOccurred()
        gen.prepare()
    }
}
