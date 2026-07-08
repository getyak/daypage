import SwiftUI

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
