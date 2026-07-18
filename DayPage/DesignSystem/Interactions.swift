import SwiftUI
import UIKit

// MARK: - DSGesture

/// Shared horizontal-swipe tuning so every horizontal pager in the app
/// (Archive month grid, DayDetail day paging) engages with the same feel.
/// Values were tuned on-device for DayDetail during the premium-polish waves;
/// #827 unifies Archive's month swipe onto them.
enum DSGesture {
    /// Minimum travel before a horizontal pager drag is recognized at all.
    static let pagerMinimumDistance: CGFloat = 24
    /// Horizontal dominance gate: |width| > |height| × ratio keeps vertical
    /// scrolls owned by the enclosing scroll view.
    static let horizontalDominance: CGFloat = 1.5
    /// Fixed travel that commits a month-page change in the Archive grid.
    static let monthSwipeCommitDistance: CGFloat = 50
    /// Width of the left-screen-edge strip reserved for the system interactive
    /// pop (swipe-to-go-back). Any in-app horizontal pager (DayDetail day
    /// paging, Archive month paging) must NOT engage when a drag starts inside
    /// this strip, so the edge stays owned by back-navigation. Same 20pt the
    /// RootView sidebar edge strip uses, hoisted here as the single source so
    /// paging and drawer share one definition.
    static let systemEdgeBackZone: CGFloat = 20
}

// MARK: - PressableCardModifier

/// 对任何卡片视图应用按压缩放 + 暗色叠加及触觉反馈。
///
/// Fix (issue #150): 使用 `onLongPressGesture(onPressingChanged:)` 替代
/// `LongPressGesture`。`LongPressGesture` 是离散手势，`onEnded` 在识别时立即触发
///（约 50ms），导致 `isPressed` 最多保持一帧为 true，按压视觉反馈（缩放 + 叠加层）
/// 几乎不可见。`onPressingChanged` 在手指按下时回调 `true`、抬起或被高优先级手势
/// 取消时回调 `false`，行为正确且不干扰水平滑动手势。
struct PressableCardModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPressed: Bool = false

    func body(content: Content) -> some View {
        content
            .scaleEffect((!reduceMotion && isPressed) ? 0.98 : 1.0)
            .overlay(
                Color.black.opacity(isPressed ? 0.04 : 0)
                    .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
            )
            .animation(reduceMotion ? nil : Motion.press, value: isPressed)
            .onLongPressGesture(minimumDuration: 0.0, maximumDistance: .infinity) {
                // 轻触动作由 MemoCardView 内部的 .onTapGesture 处理
                // 此处不执行任何操作
            } onPressingChanged: { pressing in
                if pressing {
                    if !isPressed {
                        isPressed = true
                        HapticFeedback.light()
                    }
                } else {
                    // 手指抬起或被高优先级手势取消时释放按压状态
                    isPressed = false
                }
            }
    }
}

extension View {
    func pressableCard() -> some View {
        modifier(PressableCardModifier())
    }
}

// MARK: - PressScaleButtonStyle

/// Shared press-feedback `ButtonStyle` — a small scale dip (plus optional
/// opacity fade and vertical nudge) on press, animated by a spring. Replaces
/// the near-identical private styles that had accumulated across the Today
/// surface. Parameters default to the most common values (0.97 scale,
/// `Motion.press` spring); callers override `scale` / `opacity` / `offsetY` /
/// `animation` where their original style diverged.
///
/// `respectsReduceMotion` gates the scale/opacity/offset on the user's
/// Reduce Motion setting. It defaults to `true`; pass `false` to preserve
/// styles that historically never consulted the accessibility environment.
struct PressScaleButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    var opacity: CGFloat = 1.0
    var offsetY: CGFloat = 0
    var animation: Animation = Motion.press
    var respectsReduceMotion: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var suppressed: Bool { respectsReduceMotion && reduceMotion }

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .scaleEffect((!suppressed && pressed) ? scale : 1.0)
            .opacity(pressed ? opacity : 1.0)
            .offset(y: (!suppressed && pressed) ? offsetY : 0)
            .animation(suppressed ? nil : animation, value: configuration.isPressed)
    }
}

// MARK: - Accessibility Helpers

extension View {
    /// Guarantees a minimum 44×44pt hit target (Apple HIG / WCAG 2.5.5) without
    /// changing the view's visual size. Wraps the content in a transparent frame
    /// with a minimum width/height and makes the whole frame tappable via
    /// `contentShape`. Use on compact icon buttons whose glyph is < 44pt.
    ///
    /// - Parameter size: the minimum edge length (default 44).
    func minTapTarget(_ size: CGFloat = 44) -> some View {
        frame(minWidth: size, minHeight: size)
            .contentShape(Rectangle())
    }

    /// Marks a tappable view as a button for VoiceOver: adds the `.isButton`
    /// trait, a spoken label, and an optional hint. Use on custom
    /// `.onTapGesture` / gesture-driven controls that SwiftUI can't infer are
    /// buttons (native `Button` already carries the trait). Combines children so
    /// the element is announced as one control.
    ///
    /// - Parameters:
    ///   - label: the VoiceOver-spoken name of the control.
    ///   - hint: optional usage hint spoken after a pause.
    func a11yButton(label: Text, hint: Text? = nil) -> some View {
        accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(label)
            .accessibilityHint(hint ?? Text(""))
    }
}

