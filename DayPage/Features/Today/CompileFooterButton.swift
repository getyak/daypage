import SwiftUI

// MARK: - CompileFooterButton

/// 固定在 InputBarView 上方的编译入口。
/// 可见性由父视图（TodayView）通过 `isVisible` 控制；此视图仅
/// 负责淡入/淡出动画以及在 `.idle` 和 `.compiling` 状态之间切换。
///
/// 设计：胶囊形，1pt 描边，半透明表面，闪光图标 + 标签。
/// US-005 替代时间线中的内联 CompilePromptCard 入口。
struct CompileFooterButton: View {

    /// 今日已记录的原始 memo 数量。
    let memoCount: Int
    /// 当前是否正在执行编译。
    let isCompiling: Bool
    /// 是否渲染按钮。为 `false` 时，视图以弹性动画缩小至零尺寸。
    let isVisible: Bool
    /// 用户点击立即编译时触发。编译中忽略。
    let onTap: () -> Void

    var body: some View {
        Group {
            if isVisible {
                buttonBody
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.9).combined(with: .opacity),
                            removal: .opacity
                        )
                    )
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isVisible)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isCompiling)
    }

    // MARK: 内容

    private var buttonBody: some View {
        Button(action: {
            guard !isCompiling else { return }
            onTap()
        }) {
            HStack(spacing: 8) {
                if isCompiling {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(DSColor.onSurface)
                    Text("正在编译 \(memoCount) 条 memo")
                        .font(.custom("Inter-Medium", size: 13))
                        .foregroundColor(DSColor.onSurface)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DSColor.onSurface)
                    Text("编译今日 · \(memoCount) 条")
                        .font(.custom("Inter-Medium", size: 13))
                        .foregroundColor(DSColor.onSurface)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(DSColor.surface.opacity(0.85))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(DSColor.outlineVariant, lineWidth: 1)
            )
            .surfaceElevatedShadow()
        }
        .buttonStyle(.plain)
        .disabled(isCompiling)
        .padding(.bottom, 6)
    }
}

// MARK: - ScrollOffsetPreferenceKey

/// 承载底部锚点在 ScrollView 本地坐标空间中的 minY 值。
/// 父视图将其与 ScrollView 可见高度 + 松弛量进行比较，以决定
/// 是否显示编译底部按钮。
///
/// 锚点放置在 ScrollView 内容的末尾；当用户滚动到
/// 接近底部时，`minY` 接近 ScrollView 的可见高度。
struct CompileFooterAnchorPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

// MARK: - 放置锚点的辅助视图

/// 零高度锚点，插入 ScrollView 内容底部。
/// 通过在 ScrollView 坐标空间（`named: "todayScroll"`）中的 minY
/// 来发射 `CompileFooterAnchorPreferenceKey`。
struct CompileFooterAnchor: View {
    var body: some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: CompileFooterAnchorPreferenceKey.self,
                value: geo.frame(in: .named("todayScroll")).minY
            )
        }
        .frame(height: 1)
    }
}
