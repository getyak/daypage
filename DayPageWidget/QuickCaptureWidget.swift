import WidgetKit
import SwiftUI
import AppIntents

// MARK: - QuickCaptureWidget
//
// Home Screen / Lock Screen widget that opens DayPage straight into the
// voice recorder. The whole widget surface is a single Button bound to
// `StartRecordingIntent` so iOS treats it as a one-tap action — no preview
// expansion, no list of options.

@available(iOS 17.0, *)
struct QuickCaptureWidget: Widget {

    let kind: String = "com.daypage.widget.quickcapture"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: QuickCaptureProvider()) { _ in
            QuickCaptureWidgetView()
                .containerBackground(.fill.tertiary, for: .widget)
                // Fallback path: even if the Button(intent:) wiring fails for
                // some reason, tapping anywhere on the widget surface opens
                // the deep link, which DayPageApp.onOpenURL converts into a
                // recording trigger.
                .widgetURL(URL(string: "daypage://record"))
        }
        .configurationDisplayName("快速记录")
        .description("一键开启 DayPage 语音录音。")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
    }
}

// MARK: - Provider

private struct QuickCaptureProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickCaptureEntry {
        QuickCaptureEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (QuickCaptureEntry) -> Void) {
        completion(QuickCaptureEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickCaptureEntry>) -> Void) {
        completion(Timeline(entries: [QuickCaptureEntry(date: Date())], policy: .never))
    }
}

private struct QuickCaptureEntry: TimelineEntry {
    let date: Date
}

// MARK: - View

private struct QuickCaptureWidgetView: View {

    @Environment(\.widgetFamily) private var family

    var body: some View {
        Button(intent: StartRecordingIntent()) {
            content
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "mic.fill")
                    .font(.title3)
            }

        case .accessoryRectangular:
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("DayPage")
                        .font(.caption.weight(.semibold))
                    Text("记一条")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

        default:
            VStack(spacing: 10) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.tint)
                Text("记一条")
                    .font(.headline)
                Text("DayPage")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