extension View {
    /// Apply the shared ``PressScaleButtonStyle`` press feedback.
    func pressScale(
        scale: CGFloat = 0.97,
        opacity: CGFloat = 1.0,
        offsetY: CGFloat = 0,
        animation: Animation = Motion.press,
        respectsReduceMotion: Bool = true
    ) -> some View {
        buttonStyle(PressScaleButtonStyle(
            scale: scale,
            opacity: opacity,
            offsetY: offsetY,
            animation: animation,
            respectsReduceMotion: respectsReduceMotion
        ))
    }
}

// MARK: - Interactive Pop Restorer
//
// WHY: TodayView roots its NavigationStack with `.navigationBarHidden(true)`
// (a real crash-fix constraint — see TodayView's giant-generic-type note). On
// iOS, hiding the navigation bar makes UIKit repoint the stack's
// `interactivePopGestureRecognizer.delegate` to an internal object whose
// `gestureRecognizerShouldBegin` returns false while the bar is hidden — so the
// left-edge swipe-to-pop dies on EVERY page pushed onto that stack
// (MemoDetailView / DayDetailView). The user feels this as "edge-back works
// sometimes, not others": the exact reported symptom.
//
// FIX: swap in our own delegate that re-enables the gesture, but ONLY when the
// stack has something to pop (viewControllers.count > 1). Guarding on depth
// keeps the root page from arming a pop it can't service (which UIKit turns
// into a dead, unresponsive-feeling swipe), while restoring genuine edge-back
// on every child. This changes NO visual chrome — it purely re-arms the
// system gesture the hidden bar suppressed.
//
// Usage: attach `.restoresInteractivePop()` to any view PUSHED onto a
// bar-hidden NavigationStack (the detail pages), not to the stack root.

private struct InteractivePopRestorer: UIViewControllerRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> ProbeController {
        // The probe re-claims the pop delegate in `viewWillAppear`, not just on
        // `updateUIViewController`. WHY: in an A→B push (both restored), popping
        // B back to A releases B's coordinator, leaving the delegate nil; SwiftUI
        // does not reliably re-run A's `update`, so A's edge-back would silently
        // die on the second visit. `viewWillAppear` fires on every re-exposure,
        // so each page re-arms itself as it comes back to the top.
        let vc = ProbeController()
        vc.coordinator = context.coordinator
        vc.view.backgroundColor = .clear
        vc.view.isUserInteractionEnabled = false
        return vc
    }

    func updateUIViewController(_ uiViewController: ProbeController, context: Context) {
        uiViewController.coordinator = context.coordinator
        uiViewController.rearm()
    }

    /// Zero-size probe that lives in the responder chain purely to resolve
    /// `navigationController` and re-claim the pop gesture on every appearance.
    final class ProbeController: UIViewController {
        // STRONG (not weak): the pop gesture's `delegate` is a weak reference,
        // and the coordinator is otherwise only retained by SwiftUI's Context.
        // Holding it strongly here binds the coordinator's lifetime to this
        // probe (which SwiftUI retains for the view's lifetime), so the deferred
        // `rearm()` can never set `gesture.delegate` to an object about to
        // deallocate. No cycle: the coordinator does not retain the probe.
        var coordinator: Coordinator?

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            rearm()
        }

        func rearm() {
            // Defer one hop: on the first pass the view may not yet be in the
            // nav hierarchy, so `navigationController` is nil.
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let coordinator = self.coordinator,
                      let nc = self.navigationController,
                      let gesture = nc.interactivePopGestureRecognizer
                else { return }
                coordinator.stackProvider = { [weak nc] in nc?.viewControllers.count ?? 0 }
                gesture.isEnabled = true
                gesture.delegate = coordinator
            }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// Reads the live stack depth so the edge-pop only arms when there is a
        /// parent to return to — never on the stack root.
        var stackProvider: (() -> Int)?

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            (stackProvider?() ?? 0) > 1
        }

        // Deliberately do NOT implement `shouldRecognizeSimultaneouslyWith`.
        // The default (false = mutually exclusive) is what we want: MemoDetail
        // also hosts a horizontal UIKit pan (DropToAskGesture). If the edge-pop
        // ran simultaneously, an edge drag meant as "go back" would also fire
        // "drag-to-ask". Keeping them exclusive lets UIKit's arbitration pick
        // one — the system pop wins at the screen edge (its recognizer is
        // edge-anchored), drag-to-ask wins from the card interior.
    }
}

extension View {
    /// Re-arms the system left-edge swipe-to-pop on a view pushed onto a
    /// NavigationStack whose root hid the navigation bar (which otherwise
    /// suppresses the interactive pop gesture). Attach to the DETAIL page, not
    /// the stack root. No visual effect — restores gesture behavior only.
    func restoresInteractivePop() -> some View {
        background(InteractivePopRestorer().frame(width: 0, height: 0).allowsHitTesting(false))
    }
}
