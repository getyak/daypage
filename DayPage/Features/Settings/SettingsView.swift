import SwiftUI
import CoreLocation

@MainActor
struct SettingsView: View {

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var locationService = LocationService.shared

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    private var locationAuthLabel: String {
        switch locationService.authorizationStatus {
        case .notDetermined: return "未授权"
        case .denied: return "已拒绝"
        case .restricted: return "受限"
        case .authorizedWhenInUse: return "使用时"
        case .authorizedAlways: return "始终"
        @unknown default: return "未知"
        }
    }

    private var locationAuthColor: Color {
        switch locationService.authorizationStatus {
        case .authorizedAlways: return .green
        case .authorizedWhenInUse: return .orange
        default: return .red
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // MARK: API Keys
                Section("API Keys") {
                    apiKeyRow(
                        name: "DashScope",
                        value: Secrets.dashScopeApiKey
                    )
                    apiKeyRow(
                        name: "OpenAI (Whisper)",
                        value: Secrets.openAIWhisperApiKey
                    )
                    apiKeyRow(
                        name: "OpenWeatherMap",
                        value: Secrets.openWeatherApiKey
                    )
                }

                // MARK: 权限
                Section("权限") {
                    // 位置授权状态
                    HStack {
                        Label("定位权限", systemImage: "location.fill")
                        Spacer()
                        Text(locationAuthLabel)
                            .foregroundColor(locationAuthColor)
                            .font(.caption)
                            .fontWeight(.medium)
                    }

                    // 被动位置开关
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("启用被动位置")
                            Text("自动记录到访地点（需要始终授权）")
                                .font(.caption)
                                .foregroundColor(DSColor.onSurfaceVariant)
                        }
                        Spacer()
                        if locationService.hasAlwaysAuthorization {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        } else {
                            Button("授权") {
                                locationService.requestAlwaysAuthorization()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 2)
                }

                // MARK: 通知
                Section("通知") {
                    Text("配置占位")
                        .foregroundColor(DSColor.onSurfaceVariant)
                }

                // MARK: 关于
                Section("关于") {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text(appVersion)
                            .foregroundColor(DSColor.onSurfaceVariant)
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func apiKeyRow(name: String, value: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            if value.isEmpty {
                Text("未配置")
                    .foregroundColor(.red)
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.red.opacity(0.12))
                    .clipShape(Capsule())
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            }
        }
    }
}

#Preview {
    SettingsView()
}
