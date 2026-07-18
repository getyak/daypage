import SwiftUI
import UIKit

// MARK: - Drop-to-Ask（issue #837）
//
// 小红书式「拖回变卡片 → 投入对话坞」交互：
//
//  1. 横向起手（复用 HorizontalPanGesture.isHorizontalDominant 的速度方向锁，
//     纵向滚动零损）后，整页跟手凝缩成圆角卡片；
//  2. 底部升起「对话坞」；卡片拖入坞判定区时坞点亮 + soft haptic；
//  3. 释放：入坞 → onAsk（呈现 memo 锚定对话）；坞外且右移超过屏宽 40%
//     → onCommitBack（等效返回，保留慢拖返回语义）；否则 spring 弹回。
//
// 手势宿主：不能用覆盖全页的 UIViewRepresentable overlay —— 那会吞掉
// SwiftUI 按钮点击（HorizontalPanGesture 的 onTap 回路就是为此存在的，
// 但详情页可点元素太多，逐个回路不现实）。这里改为把 recognizer 挂到
// **祖先容器 view** 上：recognizer 对后代 touch 全收，而 SwiftUI 自身的
// 点击/滚动在方向锁失败（纵向/静止）时完全不受影响。

// MARK: - DropPanAttacher

/// 零尺寸标记 view：挂载后向上爬 superview 链找到页面级容器，把
/// UIPanGestureRecognizer 装上去。翻译值（2D）与状态经闭包回给 SwiftUI。
private struct DropPanAttacher: UIViewRepresentable {

    let isEnabled: Bool
    let onBegan: () -> Void
    /// (translation, fingerLocation) —— translation 驱动凝缩进度与
    /// commit-back 判定；location 驱动卡片位置（XHS 手感：卡心贴手指）。
    let onChanged: (CGPoint, CGPoint) -> Void
    let onEnded: (CGPoint, CGPoint) -> Void   // translation, fingerLocation
    let onCancelled: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UIView {
        let marker = AttachMarkerView()
        marker.isUserInteractionEnabled = false
        marker.backgroundColor = .clear
        // makeUIView 时 superview/window 尚未建立，一次性的 async 也可能
        // 抢跑（首次验证时 pan 从未挂上、拖拽被 ScrollView 整个吃掉）。
        // didMoveToWindow 是唯一可靠的挂载时机。
        let coordinator = context.coordinator
        marker.onWindow = { [weak marker] in
            guard let marker else { return }
            DispatchQueue.main.async {
                coordinator.attachIfNeeded(from: marker)
            }
        }
        return marker
    }

    /// 进窗即回调的标记 view——挂载时机的唯一可靠信号源。
    final class AttachMarkerView: UIView {
        var onWindow: (() -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { onWindow?() }
        }
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.recognizer?.isEnabled = isEnabled
        DispatchQueue.main.async {
            context.coordinator.attachIfNeeded(from: uiView)
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: DropPanAttacher
        weak var recognizer: UIPanGestureRecognizer?
        private weak var host: UIView?

        init(parent: DropPanAttacher) { self.parent = parent }

        /// 从标记 view 向上找「页面级」容器（宽度接近屏宽的首个祖先），
        /// 把 pan 装上去。幂等——已挂载则跳过。
        func attachIfNeeded(from marker: UIView) {
            guard recognizer == nil, marker.window != nil else { return }
            let screenWidth = marker.window?.bounds.width ?? UIScreen.main.bounds.width
            var candidate: UIView? = marker.superview
            var pageHost: UIView?
            var topmost: UIView?
            while let view = candidate {
                if pageHost == nil, view.bounds.width >= screenWidth * 0.9 {
                    pageHost = view
                    break
                }
                topmost = view
                candidate = view.superview
            }
            // 兜底：找不到页面级宽度的祖先时挂最顶层，宁可范围偏大
            // 也不要静默失效（方向锁保证误伤为零）。
            guard let target = pageHost ?? topmost else { return }

            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.delegate = self
            pan.maximumNumberOfTouches = 1
            // 确认横向后即拥有 touch；SwiftUI 按压随之取消，避免拖完误触。
            pan.cancelsTouchesInView = true
            pan.isEnabled = parent.isEnabled
            target.addGestureRecognizer(pan)
            recognizer = pan
            host = target
        }

        func detach() {
            if let pan = recognizer, let host { host.removeGestureRecognizer(pan) }
            recognizer = nil
            host = nil
        }

        // 与 HorizontalPanGesture 同款方向锁：UIKit 只在 pan 自身滞回点
        // 问一次 shouldBegin，速度在那一刻已经成形——一次速度比较即可。
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let view = pan.view else { return true }
            let v = pan.velocity(in: view)
            return HorizontalPanGesture.isHorizontalDominant(vx: v.x, vy: v.y)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // Do NOT run simultaneously with the system interactive-pop
            // (a screen-edge pan). Since W0 re-arms edge-back on MemoDetail, a
            // left-edge swipe would otherwise fire BOTH pop and drag-to-ask
            // (UIKit recognizes simultaneously if EITHER delegate returns true).
            // Yield the edge to back-navigation; keep simultaneity with
            // everything else (scroll, etc.).
            if other is UIScreenEdgePanGestureRecognizer { return false }
            return true
        }

