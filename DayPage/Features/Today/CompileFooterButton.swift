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
    /// AI key 未配置时为 true，按钮显示引导态。
    var aiKeyMissing: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// F3: master AI toggle — when off, disable the compile button up-front
    /// so the user doesn't tap and only then learn AI is disabled.
    @AppStorage(AppSettings.Keys.aiFeaturesEnabled) private var aiFeaturesEnabled: Bool = true
    /// Controls the one-shot scale pulse on first reveal (visual only).
    @State private var didAppearPulse = false
    /// Cached hour component, refreshed every minute so the hint stays current across hour boundaries.
    @State private var currentHour: Int = Calendar.current.component(.hour, from: Date())

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
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: isVisible)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: isCompiling)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: errorMessage)
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
                Haptics.tapConfirm()
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
                    } else if aiKeyMissing {
                        Image(systemName: "gearshape")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(DSColor.onSurface)
                        Text(NSLocalizedString("compile.configure_ai", comment: "Configure AI engine"))
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
                .shadow(
                    color: DSColor.accentAmber.opacity(didAppearPulse ? 0.6 : 0),
                    radius: 10
                )
                .surfaceElevatedShadow()
            }
            .buttonStyle(CompilePressStyle(isDisabled: isCompiling || !aiFeaturesEnabled))
            .disabled(isCompiling || !aiFeaturesEnabled)
            .scaleEffect(didAppearPulse ? 1.06 : 1.0)
            .animation(
                Motion.respectReduceMotion(.spring(response: 0.4, dampingFraction: 0.55)),
                value: didAppearPulse
            )
            .padding(.bottom, 6)
            .onAppear {
                guard !isCompiling, errorMessage == nil else { return }
                didAppearPulse = true
                Task {
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    didAppearPulse = false
                }
            }

            // F3: surface why the button is disabled when AI is off.
            if !aiFeaturesEnabled && !isCompiling {
                Text(NSLocalizedString("compile.dock.ai_disabled",
                                       comment: "Hint under compile button when AI features are off"))
                    .font(DSType.mono10)
                    .foregroundColor(DSColor.inkSubtle)
                    .tracking(0.5)
                    .opacity(0.8)
            }
            // Time-of-day hint — only when idle and no error and AI is on
            else if !isCompiling && errorMessage == nil {
                Text(timeHint)
                    .font(DSType.mono10)
                    .foregroundColor(DSColor.inkSubtle)
                    .tracking(0.5)
                    .opacity(0.8)
                    .transition(.opacity)
            }
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            currentHour = Calendar.current.component(.hour, from: Date())
        }
    }

    /// Contextual nudge based on time of day.
    private var timeHint: String {
        switch currentHour {
        case 5..<12:  return NSLocalizedString("compile.hint.morning", comment: "")
        case 12..<18: return NSLocalizedString("compile.hint.afternoon", comment: "")
        case 18..<24: return NSLocalizedString("compile.hint.evening", comment: "")
        default:      return NSLocalizedString("compile.hint.night", comment: "")
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

// MARK: - CompilePressStyle

private struct CompilePressStyle: ButtonStyle {
    let isDisabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed && !isDisabled
        configuration.label
            .scaleEffect((!reduceMotion && pressed) ? 0.96 : 1)
            .opacity(pressed ? 0.92 : 1)
            .animation(
                reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7),
                value: configuration.isPressed
            )
    }
}

// MARK: - CompileProgressDock

/// Three capsule segments shown above the input bar when memos < 3.
/// Segments fill amber as memos accumulate, giving glanceable progress
/// toward unlocking AI compilation.
struct CompileProgressDock: View {
    let memoCount: Int

    /// Tracks the memoCount from the previous render so we can detect the
    /// exact 2→3 crossing and fire the unlock celebration only once.
    @State private var previousMemoCount: Int = 0
    /// When true, the third segment plays a one-shot scale+glow pulse.
    @State private var thirdSegmentPulsing: Bool = false
    /// When true, the next-to-fill segment breathes to signal forward momentum.
    @State private var nextSegmentBreathing: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    let isFilled = index < memoCount
                    let isPulsingSegment = (index == 2) && thirdSegmentPulsing
                    // The leftmost unfilled segment index, clamped to [0, 2].
                    let nextIndex = min(memoCount, 2)
                    let isBreathingSegment = index == nextIndex && memoCount < 3
                    // Glass base always present; amber fill draws on from leading edge.
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(DSColor.glassStd)
                        Capsule(style: .continuous)
                            .fill(DSColor.accentAmber)
                            .opacity(isBreathingSegment ? (nextSegmentBreathing ? 0.55 : 0.2) : 1)
                            .animation(
                                isBreathingSegment && !reduceMotion
                                    ? .easeInOut(duration: 1.4).repeatForever(autoreverses: true)
                                    : nil,
                                value: nextSegmentBreathing
                            )
                            .scaleEffect(x: isFilled ? 1 : (isBreathingSegment ? 1 : 0), y: 1, anchor: .leading)
                            .animation(
                                Motion.respectReduceMotion(
                                    .spring(response: 0.45, dampingFraction: 0.7)
                                )
                                .delay(Double(index) * 0.04),
                                value: memoCount
                            )
                    }
                    .frame(width: 28, height: 4)
                    .shadow(
                        color: isPulsingSegment ? DSColor.accentAmber.opacity(0.75) : .clear,
                        radius: isPulsingSegment ? 6 : 0
                    )
                    .scaleEffect(isPulsingSegment ? 1.35 : 1.0)
                    .animation(
                        Motion.respectReduceMotion(
                            .spring(response: 0.4, dampingFraction: 0.6)
                        ),
                        value: thirdSegmentPulsing
                    )
                }
            }

            Text(L10n.Empty.compileDockLocked(
                current: memoCount,
                remaining: max(0, 3 - memoCount)
            ))
            .font(DSType.mono10)
            .foregroundColor(DSColor.inkSubtle)
            .textCase(.uppercase)
            .tracking(0.8)
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("compile-dock-hint")
        .accessibilityValue("\(memoCount) of 3")
        .onAppear {
            previousMemoCount = memoCount
            if !reduceMotion && memoCount < 3 {
                nextSegmentBreathing = true
            }
        }
        .onChange(of: memoCount) { newCount in
            if previousMemoCount < 3 && newCount == 3 {
                nextSegmentBreathing = false
                Haptics.success()
                UIAccessibility.post(notification: .announcement, argument: L10n.Empty.compileDockUnlocked)
                thirdSegmentPulsing = true
                Task {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    thirdSegmentPulsing = false
                }
            }
            previousMemoCount = newCount
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
