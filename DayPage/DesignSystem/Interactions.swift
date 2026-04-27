import SwiftUI
import UIKit

// MARK: - PressableCardModifier

/// 对任何卡片视图应用按压缩放 + 暗色叠加及触觉反馈。
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
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isPressed {
                            isPressed = true
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                    }
                    .onEnded { _ in
                        isPressed = false
                    }
            )
    }
}

extension View {
    func pressableCard() -> some View {
        modifier(PressableCardModifier())
    }
}
