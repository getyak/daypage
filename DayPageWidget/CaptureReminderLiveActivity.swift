#if canImport(AlarmKit)
import WidgetKit
import SwiftUI
import AlarmKit
import AppIntents

// MARK: - CaptureReminderLiveActivity
//
// AlarmKit(iOS 26+)提醒的灵动岛/锁屏呈现。AlarmKit 用 AlarmAttributes<Metadata>
// 作为 Live Activity 的 attributes,我们提供 metadata = CaptureAlarmMetadata。
//
// 设计(参考 Apple Design «Designing Fluid Interfaces» + HIG 灵动岛规范):
//   • compact:leading 一颗琥珀麦克风,trailing 留白 —— 极简、不喧宾夺主。
//   • minimal:单颗琥珀麦克风(多活动并存时的最小态)。
//   • expanded:leading 麦克风 + 标题「记录此刻」,trailing 一句轻提示(prompt),
//     bottom 一个「记一句」按钮。琥珀 tint 呼应品牌,黑底玻璃质感由系统提供。
//   • 文案克制、不命令式,呼应「悄悄召唤、不打扰」的产品气质。

@available(iOS 26.0, *)
struct CaptureReminderLiveActivity: Widget {

    // 琥珀 amber —— 与 app 内品牌 accent 对齐。
    private static let amber = Color(red: 0.74, green: 0.49, blue: 0.14)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<CaptureAlarmMetadata>.self) { context in
            // 锁屏 / 横幅呈现。
            lockScreen(context)
                .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "mic.fill")
                        .font(.title3)
                        .foregroundStyle(Self.amber)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("记录此刻")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.attributes.metadata?.prompt ?? "记一句给今天")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Link(destination: URL(string: "daypage://record")!) {
                            Label("记一句", systemImage: "waveform")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Self.amber, in: Capsule())
                        }
                    }
                    .padding(.top, 2)
                }
            } compactLeading: {
                Image(systemName: "mic.fill")
                    .foregroundStyle(Self.amber)
            } compactTrailing: {
                // 保持克制:compact 态只留一点点琥珀呼吸,不塞文字。
                Circle()
                    .fill(Self.amber.opacity(0.9))
                    .frame(width: 6, height: 6)
            } minimal: {
                Image(systemName: "mic.fill")
                    .foregroundStyle(Self.amber)
            }
            .widgetURL(URL(string: "daypage://record"))
        }
    }

    @ViewBuilder
    private func lockScreen(_ context: ActivityViewContext<AlarmAttributes<CaptureAlarmMetadata>>) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "mic.fill")
                .font(.title2)
                .foregroundStyle(Self.amber)
            VStack(alignment: .leading, spacing: 3) {
                Text("记录此刻")
                    .font(.headline)
                Text(context.attributes.metadata?.prompt ?? "记一句给今天")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Link(destination: URL(string: "daypage://record")!) {
                Image(systemName: "waveform")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.black)
                    .frame(width: 40, height: 40)
                    .background(Self.amber, in: Circle())
            }
        }
    }
}
#endif
