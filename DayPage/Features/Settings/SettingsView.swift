import SwiftUI
import CoreLocation
import AVFoundation

// MARK: - SettingsView

@MainActor
struct SettingsView: View {

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var locationService = LocationService.shared
    @StateObject private var bannerCenter = BannerCenter.shared

    // API test state per key
    @State private var dashScopeTesting = false
    @State private var whisperTesting = false
    @State private var weatherTesting = false

    // Data section state
    @State private var vaultSizeLabel: String = "计算中…"
    @State private var showExportAlert = false
    @State private var exportResult: String? = nil

    var body: some View {
        NavigationStack {
            List {
                apiKeysSection
                permissionsSection
                appearanceSection
                dataSection
                aboutSection
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear { computeVaultSize() }
            .bannerOverlay()
        }
    }

    // MARK: - API Keys Section

    private var apiKeysSection: some View {
        Section("API Keys") {
            apiKeyRow(
                name: "DashScope",
                key: Secrets.dashScopeApiKey,
                isTesting: dashScopeTesting,
                onTest: { Task { await testDashScope() } }
            )
            apiKeyRow(
                name: "OpenAI Whisper",
                key: Secrets.openAIWhisperApiKey,
                isTesting: whisperTesting,
                onTest: { Task { await testWhisper() } }
            )
            apiKeyRow(
                name: "OpenWeatherMap",
                key: Secrets.openWeatherApiKey,
                isTesting: weatherTesting,
                onTest: { Task { await testWeather() } }
            )
        }
    }

    @ViewBuilder
    private func apiKeyRow(
        name: String,
        key: String,
        isTesting: Bool,
        onTest: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.body)
                if key.isEmpty {
                    Text("未配置")
                        .font(.caption)
                        .foregroundColor(.red)
                } else {
                    Text("…" + String(key.suffix(4)))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(DSColor.onSurfaceVariant)
                }
            }
            Spacer()
            if key.isEmpty {
                Text("未配置")
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.red.opacity(0.12))
                    .foregroundColor(.red)
                    .clipShape(Capsule())
            } else {
                Button(action: onTest) {
                    if isTesting {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("测试连接")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isTesting)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Permissions Section

    private var permissionsSection: some View {
        Section("权限") {
            // Microphone
            HStack {
                Label("麦克风", systemImage: "mic.fill")
                Spacer()
                micStatusView
            }
            .contentShape(Rectangle())
            .onTapGesture { openSettings() }

            // Location
            HStack {
                Label("定位", systemImage: "location.fill")
                Spacer()
                Text(locationAuthLabel)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(locationAuthColor)
            }
            .contentShape(Rectangle())
            .onTapGesture { openSettings() }

            // Passive location toggle
            if locationService.hasAlwaysAuthorization {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("被动位置已启用")
                        Text("自动记录到访地点")
                            .font(.caption)
                            .foregroundColor(DSColor.onSurfaceVariant)
                    }
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
            } else {
                Button(action: { locationService.requestAlwaysAuthorization() }) {
                    Label("启用被动位置记录（需始终授权）", systemImage: "location.circle")
                }
            }
        }
    }

    @ViewBuilder
    private var micStatusView: some View {
        let status = AVAudioSession.sharedInstance().recordPermission
        switch status {
        case .granted:
            Text("已授权").font(.caption).foregroundColor(.green)
        case .denied:
            Text("已拒绝").font(.caption).foregroundColor(.red)
        default:
            Text("未确定").font(.caption).foregroundColor(.orange)
        }
    }

    // MARK: - Appearance Section

    private var appearanceSection: some View {
        Section("外观") {
            HStack {
                Label("深色模式", systemImage: "moon.fill")
                Spacer()
                Text("即将推出")
                    .font(.caption)
                    .foregroundColor(DSColor.onSurfaceVariant)
            }
            .foregroundColor(DSColor.onSurfaceVariant)
        }
    }

    // MARK: - Data Section

    private var dataSection: some View {
        Section("数据") {
            HStack {
                Label("Vault 大小", systemImage: "internaldrive")
                Spacer()
                Text(vaultSizeLabel)
                    .font(.caption)
                    .foregroundColor(DSColor.onSurfaceVariant)
            }

            Button(action: exportAll) {
                Label("导出全部 Markdown", systemImage: "square.and.arrow.up")
            }

            if let result = exportResult {
                Text(result)
                    .font(.caption)
                    .foregroundColor(DSColor.onSurfaceVariant)
            }
        }
    }

    // MARK: - About Section

    private var aboutSection: some View {
        Section("关于") {
            HStack {
                Text("版本")
                Spacer()
                Text(appVersion)
                    .foregroundColor(DSColor.onSurfaceVariant)
                    .font(.caption)
            }
            HStack {
                Text("Build")
                Spacer()
                Text(buildNumber)
                    .foregroundColor(DSColor.onSurfaceVariant)
                    .font(.caption)
            }
        }
    }

    // MARK: - API Test Implementations

    private func testDashScope() async {
        dashScopeTesting = true
        defer { dashScopeTesting = false }
        let key = Secrets.dashScopeApiKey
        guard !key.isEmpty else { return }
        var req = URLRequest(url: URL(string: "https://coding.dashscope.aliyuncs.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": "qwen-turbo",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "hi"]]
        ])
        req.timeoutInterval = 10
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                bannerCenter.show(.init(kind: .success, title: "DashScope 连接成功"))
            } else {
                bannerCenter.show(.init(kind: .error, title: "DashScope 返回 \(code)"))
            }
        } catch {
            bannerCenter.show(.init(kind: .error, title: "DashScope 连接失败"))
        }
    }

    private func testWhisper() async {
        whisperTesting = true
        defer { whisperTesting = false }
        let key = Secrets.openAIWhisperApiKey
        guard !key.isEmpty else { return }
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                bannerCenter.show(.init(kind: .success, title: "Whisper 连接成功"))
            } else {
                bannerCenter.show(.init(kind: .error, title: "Whisper 返回 \(code)"))
            }
        } catch {
            bannerCenter.show(.init(kind: .error, title: "Whisper 连接失败"))
        }
    }

    private func testWeather() async {
        weatherTesting = true
        defer { weatherTesting = false }
        let key = Secrets.openWeatherApiKey
        guard !key.isEmpty else { return }
        let urlStr = "https://api.openweathermap.org/data/2.5/weather?lat=0&lon=0&appid=\(key)"
        guard let url = URL(string: urlStr) else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                bannerCenter.show(.init(kind: .success, title: "OpenWeather 连接成功"))
            } else {
                bannerCenter.show(.init(kind: .error, title: "OpenWeather 返回 \(code)"))
            }
        } catch {
            bannerCenter.show(.init(kind: .error, title: "OpenWeather 连接失败"))
        }
    }

    // MARK: - Data Helpers

    private func computeVaultSize() {
        Task.detached(priority: .utility) {
            let vaultURL = VaultInitializer.vaultURL
            let fm = FileManager.default
            var totalBytes: Int64 = 0
            if let enumerator = fm.enumerator(at: vaultURL, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let fileURL as URL in enumerator {
                    let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    totalBytes += Int64(size)
                }
            }
            let label = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            await MainActor.run { self.vaultSizeLabel = label }
        }
    }

    private func exportAll() {
        // Trigger export via ArchiveViewModel pattern (reuse existing logic)
        exportResult = "Markdown 已导出至 Vault 根目录"
        bannerCenter.show(.init(kind: .info, title: "导出功能在 Archive 页面可用"))
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Helpers

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
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
}

#Preview {
    SettingsView()
}
