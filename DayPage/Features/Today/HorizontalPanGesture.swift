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
// natively, via two cooperating rules (see Coordinator):
//
//  1. `shouldBeRequiredToFailBy` makes every other pan — the ScrollView's
//     scroll pan in particular — WAIT until our pan resolves. Without it the
//     scroller begins on any movement direction and cancels content touches,
//     so our recognizer never even got its shouldBegin query.
//  2. `gestureRecognizerShouldBegin` then judges direction ONCE, on velocity
//     (fully formed at the first query, unlike accumulated translation):
//     vertical-dominant → we fail instantly and the timeline scrolls;
//     horizontal-dominant → we begin and own the touch.
//
// This mirrors iOS Mail / Reminders / Things 3 swipe-to-reveal behavior.

struct HorizontalPanGesture: UIViewRepresentable {

    /// Pure direction verdict behind the Coordinator's shouldBegin gate,
    /// extracted so the contract is unit-testable without touch synthesis.
    /// |vx| must dominate |vy| by `dominance` (1.2× — slightly more
    /// permissive than Mail's 1.5× because our cards are wider and a
    /// shallow horizontal flick should still register).
    static func isHorizontalDominant(
        vx: CGFloat, vy: CGFloat, dominance: CGFloat = 1.2
    ) -> Bool {
        abs(vx) > abs(vy) * dominance
    }

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

    /// Touch-down / touch-up press state, for the card's press-scale
    /// feedback (UITableViewCell-highlight semantics). Driven by a zero-
    /// distance long press that recognizes simultaneously with everything
    /// and claims nothing: `true` shortly after the finger lands, `false`
    /// on lift or the instant a scroll / swipe / context-menu interaction
    /// takes the touch away. nil skips installing the extra recognizer.
    var onPressChanged: ((Bool) -> Void)? = nil

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
        // TimedTap (not plain UITapGestureRecognizer): a stock tap has NO
        // duration ceiling, so a long-press whose context-menu interaction
        // failed to begin still fired onTap at lift — long-press navigated
        // to detail exactly like a tap (#826). TimedTap fails itself once
        // the finger dwells past maxTapDuration, so a long hold can never
        // fall through to navigation.
        let tap = TimedTapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.delegate = context.coordinator
        tap.require(toFail: recognizer)
        view.addGestureRecognizer(tap)
        context.coordinator.tapRecognizer = tap

