import SwiftUI

// MARK: - CompileFooterButton

/// 固定在 InputBarView 上方的编译入口。
/// 可见性由父视图（TodayView）通过 `isVisible` 控制；此视图负责
/// 显示编译进度阶段、错误信息及重试按钮。
struct CompileFooterButton: View {

    /// 今日已记录的原始 memo 数量。
    let memoCount: Int
    /// 当前是否正在执行编译。
    let isCompiling: Bool
    /// 是否渲染按钮。为 `false` 时，视图以弹性动画缩小至零尺寸。
    let isVisible: Bool
    /// 当前编译阶段（US-020）。
    var stage: CompilationStage = .extracting
    /// 编译失败时的错误描述（US-020）。nil 表示无错误。
    var errorMessage: String? = nil
    /// 用户点击立即编译时触发。编译中忽略。
    let onTap: () -> Void
    /// 用户点击重试时触发（US-020）。
    var onRetry: (() -> Void)? = nil

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
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: errorMessage)
    }

    // MARK: 内容

    private var buttonBody: some View {
        VStack(spacing: 6) {
            // Error banner row (US-020)
            if let msg = errorMessage, !isCompiling {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DSColor.errorRed)
                    Text(msg)
                        .font(.custom("Inter-Regular", size: 12))
                        .foregroundColor(DSColor.errorRed)
                        .lineLimit(2)
                    Spacer()
                    if let retry = onRetry {
                        Button(action: retry) {
                            Text("重试")
                                .font(.custom("Inter-Medium", size: 12))
                                .foregroundColor(DSColor.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(DSColor.errorSoft)
                .clipShape(Capsule(style: .continuous))
            }

            // Main compile button
            Button(action: {
                guard !isCompiling else { return }
                onTap()
            }) {
                HStack(spacing: 8) {
                    if isCompiling {
                        ProgressView()
                            .scaleEffect(0.7)
                            .tint(DSColor.onSurface)
                        Text(stageLabel)
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

    /// Human-readable label for the current compilation stage.
    private var stageLabel: String {
        switch stage {
        case .extracting:  return "读取 \(memoCount) 条 memo…"
        case .compiling:   return "AI 正在编译…"
        case .formatting:  return "写入 Daily Page…"
        case .done:        return "准备编译 \(memoCount) 条 memo"
        }
    }
}

// MARK: - ScrollOffsetPreferenceKey

/// 承载底部锚点在 ScrollView 本地坐标空间中的 minY 值。
struct CompileFooterAnchorPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

// MARK: - 放置锚点的辅助视图

/// 零高度锚点，插入 ScrollView 内容底部。
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
