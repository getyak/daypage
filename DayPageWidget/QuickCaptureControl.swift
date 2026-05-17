import WidgetKit
import SwiftUI
import AppIntents

// MARK: - QuickCaptureControl
//
// iOS 18+ Control Widget: shows up in Control Center, Lock Screen control
// area, and is assignable to the Action Button. Tapping fires the shared
// `StartRecordingIntent`.

@available(iOS 18.0, *)
struct QuickCaptureControl: ControlWidget {

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: "com.daypage.control.quickcapture"
        ) {
            ControlWidgetButton(action: StartRecordingIntent()) {
                Label("记一条", systemImage: "mic.fill")
            }
        }
        .displayName("DayPage 录音")
        .description("一键开启语音录音。")
    }
}