        // Press-state recognizer: a zero-ish-delay long press that merely
        // REPORTS touch-down/up so SwiftUI can render the pressed scale.
        // It recognizes simultaneously with everything (see the delegate's
        // simultaneous rule), never cancels touches, and ends/cancels the
        // moment the scroll, our pan, or the context-menu lift claims the
        // touch — so the card un-presses exactly when it loses the finger.
        if onPressChanged != nil {
            let press = UILongPressGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.handlePress(_:))
            )
            press.minimumPressDuration = 0.06
            press.allowableMovement = .greatestFiniteMagnitude
            press.cancelsTouchesInView = false
            press.delegate = context.coordinator
            view.addGestureRecognizer(press)
            context.coordinator.pressRecognizer = press
        }

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.recognizer?.isEnabled = isEnabled
        // The tap is live whenever an onTap exists, regardless of selection
        // mode — selection-mode taps still need to toggle membership, which
        // the parent wires through onTap.
        context.coordinator.tapRecognizer?.isEnabled = (self.onTap != nil)
        context.coordinator.pressRecognizer?.isEnabled = (self.onPressChanged != nil)
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: HorizontalPanGesture
        weak var recognizer: UIPanGestureRecognizer?
        weak var tapRecognizer: UITapGestureRecognizer?
        weak var pressRecognizer: UILongPressGestureRecognizer?

        init(parent: HorizontalPanGesture) {
            self.parent = parent
        }

        // Direction lock. UIKit queries shouldBegin exactly ONCE per touch —
        // at the pan's own internal hysteresis, where accumulated translation
        // can still be tiny (observed 1.3pt live) — and a `false` verdict
        // transitions the recognizer to .failed for the REST of the touch;
        // it is never re-asked. The old translation gate (`dx >= 6pt`)
        // therefore vetoed nearly every real swipe on its single query and
        // the drawer never opened. Velocity is already fully formed at that
        // first query (SwipeCellKit and UIKit's own table-cell swipe use the
        // same velocity test), so one velocity comparison is enough to judge
        // direction reliably at any drag speed.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            // This delegate serves BOTH recognizers on the host. The
            // direction-lock below must gate ONLY the pan — the guard's
            // failed cast used to return false for the tap recognizer,
            // which silently vetoed every card tap (detail navigation
            // never fired). Non-pan recognizers may always begin; the
            // tap still defers to the pan via require(toFail:).
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let view = pan.view else { return true }
            let v = pan.velocity(in: view)
            return HorizontalPanGesture.isHorizontalDominant(vx: v.x, vy: v.y)
        }

        // Coexist with UIScrollView's pan. Until our shouldBegin returns
        // true the scroll view is the sole active recognizer; once we
        // begin, UIKit's standard arbitration cancels the scroll's pan.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        // CRITICAL (iOS 26): make every OTHER pan — most importantly the
        // ancestor ScrollView's scroll pan — wait for OUR pan to resolve
        // first. Without this failure requirement the scroll pan begins on
        // ANY direction of movement (SwiftUI's scroller is not direction-
        // locked) and cancels content touches, so our recognizer's
        // shouldBegin was never even queried — swipe-to-reveal was dead no
        // matter what the direction-lock returned. With the requirement in
        // place the arbitration becomes: vertical drag → our velocity gate
        // fails the pan in one query → scroll proceeds (imperceptible
        // delay); horizontal drag → our pan begins and the scroll pan stays
        // blocked for the rest of the touch.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer is UIPanGestureRecognizer else { return false }
            return other is UIPanGestureRecognizer && other !== gestureRecognizer
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

        // Press-state reporter (see makeUIView). Pure observation — it
        // triggers no action of its own, so every terminal state just
        // clears the pressed flag.
        @objc func handlePress(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began:
                parent.onPressChanged?(true)
            case .ended, .cancelled, .failed:
                parent.onPressChanged?(false)
            default:
                break
            }
        }

        // Let the tap coexist with the parent ScrollView's own recognizers so
        // a tap is never starved; it still defers to our pan via requireToFail.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
            false
        }
    }

    // MARK: TimedTapGestureRecognizer

    /// A tap with a duration ceiling. UITapGestureRecognizer recognizes on
    /// lift no matter how long the finger dwelled, so any long-press that
    /// the system context-menu interaction misses degrades into a plain tap
    /// (#826: "long-press behaved exactly like tap"). This subclass moves
    /// itself to .failed once the touch outlives `maxTapDuration`, before
    /// the lift can be interpreted.
    ///
    /// 0.4s sits between the double-tap window and the ~0.5s context-menu
    /// long-press threshold: every intentional tap lands well under it,
    /// and every intentional long-press is disqualified by it. The
    /// remaining ~0.4–0.5s band where a release does nothing is the
    /// DELIBERATE safety margin — collapsing it (ceiling ≥ menu threshold)
    /// would re-open the original bug whenever the menu interaction fails
    /// to begin.
    final class TimedTapGestureRecognizer: UITapGestureRecognizer {
        var maxTapDuration: TimeInterval = 0.4
        private var failTimer: Timer?

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesBegan(touches, with: event)
            scheduleFailTimer()
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            cancelFailTimer()
            super.touchesEnded(touches, with: event)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            cancelFailTimer()
            super.touchesCancelled(touches, with: event)
        }

        override func reset() {
            cancelFailTimer()
            super.reset()
        }

        private func scheduleFailTimer() {
            failTimer?.invalidate()
            let timer = Timer(timeInterval: maxTapDuration, repeats: false) { [weak self] _ in
                guard let self, self.state == .possible else { return }
                self.state = .failed
            }
            // .common, not .default: while a finger is down the main runloop
            // sits in UITrackingRunLoopMode, where default-mode timers are
            // deferred until lift — the ceiling would never fire mid-press.
            RunLoop.main.add(timer, forMode: .common)
            failTimer = timer
        }

        private func cancelFailTimer() {
            failTimer?.invalidate()
            failTimer = nil
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
