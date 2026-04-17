import SwiftUI

@MainActor
struct SettingsView: View {

    @Environment(\.dismiss) private var dismiss

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                // MARK: API Keys
                Section("API Keys") {
                    Text("配置占位")
                        .foregroundColor(DSColor.onSurfaceVariant)
                }

                // MARK: 权限
                Section("权限") {
                    Text("配置占位")
                        .foregroundColor(DSColor.onSurfaceVariant)
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
}

#Preview {
    SettingsView()
}