        // Wait for the system edge-pop to fail before we begin: an edge-anchored
        // swipe is a back gesture, not a drag-to-ask. Combined with the
        // non-simultaneity above, the edge belongs to pop and the interior
        // belongs to drag-to-ask.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            if other is UIScreenEdgePanGestureRecognizer { return false }
            guard gestureRecognizer is UIPanGestureRecognizer else { return false }
            return other is UIPanGestureRecognizer && other !== gestureRecognizer
        }

        // The inverse: our pan should wait for the screen-edge pop to fail, so a
        // true edge swipe pops instead of arming drag-to-ask.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
            other is UIScreenEdgePanGestureRecognizer
        }

        @objc func handlePan(_ pan: UIPanGestureRecognizer) {
            guard let view = pan.view else { return }
            let t = pan.translation(in: view)
            let loc = pan.location(in: view)
            switch pan.state {
            case .began:
                parent.onBegan()
                parent.onChanged(t, loc)
            case .changed:
                parent.onChanged(t, loc)
            case .ended:
                parent.onEnded(t, loc)
            case .cancelled, .failed:
                parent.onCancelled()
            default:
                break
            }
        }
    }
}

// MARK: - DropToAskModifier

/// 应用到详情页 ScrollView：驱动「凝缩成卡 + 对话坞」的全部视觉与判定。
struct DropToAskModifier: ViewModifier {

    let isEnabled: Bool
    /// 卡片投入对话坞。
    let onAsk: () -> Void
    /// 坞外右移超过 commit 阈值——等效返回。
    let onCommitBack: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 累计位移——驱动凝缩进度与 commit-back 判定。
    @State private var translation: CGPoint = .zero
    /// 卡片视觉位移（卡心贴手指的偏移量）——XHS 手感的核心。
    @State private var cardOffset: CGSize = .zero
    @State private var isDragging = false
    @State private var isOverDock = false

    // MARK: Tuning

    /// 距离→进度的归一化半径：拖过这个距离即完全凝缩。
    private static let condenseRadius: CGFloat = 220
    /// 完全凝缩时的缩放。
    private static let minScale: CGFloat = 0.62
    /// 坞判定区高度（自底部算起）。
    private static let dockZoneHeight: CGFloat = 170
    /// 等效返回的右移距离占屏宽比例。
    private static let backCommitFraction: CGFloat = 0.4

    private var progress: CGFloat {
        let d = hypot(translation.x, translation.y)
        return min(1, d / Self.condenseRadius)
    }

