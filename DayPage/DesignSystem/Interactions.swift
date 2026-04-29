import SwiftUI
import UIKit

// MARK: - PressableCardModifier

/// 对任何卡片视图应用按压缩放 + 暗色叠加及触觉反馈。
///
/// Fix (issue #150): 使用 `onLongPressGesture(onPressingChanged:)` 替代
/// `LongPressGesture`。`LongPressGesture` 是离散手势，`onEnded` 在识别时立即触发
///（约 50ms），导致 `isPressed` 最多保持一帧为 true，按压视觉反馈（缩放 + 叠加层）
/// 几乎不可见。`onPressingChanged` 在手指按下时回调 `true`、抬起或被高优先级手势
/// 取消时回调 `false`，行为正确且不干扰水平滑动手势。
struct PressableCardModifier: ViewModifier {
    @State private var isPressed: Bool = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed ? 0.98 : 1.0)
            .overlay(
                Color.black.opacity(isPressed ? 0.04 : 0)
                    .clipShape(RoundedRectangle(cornerRadius: DSSpacing.radiusCard, style: .continuous))
            )
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isPressed)
            .onLongPressGesture(minimumDuration: 0.01, maximumDistance: 10) {
                // 轻触动作由 MemoCardView 内部的 .onTapGesture 处理
                // 此处不执行任何操作
            } onPressingChanged: { pressing in
                if pressing {
                    if !isPressed {
                        isPressed = true
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
