#if canImport(AlarmKit)
import WidgetKit
import SwiftUI
import UIKit
import AlarmKit
import AppIntents

// MARK: - CaptureReminderLiveActivity
//
// AlarmKit(iOS 26+)提醒的灵动岛/锁屏呈现。AlarmKit 用 AlarmAttributes<Metadata>
// 作为 Live Activity 的 attributes,我们提供 metadata = CaptureAlarmMetadata。
//
// 设计(参考 HIG 灵动岛规范 + 系统时钟/计时器的呈现语言):
//   • compact:leading 琥珀麦克风(alerting 时呼吸),trailing「记一句」CTA 短文案
//     —— compact 态必须可扫读,严禁「占位却乌黑」。
//   • minimal:单颗琥珀麦克风(多活动并存时的最小态)。
//   • expanded:leading 图标+标题(标准布局:标题跟图标同侧),bottom 一句轻提示
//     + 琥珀胶囊 CTA;keyline 同步品牌琥珀,黑底玻璃质感由系统提供。
//   • 状态感知:context.state.mode == .alert 时麦克风 .breathe 呼吸、CTA 波形
//     .variableColor 流动 —— 岛是「活」的,不是一张静态贴纸。
//   • 品牌色单源:琥珀一律读 attributes.tintColor(service 侧唯一定义),
//     widget 不再自持硬编码副本。
//   • 文案克制、不命令式,呼应「悄悄召唤、不打扰」的产品气质。

@available(iOS 26.0, *)
struct CaptureReminderLiveActivity: Widget {

    private typealias Context = ActivityViewContext<AlarmAttributes<CaptureAlarmMetadata>>

