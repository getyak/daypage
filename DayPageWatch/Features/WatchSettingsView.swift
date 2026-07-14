import SwiftUI

// MARK: - WatchSettingsView

/// The settings page — the bottom page of the three-page vertical TabView.
/// Holds only the *day-to-day quick* settings that pass the "two-second
/// attention" test; full / advanced configuration lives in the iPhone Watch
/// app. Every control writes straight through to `WatchSettingsStore`, whose
/// values `RecordingView` reads live.
struct WatchSettingsView: View {

    @ObservedObject var settings: WatchSettingsStore

    var body: some View {
        List {
            // MARK: Capture mode
            Section {
                NavigationLink {
                    captureModePicker
                } label: {
                    settingRow(title: "捕获模式", value: settings.captureMode.title)
                }
            } header: {
                Text("捕获")
            } footer: {
                Text(settings.captureMode.subtitle)
            }

            // MARK: Recording
            Section("录音") {
                Stepper(value: $settings.maxDuration, in: 30...180, step: 10) {
                    settingRow(title: "时长上限", value: "\(settings.maxDuration)s")
                }
                NavigationLink {
                    audioQualityPicker
                } label: {
                    settingRow(title: "音质", value: settings.audioQuality.title)
                }
            }

            // MARK: Sync & cleanup
            Section {
                NavigationLink {
                    retentionPicker
                } label: {
                    settingRow(title: "未送达保留", value: settings.retentionPolicy.title)
                }
                Toggle("仅 Wi-Fi 传输", isOn: $settings.wifiOnlyTransfer)
            } header: {
                Text("同步与清理")
            } footer: {
                Text("已送达的录音会立即清理；未送达的按上面的策略保留。")
            }

            // MARK: Haptics
            Section("触感与提示") {
                Toggle("开始震动", isOn: $settings.hapticsOnStart)
                Toggle("停止震动", isOn: $settings.hapticsOnStop)
            }
        }
        .navigationTitle("设置")
        .containerBackground(.gray.gradient, for: .navigation)
    }

    // MARK: - Row helper

    private func settingRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Sub-pickers

    private var captureModePicker: some View {
        List {
            ForEach(WatchCaptureMode.allCases) { mode in
                Button {
                    settings.captureMode = mode
                } label: {
                    pickerRow(
                        title: mode.title,
                        subtitle: mode.subtitle,
                        selected: settings.captureMode == mode
                    )
                }
            }
        }
        .navigationTitle("捕获模式")
    }

    private var audioQualityPicker: some View {
        List {
            ForEach(WatchAudioQuality.allCases) { quality in
                Button {
                    settings.audioQuality = quality
                } label: {
                    pickerRow(
                        title: quality.title,
                        subtitle: "\(Int(quality.sampleRate / 1000)) kHz",
                        selected: settings.audioQuality == quality
                    )
                }
            }
        }
        .navigationTitle("音质")
    }

    private var retentionPicker: some View {
        List {
            ForEach(WatchRetentionPolicy.allCases) { policy in
                Button {
                    settings.retentionPolicy = policy
                } label: {
                    pickerRow(
                        title: policy.title,
                        subtitle: nil,
                        selected: settings.retentionPolicy == policy
                    )
                }
            }
        }
        .navigationTitle("未送达保留")
    }

    private func pickerRow(title: String, subtitle: String?, selected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if selected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .accessibilityLabel("已选中")
            }
        }
    }
}
