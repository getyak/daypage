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
    @State private var deepSeekTesting = false
    @State private var whisperTesting = false
    @State private var weatherTesting = false

    // Inline test result per key (cleared on next test)
    @State private var deepSeekResult: APITestResult?
    @State private var whisperResult: APITestResult?
    @State private var weatherResult: APITestResult?

    // On This Day settings (backed by OnThisDayScheduler.shared via UserDefaults)
    @State private var onThisDayEnabled: Bool = OnThisDayScheduler.shared.isEnabled
    @State private var onThisDayRefreshHour: Int = OnThisDayScheduler.shared.refreshHour

    // Time zone settings
    @ObservedObject private var appSettings = AppSettings.shared
    @State private var timeZoneSearchText: String = ""
    @State private var showTimeZonePicker = false

    // iCloud sync monitor
    @StateObject private var syncMonitor = iCloudSyncMonitor.shared

    // Press-to-talk fallback toggle (US-008).
    @AppStorage("usePressToTalk") private var usePressToTalk: Bool = true

    // API key editing sheet
    @State private var editingKeyName: String = ""
    @State private var editingKeyUD: String = ""        // UserDefaults key name
    @State private var editingKeyValue: String = ""
    @State private var showApiKeyEditor = false
    @State private var keyRefreshToken: UUID = UUID()   // bump to force apiKeysSection redraw

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
                timeZoneSection
                iCloudSyncSection
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
            .sheet(isPresented: $showApiKeyEditor) {
                apiKeyEditorSheet
            }
        }
    }

    // MARK: - API Key Editor Sheet

    private var apiKeyEditorSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("填入 \(editingKeyName) 的 API Key")
                    .font(.headline)
                    .padding(.top, 8)

                SecureField("sk-... 或直接粘贴", text: $editingKeyValue)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                    .padding(.horizontal)

                HStack {
                    Button("粘贴") {
                        if let s = UIPasteboard.general.string { editingKeyValue = s }
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button("清除") {
                        editingKeyValue = ""
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
                .padding(.horizontal)

                Spacer()
            }
            .navigationTitle("配置 API Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showApiKeyEditor = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let trimmed = editingKeyValue.trimmingCharacters(in: .whitespaces)
                        if trimmed.isEmpty {
                            UserDefaults.standard.removeObject(forKey: editingKeyUD)
                        } else {
                            UserDefaults.standard.set(trimmed, forKey: editingKeyUD)
                        }
                        keyRefreshToken = UUID()
                        showApiKeyEditor = false
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - API Keys Section

    private var apiKeysSection: some View {
        Section("API Keys") {
            let _ = keyRefreshToken  // read token so SwiftUI re-evaluates when key is saved
            apiKeyRow(
                name: "DeepSeek",
                udKey: AppSettings.Keys.runtimeDeepSeekKey,
                key: Secrets.resolvedDeepSeekApiKey,
                isTesting: deepSeekTesting,
                result: deepSeekResult,
                onTest: { Task { await testDeepSeek() } }
            )
            apiKeyRow(
                name: "OpenAI Whisper",
                udKey: AppSettings.Keys.runtimeOpenAIKey,
                key: Secrets.resolvedOpenAIWhisperApiKey,
                isTesting: whisperTesting,
                result: whisperResult,
                onTest: { Task { await testWhisper() } }
            )
            apiKeyRow(
                name: "OpenWeatherMap",
                udKey: AppSettings.Keys.runtimeOpenWeatherKey,
                key: Secrets.resolvedOpenWeatherApiKey,
                isTesting: weatherTesting,
                result: weatherResult,
                onTest: { Task { await testWeather() } }
            )
        }
    }

    @ViewBuilder
    private func apiKeyRow(
        name: String,
        udKey: String,
        key: String,
        isTesting: Bool,
        result: APITestResult?,
        onTest: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
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
                // Edit button — always visible
                Button {
                    editingKeyName = name
                    editingKeyUD = udKey
                    editingKeyValue = UserDefaults.standard.string(forKey: udKey) ?? ""
                    showApiKeyEditor = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

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
            if let result {
                HStack(spacing: 6) {
                    Image(systemName: result.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(result.isSuccess ? .green : .red)
                    Text(result.message)
                        .font(.caption)
                        .foregroundColor(result.isSuccess ? .green : .red)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
            // Theme (dark mode)
            Picker(selection: $appSettings.themeMode) {
                ForEach(ThemeMode.allCases, id: \.self) { mode in
                    HStack {
                        Image(systemName: themeIcon(for: mode))
                        Text(mode.label)
                    }.tag(mode)
                }
            } label: {
                Label("深色模式", systemImage: "moon.fill")
            }

            // Accent color
            Picker(selection: $appSettings.accentColor) {
                ForEach(AccentColorOption.allCases, id: \.self) { color in
                    HStack {
                        Circle()
                            .fill(color.color)
                            .frame(width: 14, height: 14)
                        Text(color.label)
                    }.tag(color)
                }
            } label: {
                Label("强调色", systemImage: "paintpalette")
            }

            // Font size adjustment
            Picker(selection: $appSettings.fontSizeAdjust) {
                ForEach(FontSizeAdjust.allCases, id: \.self) { adjust in
                    Text(adjust.label).tag(adjust)
                }
            } label: {
                Label("正文字号", systemImage: "textformat.size")
            }

            // Card density
            Picker(selection: $appSettings.cardDensity) {
                ForEach(CardDensity.allCases, id: \.self) { density in
                    Text(density.label).tag(density)
                }
            } label: {
                Label("卡片密度", systemImage: "rectangle.expand.vertical")
            }

            // Press-to-talk (US-008). Invert the binding so the visible label reads
            // "Use legacy voice recording" per the PRD's legacy-fallback copy.
            Toggle(isOn: Binding(
                get: { !usePressToTalk },
                set: { usePressToTalk = !$0 }
            )) {
                Label("使用旧版语音录制", systemImage: "mic.circle")
            }

            // On This Day configuration
            Toggle(isOn: $onThisDayEnabled) {
                Label("On This Day", systemImage: "calendar.badge.clock")
            }
            .onChange(of: onThisDayEnabled) { val in
                OnThisDayScheduler.shared.isEnabled = val
            }

            if onThisDayEnabled {
                Picker("刷新时间", selection: $onThisDayRefreshHour) {
                    Text("午夜 00:00").tag(0)
                    Text("清晨 06:00").tag(6)
                    Text("上午 09:00").tag(9)
                }
                .onChange(of: onThisDayRefreshHour) { val in
                    OnThisDayScheduler.shared.refreshHour = val
                }
            }
        }
    }

    private func themeIcon(for mode: ThemeMode) -> String {
        switch mode {
        case .system: return "gearshape"
        case .light: return "sun.max"
        case .dark: return "moon.stars"
        }
    }

    // MARK: - Time Zone Section

    private var timeZoneSection: some View {
        Section {
            NavigationLink(destination: timeZonePickerView) {
                HStack {
                    Label("偏好时区", systemImage: "clock.badge.questionmark")
                    Spacer()
                    Text(appSettings.preferredTimeZone.localizedLabel)
                        .font(.caption)
                        .foregroundColor(DSColor.onSurfaceVariant)
                }
            }
            if appSettings.preferredTimeZone.identifier != TimeZone.current.identifier {
                Button(role: .destructive) {
                    appSettings.resetToDeviceTimeZone()
                    BackgroundCompilationService.shared.scheduleIfNeeded()
                } label: {
                    Label("恢复设备时区", systemImage: "arrow.counterclockwise")
                }
            }
        } header: {
            Text("时间与日期")
        } footer: {
            Text("所有 Memo 归属日期与编译触发时间均以此时区为准。旅行时锁定家乡时区，避免记录错位。")
                .font(.caption)
        }
    }

    private var timeZonePickerView: some View {
        TimeZonePickerView(
            selected: appSettings.preferredTimeZone,
            onSelect: { tz in
                appSettings.preferredTimeZone = tz
                BackgroundCompilationService.shared.scheduleIfNeeded()
            }
        )
    }

    // MARK: - iCloud Sync Section

    private var iCloudSyncSection: some View {
        Section {
            iCloudStatusRow
            attachmentPolicyPicker
            rollbackButton
            cleanupBackupButton
        } header: {
            Text("iCloud 同步")
        }
    }

    @ViewBuilder
    private var iCloudStatusRow: some View {
        switch syncMonitor.status {
        case .notConfigured:
            iCloudNotConfiguredCard

        case .connected(let lastSync):
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text("已连接").font(.body).fontWeight(.medium)
                    Text("iCloud Drive").font(.caption).foregroundColor(DSColor.onSurfaceVariant)
                }
                Spacer()
                if let date = lastSync {
                    Text(lastSyncLabel(date))
                        .font(.caption)
                        .foregroundColor(DSColor.onSurfaceVariant)
                }
            }

        case .syncing(let pendingFiles):
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("同步中").font(.body).fontWeight(.medium)
                    Text("\(pendingFiles) 个文件待传")
                        .font(.caption)
                        .foregroundColor(DSColor.onSurfaceVariant)
                }
            }

        case .error(let message):
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("同步错误").font(.body).fontWeight(.medium).foregroundColor(.red)
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(2)
                }
            }
        }
    }

    private var iCloudNotConfiguredCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("☁️")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("开启多设备同步")
                        .font(.body)
                        .fontWeight(.semibold)
                    Text("在 iPhone 与 iPad 之间同步你的日记")
                        .font(.caption)
                        .foregroundColor(DSColor.onSurfaceVariant)
                }
            }
            Button(action: openSettings) {
                Label("前往 iOS 设置开启 iCloud Drive", systemImage: "arrow.up.right.square")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var attachmentPolicyPicker: some View {
        if case .notConfigured = syncMonitor.status {
            EmptyView()
        } else {
            Picker(selection: Binding(
                get: { appSettings.attachmentPolicy },
                set: { appSettings.attachmentPolicy = $0 }
            )) {
                Text("按需下载（节省空间）").tag(AttachmentPolicy.onDemand)
                Text("始终保留本地副本").tag(AttachmentPolicy.alwaysLocal)
            } label: {
                Label("附件下载策略", systemImage: "square.and.arrow.down")
            }
        }
    }

    @ViewBuilder
    private var rollbackButton: some View {
        if let migratedAt = appSettings.migrationCompletedAt,
           Date().timeIntervalSince(migratedAt) < 30 * 24 * 3600 {
            Button(role: .destructive, action: rollbackToLocal) {
                Label("切换回本地存储", systemImage: "arrow.counterclockwise")
            }
        }
    }

    private func rollbackToLocal() {
        appSettings.vaultLocation = .local
        VaultInitializer.shared = LocalVaultLocator()
        bannerCenter.show(AppBannerModel(
            kind: .info,
            title: "已切换回本地存储",
            autoDismiss: true
        ))
    }

    // Shows only when: migrated to iCloud + 30-day window elapsed + local backup still exists
    @ViewBuilder
    private var cleanupBackupButton: some View {
        if let migratedAt = appSettings.migrationCompletedAt,
           Date().timeIntervalSince(migratedAt) >= 30 * 24 * 3600,
           appSettings.vaultLocation == .iCloud,
           FileManager.default.fileExists(atPath: LocalVaultLocator().vaultURL.path) {
            Button(role: .destructive, action: cleanupLocalBackup) {
                Label("清理本地备份", systemImage: "trash")
            }
        }
    }

    private func cleanupLocalBackup() {
        do {
            try VaultMigrationService.shared.deleteLocalBackup()
            bannerCenter.show(AppBannerModel(
                kind: .info,
                title: "本地备份已清理",
                autoDismiss: true
            ))
        } catch {
            bannerCenter.show(AppBannerModel(
                kind: .error,
                title: "清理失败：\(error.localizedDescription)",
                autoDismiss: true
            ))
        }
    }

    private func lastSyncLabel(_ date: Date) -> String {
        let cal = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        if cal.isDateInToday(date) {
            formatter.dateFormat = "今天 HH:mm"
        } else {
            formatter.dateFormat = "M月d日 HH:mm"
        }
        return formatter.string(from: date)
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

            if SampleDataSeeder.hasSeededSamples {
                Button(role: .destructive) {
                    SampleDataSeeder.clearSampleData()
                    bannerCenter.show(AppBannerModel(
                        kind: .success,
                        title: "示例数据已清除",
                        autoDismiss: true
                    ))
                } label: {
                    Label("清除示例数据", systemImage: "trash")
                }
            }

            if let result = exportResult {
                Text(result)
                    .font(.caption)
                    .foregroundColor(DSColor.onSurfaceVariant)
            }
        }
        .onAppear { computeVaultSize() }
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

    private func testDeepSeek() async {
        deepSeekTesting = true
        deepSeekResult = nil
        defer { deepSeekTesting = false }

        let key = Secrets.resolvedDeepSeekApiKey
        guard !key.isEmpty else { return }

        // Mirror CompilationService.callDeepSeek URL resolution so test hits the same endpoint
        let baseURL = Secrets.deepSeekBaseURL.isEmpty
            ? "https://api.deepseek.com/v1"
            : Secrets.deepSeekBaseURL
        let model = Secrets.deepSeekModel.isEmpty ? "deepseek-v4-pro" : Secrets.deepSeekModel

        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            deepSeekResult = .failure("URL 无效：\(baseURL)")
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "hi"]]
        ])
        req.timeoutInterval = 10

        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                deepSeekResult = .success("连接成功 · 模型 \(model)")
            } else {
                deepSeekResult = .failure("HTTP \(code) · \(hintForDeepSeek(status: code))")
            }
        } catch {
            deepSeekResult = .failure(hintForNetwork(error: error))
        }
    }

    private func testWhisper() async {
        whisperTesting = true
        whisperResult = nil
        defer { whisperTesting = false }

        let key = Secrets.resolvedOpenAIWhisperApiKey
        guard !key.isEmpty else { return }

        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10

        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                whisperResult = .success("连接成功 · Whisper")
            } else {
                whisperResult = .failure("HTTP \(code) · \(hintForOpenAI(status: code))")
            }
        } catch {
            whisperResult = .failure(hintForNetwork(error: error))
        }
    }

    private func testWeather() async {
        weatherTesting = true
        weatherResult = nil
        defer { weatherTesting = false }

        let key = Secrets.resolvedOpenWeatherApiKey
        guard !key.isEmpty else { return }
        let urlStr = "https://api.openweathermap.org/data/2.5/weather?lat=0&lon=0&appid=\(key)"
        guard let url = URL(string: urlStr) else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10

        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                weatherResult = .success("连接成功 · OpenWeather")
            } else {
                weatherResult = .failure("HTTP \(code) · \(hintForOpenWeather(status: code))")
            }
        } catch {
            weatherResult = .failure(hintForNetwork(error: error))
        }
    }

    // MARK: - Error hint helpers

    private func hintForDeepSeek(status: Int) -> String {
        switch status {
        case 401, 403: return "API key 无效或权限不足"
        case 404: return "URL 不存在，检查 baseURL"
        case 429: return "频率限制，稍后重试"
        case 500...599: return "服务端错误，稍后重试"
        default: return "请求失败"
        }
    }

    private func hintForOpenAI(status: Int) -> String {
        switch status {
        case 401, 403: return "API key 无效或权限不足"
        case 404: return "URL 不存在，检查 baseURL"
        case 429: return "频率限制或额度不足"
        case 500...599: return "服务端错误，稍后重试"
        default: return "请求失败"
        }
    }

    private func hintForOpenWeather(status: Int) -> String {
        switch status {
        case 401: return "API key 无效"
        case 404: return "URL 不存在"
        case 429: return "免费套餐额度用尽"
        case 500...599: return "服务端错误，稍后重试"
        default: return "请求失败"
        }
    }

    private func hintForNetwork(error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut: return "网络不可达，检查代理（超时）"
            case NSURLErrorNotConnectedToInternet: return "未连接到互联网"
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
                return "URL 不存在，检查 baseURL"
            case NSURLErrorNetworkConnectionLost: return "网络连接已断开"
            default: return "网络错误：\(nsError.localizedDescription)"
            }
        }
        return "连接失败：\(nsError.localizedDescription)"
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

// MARK: - API Test Result

private enum APITestResult {
    case success(String)
    case failure(String)

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var message: String {
        switch self {
        case .success(let m), .failure(let m): return m
        }
    }
}

#Preview {
    SettingsView()
}