    // MARK: 锁屏卡品牌配色
    //
    // 镜像 design-tokens/tokens.json(widget target 不含生成的 DSTokens.swift;
    // tokens 变更后须同步此处)。琥珀 accent 不在此镜像 —— 它经由
    // AlarmAttributes.tintColor 从 app 侧单源下发,锁屏另取明暗自适应变体。
    private enum Palette {
        /// bg.warm — light #FAF8F6 / dark #1A1814
        static let bgWarm = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.102, green: 0.094, blue: 0.078, alpha: 1.0)
                : UIColor(red: 0.980, green: 0.973, blue: 0.965, alpha: 1.0)
        })
        /// fg.primary — light #2B2822 / dark #F0EDE8
        static let ink = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.941, green: 0.929, blue: 0.910, alpha: 1.0)
                : UIColor(red: 0.169, green: 0.157, blue: 0.133, alpha: 1.0)
        })
        /// fg.muted — light #6B6560 / dark #A39F99
        static let inkMuted = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.639, green: 0.624, blue: 0.600, alpha: 1.0)
                : UIColor(red: 0.420, green: 0.396, blue: 0.376, alpha: 1.0)
        })
        /// 琥珀 accent — light #A8541B(DSColor.amberAccent)/ dark #C9883A(tokens accent dark)
        static let amber = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.788, green: 0.533, blue: 0.227, alpha: 1.0)
                : UIColor(red: 0.659, green: 0.329, blue: 0.106, alpha: 1.0)
        })
        /// 琥珀底上的前景:浅色下白字够对比,暗色琥珀偏亮改用深墨。
        static let onAmber = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.102, green: 0.094, blue: 0.078, alpha: 1.0)
                : UIColor.white
        })
    }

    private static let recordURL = URL(string: "daypage://record")!

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<CaptureAlarmMetadata>.self) { context in
            // 锁屏 / 横幅呈现 —— 暖米色品牌卡,和 app 内「日式美术馆」同一语境。
            lockScreen(context)
                .padding()
                .activityBackgroundTint(Palette.bgWarm)
                .activitySystemActionForegroundColor(Palette.amber)
        } dynamicIsland: { context in
            DynamicIsland {
                // ── Expanded:一张有呼吸的卡。品牌行明确写「DayPage」释除
                //    「这是谁的」疑惑;大倒计时是主角;底部一句提示 + 琥珀 CTA。
                DynamicIslandExpandedRegion(.leading) {
                    Self.brandMark(context)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    // countdown 态给剩余时间(数据位,mono 大字);alerting 态由
                    // 系统横幅接管 expanded,这里自然留白。
                    if case .countdown(let cd) = context.state.mode {
                        Text(timerInterval: cd.startDate...cd.fireDate, countsDown: true)
                            .font(.title3.weight(.semibold).monospacedDigit())
                            .foregroundStyle(context.attributes.tintColor)
                            .multilineTextAlignment(.trailing)
                            .padding(.trailing, 2)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 10) {
                        Text(context.attributes.metadata?.prompt ?? "记一句给今天")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.62))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        Spacer(minLength: 8)
                        Link(destination: Self.recordURL) {
                            Label("记一句", systemImage: "waveform")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Self.onAmberInk(context))
                                .symbolEffect(.variableColor.iterative.reversing,
                                              options: .repeat(.continuous),
                                              isActive: Self.isAlerting(context))
                                .padding(.horizontal, 13)
                                .padding(.vertical, 6)
                                .background(context.attributes.tintColor, in: Capsule())
                        }
                    }
                    .padding(.top, 8)
                }
            } compactLeading: {
                // 复合品牌标:琥珀圆底盛麦克风 —— 比裸符号更有辨识度,一眼是
                // 「有品牌的记录提醒」而非通用闹钟。呼吸只在 alerting。
                Self.compactBadge(context)
            } compactTrailing: {
                // compact trailing 是数据位:countdown 给实时倒计时;
                // 其余(alerting)给 3 字 CTA。宽度预算内不截断。
                if case .countdown(let cd) = context.state.mode {
                    Text(timerInterval: cd.startDate...cd.fireDate, countsDown: true)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(context.attributes.tintColor)
                        .frame(maxWidth: 46)
                        .multilineTextAlignment(.trailing)
                } else {
                    Text("记一句")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(context.attributes.tintColor)
                }
            } minimal: {
                // minimal 空间只一个符号:琥珀麦克风,呼吸态 = alerting。
                Image(systemName: "mic.fill")
                    .foregroundStyle(context.attributes.tintColor)
                    .symbolEffect(.breathe, options: .repeat(.continuous),
                                  isActive: Self.isAlerting(context))
            }
            .widgetURL(Self.recordURL)
            .keylineTint(context.attributes.tintColor)
        }
    }

    /// alarm 已触发(.alert)—— 呼吸/波形动画只在这个状态跑,
    /// countdown/paused(本 app 不配置)保持静态。
    private static func isAlerting(_ context: Context) -> Bool {
        if case .alert = context.state.mode { return true }
        return false
    }

    // MARK: - Brand marks(建立「这是 DayPage」的辨识度)

    /// Expanded leading 的品牌行:琥珀圆底麦克风 + 「DayPage」名 + 一句状态。
    /// 明确写出 App 名,释除用户「主屏冒出个麦克风倒计时,谁的?」的疑惑。
    @ViewBuilder
    private static func brandMark(_ context: Context) -> some View {
        HStack(spacing: 9) {
            compactBadge(context)
            VStack(alignment: .leading, spacing: 1) {
                Text("DayPage")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text("记录此刻")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    /// compact leading / expanded 品牌圆标:琥珀圆底盛麦克风。比裸 SF Symbol
    /// 更有辨识度 —— 圆底 + 品牌琥珀让它读作「有身份的记录提醒」。呼吸态 =
    /// alerting(响铃前的预热窗口静态,不抢注意力)。
    @ViewBuilder
    private static func compactBadge(_ context: Context) -> some View {
        Image(systemName: "mic.fill")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(onAmberInk(context))
            .frame(width: 22, height: 22)
            .background(context.attributes.tintColor, in: Circle())
            .symbolEffect(.breathe, options: .repeat(.continuous),
                          isActive: isAlerting(context))
    }

    /// 琥珀底上的前景墨色:琥珀偏亮(暗色变体 #C9883A)→ 用深墨够对比;
    /// tintColor 由 app 侧单源下发,这里取一个恒定深墨(灵动岛恒黑底语境)。
    private static func onAmberInk(_ context: Context) -> Color {
        // 灵动岛恒黑底 + 琥珀 tint(#C9883A 亮琥珀)→ 深墨字对比最佳。
        Color(red: 0.102, green: 0.094, blue: 0.078)
    }

    @ViewBuilder
    private func lockScreen(_ context: Context) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "mic.fill")
                .font(.title2)
                .foregroundStyle(Palette.amber)
                .symbolEffect(.breathe, options: .repeat(.continuous),
                              isActive: Self.isAlerting(context))
            VStack(alignment: .leading, spacing: 3) {
                // 锁屏也明确写 App 名 —— 与灵动岛 expanded 品牌行一致,
                // 用户一眼知道是 DayPage 在召唤记录。
                HStack(spacing: 6) {
                    Text("DayPage")
                        .font(.headline)
                        .foregroundStyle(Palette.ink)
                    Text("记录此刻")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Palette.inkMuted)
                }
                Text(context.attributes.metadata?.prompt ?? "记一句给今天")
                    .font(.subheadline)
                    .foregroundStyle(Palette.inkMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Link(destination: Self.recordURL) {
                Image(systemName: "waveform")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Palette.onAmber)
                    .symbolEffect(.variableColor.iterative.reversing,
                                  options: .repeat(.continuous),
                                  isActive: Self.isAlerting(context))
                    .frame(width: 40, height: 40)
                    .background(Palette.amber, in: Circle())
            }
        }
    }
}
#endif
