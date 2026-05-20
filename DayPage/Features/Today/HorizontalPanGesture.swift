import SwiftUI
import UIKit

// MARK: - HorizontalPanGesture
//
// SwiftUI's DragGesture cannot express "stay pending until direction is
// confirmed, then claim ownership; otherwise let the parent ScrollView win."
// .simultaneousGesture activates on the first touch event, and inside its
// .updating closure we can only mute our own delta — we cannot relinquish
// gesture ownership back to UIScrollView. That's why a finger that lands on
// SwipeableMemoCard and drags vertically can freeze the timeline: SwiftUI's
// arbitration never picks UIScrollView as the winner.
//
// UIKit's UIPanGestureRecognizer + UIGestureRecognizerDelegate solves this
// natively. We override gestureRecognizerShouldBegin to return true ONLY
// after the touch's translation passes a horizontal-dominance test. Until
// then, UIScrollView's pan owns the touch and the timeline scrolls normally.
// This mirrors iOS Mail / Reminders / Things 3 swipe-to-reveal behavior.

struct HorizontalPanGesture: UIViewRepresentable {

    /// True while a confirmed horizontal pan is in progress. Use this to
    /// disable adjacent SwiftUI taps (NavigationLink) so finger-up after a
    /// swipe never routes into the detail screen.
    let isActive: Binding<Bool>

    /// Live horizontal translation while the pan is recognized.
    let onChanged: (CGFloat) -> Void

    /// Final translation + horizontal velocity (pt/s) when the user lifts.
    /// Velocity is reported separately because UIKit's predictedEndLocation
    /// has no SwiftUI equivalent, and snap-decision needs real velocity.
    let onEnded: (_ translation: CGFloat, _ velocity: CGFloat) -> Void

    /// Cancellation (system interruption, simultaneous winner). Treat as
    /// "abort and snap back to the previous resting position."
    let onCancelled: () -> Void

    /// Hard-disable the recognizer (e.g. selection mode). When false the
    /// underlying recognizer reports isEnabled = false so it never even
    /// evaluates a touch.
    let isEnabled: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UIView {
        let view = PassthroughView()
        let recognizer = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        recognizer.delegate = context.coordinator
        recognizer.maximumNumberOfTouches = 1
        recognizer.cancelsTouchesInView = false
        view.addGestureRecognizer(recognizer)
        context.coordinator.recognizer = recognizer
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.recognizer?.isEnabled = isEnabled
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: HorizontalPanGesture
        weak var recognizer: UIPanGestureRecognizer?

        // 10pt direction-lock matches Apple's internal swipe recognizers.
        // Below this we stay Possible so UIScrollView keeps ownership.
        private let directionLockDistance: CGFloat = 10
        // |dx| must dominate |dy| by 1.2× — slightly more permissive than
        // Mail (1.5×) because our cards are wider and a shallow horizontal
        // flick should still register.
        private let horizontalDominance: CGFloat = 1.2

        init(parent: HorizontalPanGesture) {
            self.parent = parent
        }

        // Critical: this gate gives UIScrollView its scroll back. UIKit
        // calls this when the pan is about to transition from Possible to
        // Began. Returning false keeps it Possible — UIScrollView's pan,
        // which has no such gate, wins arbitration and the timeline scrolls.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let view = pan.view else { return false }
            let translation = pan.translation(in: view)
            let dx = abs(translation.x)
            let dy = abs(translation.y)
            return dx >= directionLockDistance && dx > dy * horizontalDominance
        }

        // Coexist with UIScrollView's pan. Until our shouldBegin returns
        // true the scroll view is the sole active recognizer; once we
        // begin, UIKit's standard arbitration cancels the scroll's pan.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let translation = recognizer.translation(in: view).x
            let velocity = recognizer.velocity(in: view).x

            switch recognizer.state {
            case .began:
                parent.isActive.wrappedValue = true
                parent.onChanged(translation)
            case .changed:
                parent.onChanged(translation)
            case .ended:
                parent.isActive.wrappedValue = false
                parent.onEnded(translation, velocity)
            case .cancelled, .failed:
                parent.isActive.wrappedValue = false
                parent.onCancelled()
            default:
                break
            }
        }
    }

    // Hosts the recognizer without interfering with SwiftUI hit-testing.
    // hitTest returns nil so taps fall through to SwiftUI siblings, but
    // gesture recognizers attached here still see touches via UIWindow.
    private final class PassthroughView: UIView {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            nil
        }
    }
}