    func body(content: Content) -> some View {
        GeometryReader { geo in
            ZStack {
                content
                    // 仅拖拽时铺不透明纸面：静止时必须让 AmbientBackground
                    // 渐变透上来（常驻 bgWarm 会把它盖成死平色）。
                    .background(isDragging ? DSColor.bgWarm : Color.clear)
                    .clipShape(RoundedRectangle(
                        cornerRadius: reduceMotion ? 0 : 28 * progress,
                        style: .continuous
                    ))
                    .shadow(
                        color: Color.black.opacity(reduceMotion ? 0 : 0.22 * progress),
                        radius: 24, x: 0, y: 10
                    )
                    .scaleEffect(reduceMotion ? 1 : 1 - (1 - Self.minScale) * progress)
                    .offset(reduceMotion ? .zero : cardOffset)
                    .opacity(reduceMotion && isDragging ? max(0.5, 1 - 0.5 * progress) : 1)

                // 对话坞：拖拽开始后自底部升起。
                if isDragging {
                    VStack {
                        Spacer()
                        AskDockView(isHighlighted: isOverDock)
                            .padding(.bottom, 28)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
                }
            }
            .background(
                DropPanAttacher(
                    isEnabled: isEnabled,
                    onBegan: {
                        Haptics.soft()
                        withAnimation(Motion.spring) { isDragging = true }
                    },
                    onChanged: { t, loc in
                        translation = t
                        // 卡心向手指位置收敛（按凝缩进度插值）：起手时页面
                        // 还大，只轻微跟随；凝缩完成后卡心稳贴手指——
                        // 1:1 translation 会把卡片甩出屏幕（首轮实测）。
                        let p = min(1, hypot(t.x, t.y) / Self.condenseRadius)
                        cardOffset = CGSize(
                            width: (loc.x - geo.size.width / 2) * p,
                            height: (loc.y - geo.size.height / 2) * p
                        )
                        updateDockHover(fingerY: loc.y, in: geo.size)
                    },
                    onEnded: { t, _ in
                        resolveRelease(translation: t, in: geo.size)
                    },
                    onCancelled: { snapBack() }
                )
                .frame(width: 0, height: 0)
            )
        }
    }

    // MARK: Hit-testing & release

    /// 手指落进底部判定区即视为悬于坞上（卡心贴手指，两者等价，
    /// 但手指判定对用户更直觉）。
    private func updateDockHover(fingerY: CGFloat, in size: CGSize) {
        let hovering = fingerY > size.height - Self.dockZoneHeight
        if hovering != isOverDock {
            withAnimation(Motion.spring) { isOverDock = hovering }
            if hovering { Haptics.soft() }
        }
    }

    private func resolveRelease(translation t: CGPoint, in size: CGSize) {
        if isOverDock {
            Haptics.rigid(intensity: 0.8)
            // 卡片吸入坞位，随即交给 sheet 呈现。
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                cardOffset = CGSize(width: 0, height: size.height / 2 - Self.dockZoneHeight / 2)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                onAsk()
                snapBack(delay: 0.35)
            }
        } else if t.x > size.width * Self.backCommitFraction {
            Haptics.tapConfirm()
            onCommitBack()
            snapBack(delay: 0.3)
        } else {
            snapBack()
        }
    }

    /// 复位。`delay` 用于 onAsk/onCommitBack 后等 sheet/pop 呈现完再复位，
    /// 避免复位动画在转场底下闪一帧。
    private func snapBack(delay: TimeInterval = 0) {
        let work = {
            withAnimation(Motion.spring) {
                translation = .zero
                cardOffset = .zero
                isDragging = false
                isOverDock = false
            }
        }
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            work()
        }
    }
}

extension View {
    /// 详情页「拖拽入坞唤起 AI 对话」手势（issue #837）。
    func dropToAsk(
        isEnabled: Bool = true,
        onAsk: @escaping () -> Void,
        onCommitBack: @escaping () -> Void
    ) -> some View {
        modifier(DropToAskModifier(
            isEnabled: isEnabled,
            onAsk: onAsk,
            onCommitBack: onCommitBack
        ))
    }
}

// MARK: - AskDockView

/// 底部「对话坞」：玻璃胶囊，卡片悬停时琥珀点亮。
private struct AskDockView: View {
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(isHighlighted ? DSColor.amberAccent : DSColor.accentOnBg)
            Text(NSLocalizedString(
                "memo.detail.drop_dock",
                value: "Drop here to ask",
                comment: "Detail view — drop-to-ask dock label"
            ))
            .font(DSType.bodySM)
            .foregroundColor(DSColor.inkPrimary)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(isHighlighted ? AnyView(DSColor.amberSoft) : AnyView(Color.clear))
        .liquidGlassCard(cornerRadius: 28)
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(
                    DSColor.amberRim.opacity(isHighlighted ? 1 : 0.4),
                    lineWidth: isHighlighted ? 1 : 0.5
                )
        )
        .scaleEffect(isHighlighted ? 1.06 : 1.0)
        .animation(Motion.spring, value: isHighlighted)
        .accessibilityHidden(true) // 手势不可达路径；无障碍走 CTA。
    }
}
