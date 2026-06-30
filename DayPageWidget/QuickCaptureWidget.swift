import WidgetKit
import SwiftUI
import AppIntents
import DayPageServices

// MARK: - QuickCaptureWidget
//
// Home Screen / Lock Screen widget that opens DayPage straight into the
// voice recorder. The whole widget surface is a single Button bound to
// `StartRecordingIntent` so iOS treats it as a one-tap action — no preview
// expansion, no list of options.

@available(iOS 17.0, *)
struct QuickCaptureWidget: Widget {

    let kind: String = "com.daypage.widget.quickcapture"

    // R5: feature-flag aware family list. `.systemMedium` is the only
    // family gated by `.widgetSystemMedium` — flipping that flag off in
    // Settings → Experiments collapses the widget back to the original
    // small + accessory set without a rebuild. Lock-screen accessory
    // families always stay because they're independent of the home-
    // screen layout flag.
    //
    // Note: `FeatureFlagStore.shared` is `@MainActor`. WidgetKit calls
    // `body` on the main actor at registration time, so the access is
    // safe. The store reads `UserDefaults.standard` — the widget
    // extension has its own .standard suite, which is intentional: the
    // flag default-on means new users see the same widget regardless of
    // whether the main app has ever launched.
    @MainActor
    private static var supportedFamilies: [WidgetFamily] {
        var families: [WidgetFamily] = [.systemSmall, .accessoryCircular, .accessoryRectangular]
        if FeatureFlagStore.shared.isEnabled(.widgetSystemMedium) {
            families.append(.systemMedium)
        }
        return families
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: QuickCaptureProvider()) { entry in
            QuickCaptureWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                // Fallback path: even if the Button(intent:) wiring fails for
                // some reason, tapping anywhere on the widget surface opens
                // the deep link, which DayPageApp.onOpenURL converts into a
                // recording trigger.
                .widgetURL(URL(string: "daypage://record"))
        }
        .configurationDisplayName("快速记录")
        .description("一键开启 DayPage 语音录音。")
        .supportedFamilies(Self.supportedFamilies)
    }
}

// MARK: - Provider

// App Group identifier mirrors the main app. When the App Group is enabled
// (DayPage + DayPageWidget share `group.com.daypage`), the widget reads the
// latest memo preview that the app writes. Without the group, the fallback
// placeholder "开始今天的记录" keeps .systemMedium from rendering blank.
private let kAppGroup = "group.com.daypage"
private let kLatestMemoKey = "latestMemoPreview"

private struct QuickCaptureProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickCaptureEntry {
        QuickCaptureEntry(date: Date(), latestMemoPreview: "开始今天的记录")
    }

    func getSnapshot(in context: Context, completion: @escaping (QuickCaptureEntry) -> Void) {
        completion(QuickCaptureEntry(date: Date(), latestMemoPreview: Self.readLatestMemo()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickCaptureEntry>) -> Void) {
        let entry = QuickCaptureEntry(date: Date(), latestMemoPreview: Self.readLatestMemo())
        // Refresh every 30 min so a fresh memo eventually surfaces on the medium widget.
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private static func readLatestMemo() -> String {
        if let defaults = UserDefaults(suiteName: kAppGroup),
           let raw = defaults.string(forKey: kLatestMemoKey) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return String(trimmed.prefix(30)) }
        }
        return "开始今天的记录"
    }
}

private struct QuickCaptureEntry: TimelineEntry {
    let date: Date
    let latestMemoPreview: String
}

// MARK: - View

private struct QuickCaptureWidgetView: View {

    let entry: QuickCaptureEntry
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

        case .systemMedium:
            // Left half: the small-widget mic CTA. Right half: today's date
            // plus a 30-char preview of the latest memo so the medium widget
            // earns its extra real estate. Tapping anywhere still routes to
            // StartRecordingIntent via the wrapping Button.
            HStack(spacing: 16) {
                smallCTA
                    .frame(maxWidth: .infinity)
                Divider()
                    .opacity(0.4)
                VStack(alignment: .leading, spacing: 6) {
                    Text(Self.mediumDateFormatter.string(from: entry.date))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("最近一条")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(entry.latestMemoPreview)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 4)

        default:
            smallCTA
        }
    }

    // Shared by .systemSmall and the left column of .systemMedium so the
    // small-widget visual identity stays consistent across sizes.
    private var smallCTA: some View {
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

    private static let mediumDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM/dd EEE"
        return f
    }()
}
