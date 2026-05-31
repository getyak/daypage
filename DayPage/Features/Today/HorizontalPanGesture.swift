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

    /// A discrete tap that did NOT turn into a pan. Because the host view
    /// hit-tests to SELF (so the pan recognizer can see touches), a plain
    /// tap on the card would otherwise be swallowed before it reaches the
    /// SwiftUI content below. We therefore recognize the tap in UIKit too and
    /// route it back here, letting the parent drive programmatic navigation.
    /// nil means "no tap action" (e.g. the panel-close overlay).
    var onTap: (() -> Void)? = nil

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
        // Keep delivering touchesXXX to the view tree so any UIKit content
        // below still works; SwiftUI taps are handled by our own tap
        // recognizer (see below) since this host hit-tests to self.
        recognizer.cancelsTouchesInView = false
        view.addGestureRecognizer(recognizer)
        context.coordinator.recognizer = recognizer

        // Tap recognizer: fires only when the pan did not. It waits for the
        // pan to fail (requireToFail) so a swipe never also triggers a tap.
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.delegate = context.coordinator
        tap.require(toFail: recognizer)
        view.addGestureRecognizer(tap)
        context.coordinator.tapRecognizer = tap

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.recognizer?.isEnabled = isEnabled
        // The tap is live whenever an onTap exists, regardless of selection
        // mode — selection-mode taps still need to toggle membership, which
        // the parent wires through onTap.
        context.coordinator.tapRecognizer?.isEnabled = (self.onTap != nil)
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: HorizontalPanGesture
        weak var recognizer: UIPanGestureRecognizer?
        weak var tapRecognizer: UITapGestureRecognizer?

        // 6pt direction-lock: tightened from 10pt so UIKit's pan can enter
        // Began before SwiftUI's ambient DragGestures (sidebar edge swipe,
        // feedback-panel close) finish their own arbitration window. Still
        // safely below UIScrollView's vertical pan threshold, so a slow
        // vertical drag still hands ownership to the timeline scroll.
        private let directionLockDistance: CGFloat = 6
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

        // Discrete tap that survived `require(toFail: pan)` — i.e. the finger
        // lifted without a horizontal pan ever beginning. Routes to the
        // parent so SwiftUI can navigate / toggle selection programmatically.
        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            parent.onTap?()
        }

        // Let the tap coexist with the parent ScrollView's own recognizers so
        // a tap is never starved; it still defers to our pan via requireToFail.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
            false
        }
    }

    // Hosts the recognizer. CRITICAL CORRECTION: a UIView whose hitTest
    // returns nil for every point is invisible to the hit-test walk, so the
    // UIPanGestureRecognizer attached to it NEVER receives a touch — UIKit
    // only delivers a touch sequence to recognizers on the hit-tested view or
    // its ancestors. The previous `return nil` therefore silently disabled
    // swipe-to-reveal entirely (the old commit only verified `xcodebuild
    // build`, never the live gesture).
    //
    // The correct iOS-Mail pattern is: hitTest returns SELF so the recognizer
    // sees the touch, while `cancelsTouchesInView = false` (set on the
    // recognizer in makeUIView) lets the same touch ALSO reach the SwiftUI
    // content below for taps. The recognizer's `gestureRecognizerShouldBegin`
    // direction-lock keeps it Possible until a horizontal pan is confirmed, so
    // vertical scrolls and taps are unaffected; only a confirmed horizontal
    // drag claims the touch (UIScrollView's pan is then cancelled by standard
    // arbitration). This view must be mounted as an `.overlay` (above the
    // card) — not `.background` — so it is part of the hit-test walk for
    // touches that land on the card.
    private final class PassthroughView: UIView {}
}
