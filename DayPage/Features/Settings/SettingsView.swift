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
    @AppStorage(AppSettings.Keys.usePressToTalk) private var usePressToTalk: Bool = true

    // API key editing sheet
    @State private var editingKeyName: String = ""
    @State private var editingKeyID: String = ""        // Keychain identifier
    @State private var editingKeyValue: String = ""
    @State private var showApiKeyEditor = false
    @State private var keyRefreshToken: UUID = UUID()   // bump to force apiKeysSection redraw

    // Account sheet
    @EnvironmentObject private var authService: AuthService
    @State private var showAccountSheet = false

    // Data section state
    @State private var vaultSizeLabel: String = "计算中…"
    @State private var showExportAlert = false
    @State private var exportResult: String? = nil

    // Obsidian export
    @State private var isExportingObsidian = false
    @State private var obsidianExportURL: URL? = nil
    @State private var showObsidianShareSheet = false

    // Confirmation dialogs for destructive operations
    @State private var showCleanupConfirm = false
    @State private var showClearSampleConfirm = false

    // Tap-to-copy confirmation for the About → version row.
    // Briefly true after the user taps the version row to copy it to the
    // clipboard, swapping the value for a "已复制" checkmark for ~1.5s.
    @State private var didCopyVersion = false

    var body: some View {
        NavigationStack {
            List {
                accountSection
                apiKeysSection
                aiEngineSection
                permissionsSection
                appearanceSection
                timeZoneSection
                iCloudSyncSection
                dataSection
                aboutSection
            }
            .accessibilityIdentifier("settings-list")
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { dismiss() }
                        .accessibilityLabel(NSLocalizedString("settings.close.label", comment: ""))
                        .accessibilityIdentifier("settings-close-button")
                }
            }
            .onAppear { computeVaultSize() }
            .bannerOverlay()
            .sheet(isPresented: $showAccountSheet) {
                AccountSheet()
            }
            .sheet(isPresented: $showApiKeyEditor) {
                apiKeyEditorSheet
            }
            .sheet(isPresented: $showObsidianShareSheet, onDismiss: {
                obsidianExportURL = nil
            }) {
                if let url = obsidianExportURL {
                    ShareSheet(activityItems: [url])
                        .ignoresSafeArea()
                }
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
                    .padding(DSSpacing.md)
                    .background(DSColor.glassLo)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous)
                            .strokeBorder(DSColor.glassRim, lineWidth: 0.5)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous))
                    .padding(.horizontal)

                HStack {
                    Button("粘贴") {
                        if let s = UIPasteboard.general.string { editingKeyValue = s }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(NSLocalizedString("settings.apikey.paste.label", comment: ""))
                    .accessibilityIdentifier("api-key-paste-button")

                    Spacer()

                    Button("清除") {
                        editingKeyValue = ""
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .accessibilityLabel(NSLocalizedString("settings.apikey.clear.label", comment: ""))
                    .accessibilityIdentifier("api-key-clear-button")
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
                        // Trim whitespace AND newlines — pasted API keys frequently
                        // carry a trailing `\n` from the source (terminal copy,
                        // password manager export), which silently makes the
                        // Authorization header invalid (`Bearer sk-…\n`) and the
                        // request 401s with no clue why.
                        let trimmed = editingKeyValue
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty {
                            KeychainHelper.deleteAPIKey(for: editingKeyID)
                        } else {
                            KeychainHelper.setAPIKey(trimmed, for: editingKeyID)
                        }
                        keyRefreshToken = UUID()
                        showApiKeyEditor = false
                    }
                    .fontWeight(.semibold)
                    .accessibilityLabel(NSLocalizedString("settings.apikey.save.label", comment: ""))
                    .accessibilityIdentifier("api-key-save-button")
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Account Section

    /// Top-of-list row that surfaces the signed-in account and opens the
    /// existing `AccountSheet` for sign-in / sign-out actions. Added when
    /// the account avatar was removed from the Today header (#US-004) but
    /// the corresponding `accountSection` view was never landed.
    private var accountSection: some View {
        Section("账号") {
            Button {
                showAccountSheet = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle")
                        .font(DSType.h2)
                        .foregroundColor(DSColor.onSurfaceVariant)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(authService.session?.user.email ?? "未登录")
                            .font(DSType.bodyMD)
                            .foregroundColor(DSColor.onBackgroundPrimary)
                        Text(authService.session == nil ? "点击登录" : "管理账号")
                            .font(DSType.labelSM)
                            .foregroundColor(DSColor.onSurfaceVariant)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(DSType.caption)
                        .foregroundColor(DSColor.onSurfaceVariant)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - API Keys Section

    private var apiKeysSection: some View {
        Section("API Keys") {
            let _ = keyRefreshToken  // read token so SwiftUI re-evaluates when key is saved
            apiKeyRow(
                name: "DeepSeek",
                keychainID: "deepSeekApiKey",
                key: Secrets.resolvedDeepSeekApiKey,
                isTesting: deepSeekTesting,
                result: deepSeekResult,
                onTest: { Task { await testDeepSeek() } },
                providerID: "deepseek"
            )
            apiKeyRow(
                name: "OpenAI Whisper",
                keychainID: "openAIWhisperApiKey",
                key: Secrets.resolvedOpenAIWhisperApiKey,
                isTesting: whisperTesting,
                result: whisperResult,
                onTest: { Task { await testWhisper() } },
                providerID: "whisper"
            )
            apiKeyRow(
                name: "OpenWeatherMap",
                keychainID: "openWeatherApiKey",
                key: Secrets.resolvedOpenWeatherApiKey,
                isTesting: weatherTesting,
                result: weatherResult,
                onTest: { Task { await testWeather() } },
                providerID: "openweather"
            )
        }
    }

    @ViewBuilder
    private func apiKeyRow(
        name: String,
        keychainID: String,
        key: String,
        isTesting: Bool,
        result: APITestResult?,
        onTest: @escaping () -> Void,
        providerID: String = ""
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
                            .font(DSType.labelSM)
                            .foregroundColor(DSColor.onSurfaceVariant)
                    }
                }
                Spacer()
                // Edit button — always visible
                Button {
                    editingKeyName = name
                    editingKeyID = keychainID
                    editingKeyValue = KeychainHelper.getAPIKey(for: keychainID) ?? ""
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
                    .accessibilityLabel(NSLocalizedString("settings.apikey.test.label", comment: ""))
                    .accessibilityIdentifier("api-key-test-button-\(providerID)")
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
        Section {
            // Live preview — re-renders as the pickers below change so the
            // abstract font-size / density / accent choices become tangible
            // without leaving Settings. (#appearance-preview)
            appearancePreviewCard

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
            .onChange(of: appSettings.themeMode) { _ in Haptics.soft() }

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
            .onChange(of: appSettings.accentColor) { _ in Haptics.soft() }

            // Font size adjustment
            Picker(selection: $appSettings.fontSizeAdjust) {
                ForEach(FontSizeAdjust.allCases, id: \.self) { adjust in
                    Text(adjust.label).tag(adjust)
                }
            } label: {
                Label("正文字号", systemImage: "textformat.size")
            }
            .onChange(of: appSettings.fontSizeAdjust) { _ in Haptics.soft() }

            // Card density
            Picker(selection: $appSettings.cardDensity) {
                ForEach(CardDensity.allCases, id: \.self) { density in
                    Text(density.label).tag(density)
                }
            } label: {
                Label("卡片密度", systemImage: "rectangle.expand.vertical")
            }
            .onChange(of: appSettings.cardDensity) { _ in Haptics.soft() }

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
            .accessibilityIdentifier("onthisday-enabled-toggle")
            .onChange(of: onThisDayEnabled) { val in
                OnThisDayScheduler.shared.isEnabled = val
            }

            if onThisDayEnabled {
                Picker("刷新时间", selection: $onThisDayRefreshHour) {
                    Text("午夜 00:00").tag(0)
                    Text("清晨 06:00").tag(6)
                    Text("上午 09:00").tag(9)
                }
                .accessibilityIdentifier("onthisday-refresh-hour-picker")
                .onChange(of: onThisDayRefreshHour) { val in
                    OnThisDayScheduler.shared.refreshHour = val
                }
            }
        } header: {
            Text("外观")
        }
    }

    // MARK: - Appearance Preview

    /// A miniature memo card that mirrors the real card aesthetic (mono kicker
    /// + serif title + body) and re-renders live as the appearance pickers
    /// change. `bodyMDStyle()` / `bodySMStyle()` read `fontSizeAdjust` and
    /// `cardDensity` from `AppSettings.shared`, so adjusting either control
    /// updates this card immediately; the accent picker tints the kicker + dot.
    private var appearancePreviewCard: some View {
        let accent = appSettings.accentColor.color
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(accent)
                    .frame(width: 6, height: 6)
                Text("预览 · 14:30")
                    .font(DSType.mono10)
                    .tracking(1.0)
                    .textCase(.uppercase)
                    .foregroundColor(accent)
            }
            Text("一杯手冲，窗外是慢下来的城市。")
                .bodyMDStyle()
                .foregroundColor(DSColor.onBackgroundPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("调整下方字号与卡片密度，这张卡片会实时变化。")
                .bodySMStyle()
                .foregroundColor(DSColor.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(DSColor.glassLo)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                .strokeBorder(accent.opacity(0.18), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
        .padding(.vertical, 2)
        .animation(Motion.fade, value: appSettings.fontSizeAdjust)
        .animation(Motion.fade, value: appSettings.cardDensity)
        .animation(Motion.fade, value: appSettings.accentColor)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(NSLocalizedString("settings.appearance.preview.a11y", comment: "Appearance preview card accessibility label"))
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
            .accessibilityLabel(NSLocalizedString("settings.rollback.label", comment: ""))
            .accessibilityHint(NSLocalizedString("settings.rollback.hint", comment: ""))
            .accessibilityIdentifier("settings-rollback-button")
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
            Button(role: .destructive, action: { showCleanupConfirm = true }) {
                Label("清理本地备份", systemImage: "trash")
            }
            .accessibilityLabel(NSLocalizedString("settings.cleanup_backup.label", comment: ""))
            .accessibilityHint(NSLocalizedString("settings.cleanup_backup.hint", comment: ""))
            .accessibilityIdentifier("settings-cleanup-backup-button")
            .confirmationDialog(
                "确认清理本地备份？",
                isPresented: $showCleanupConfirm,
                titleVisibility: .visible
            ) {
                Button("清理备份", role: .destructive, action: cleanupLocalBackup)
                Button("取消", role: .cancel) {}
            } message: {
                Text("本地备份将被永久删除，此操作无法撤销。")
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
                Label("前往 Archive 页面导出", systemImage: "archivebox")
            }
            .foregroundColor(DSColor.onSurfaceVariant)

            Button(action: { Task { await exportObsidianVault() } }) {
                if isExportingObsidian {
                    HStack {
                        Label("导出中…", systemImage: "square.and.arrow.up")
                        Spacer()
                        ProgressView().scaleEffect(0.8)
                    }
                } else {
                    Label("导出日记 (Obsidian 兼容)", systemImage: "square.and.arrow.up")
                }
            }
            .disabled(isExportingObsidian)

            if SampleDataSeeder.hasSeededSamples {
                Button(role: .destructive, action: { showClearSampleConfirm = true }) {
                    Label("清除示例数据", systemImage: "trash")
                }
                .accessibilityLabel(NSLocalizedString("settings.clear_sample.label", comment: ""))
                .accessibilityHint(NSLocalizedString("settings.clear_sample.hint", comment: ""))
                .accessibilityIdentifier("settings-clear-sample-button")
                .confirmationDialog(
                    "确认清除示例数据？",
                    isPresented: $showClearSampleConfirm,
                    titleVisibility: .visible
                ) {
                    Button("清除", role: .destructive) {
                        SampleDataSeeder.clearSampleData()
                        bannerCenter.show(AppBannerModel(
                            kind: .success,
                            title: "示例数据已清除",
                            autoDismiss: true
                        ))
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("所有示例数据将被永久删除，此操作无法撤销。")
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
            // Tap to copy "DayPage <version> (<build>)" to the clipboard, so the
            // exact version can be pasted into a support request or bug report.
            Button(action: copyVersionInfo) {
                HStack {
                    Text("版本")
                        .foregroundColor(DSColor.onSurface)
                    Spacer()
                    if didCopyVersion {
                        Label("已复制", systemImage: "checkmark")
                            .labelStyle(.titleAndIcon)
                            .foregroundColor(DSColor.accentAmber)
                            .font(.caption)
                            .transition(.opacity)
                    } else {
                        Text(appVersion)
                            .foregroundColor(DSColor.onSurfaceVariant)
                            .font(.caption)
                            .transition(.opacity)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint(NSLocalizedString("settings.about.version.copy_hint", comment: "Tap to copy version hint"))
            HStack {
                Text("Build")
                Spacer()
                Text(buildNumber)
                    .foregroundColor(DSColor.onSurfaceVariant)
                    .font(.caption)
            }
        }
    }

    /// Copies "DayPage <version> (<build>)" to the clipboard and shows a brief
    /// "已复制" confirmation on the version row.
    private func copyVersionInfo() {
        UIPasteboard.general.string = "DayPage \(appVersion) (\(buildNumber))"
        Haptics.success()
        withAnimation(Motion.fade) { didCopyVersion = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(Motion.fade) { didCopyVersion = false }
        }
    }

    // MARK: - AI Engine Section (US-014)

    private var aiEngineSection: some View {
        Section {
            // Model name (read-only)
            HStack {
                Label(NSLocalizedString("settings.ai.model", comment: ""), systemImage: "cpu")
                Spacer()
                Text(aiModelName)
                    .foregroundColor(DSColor.onSurfaceVariant)
                    .font(DSType.labelSM)
            }
            // Provider name (read-only)
            HStack {
                Label(NSLocalizedString("settings.ai.provider", comment: ""), systemImage: "server.rack")
                Spacer()
                Text(aiProviderName)
                    .foregroundColor(DSColor.onSurfaceVariant)
                    .font(DSType.labelSM)
            }
            // Endpoint (read-only, truncated)
            HStack {
                Label(NSLocalizedString("settings.ai.endpoint", comment: ""), systemImage: "network")
                Spacer()
                Text(aiEndpointDisplay)
                    .foregroundColor(DSColor.onSurfaceVariant)
                    .font(DSType.labelSM)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } header: {
            Text(NSLocalizedString("settings.ai.section_title", comment: ""))
        } footer: {
            Text(NSLocalizedString("settings.ai.footer", comment: ""))
                .font(.caption)
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
            // Count daily entries: files directly under vault/raw/ named
            // YYYY-MM-DD.md (one per logged day). Assets and other dirs excluded.
            let rawURL = vaultURL.appendingPathComponent("raw")
            var dayCount = 0
            if let enumerator = fm.enumerator(at: vaultURL, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let fileURL as URL in enumerator {
                    let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    totalBytes += Int64(size)
                    if fileURL.deletingLastPathComponent().path == rawURL.path,
                       Self.isDayFileName(fileURL.lastPathComponent) {
                        dayCount += 1
                    }
                }
            }
            let sizeLabel = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            // Surface the entry count alongside size so users see how much
            // they've logged at a glance, e.g. "12 天 · 1.2 MB".
            let label = dayCount > 0 ? "\(dayCount) 天 · \(sizeLabel)" : sizeLabel
            await MainActor.run { self.vaultSizeLabel = label }
        }
    }

    /// True for a raw day-file name of the form `YYYY-MM-DD.md`.
    private static func isDayFileName(_ name: String) -> Bool {
        guard name.hasSuffix(".md") else { return false }
        let stem = String(name.dropLast(3))
        let parts = stem.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2 else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    private func exportAll() {
        // Export is not implemented here; direct the user to the Archive tab.
        exportResult = "请前往 Archive 页面使用导出功能"
        bannerCenter.show(.init(kind: .info, title: "导出功能在 Archive 页面可用"))
    }

    // MARK: - Obsidian Export

    private func exportObsidianVault() async {
        isExportingObsidian = true
        defer { isExportingObsidian = false }

        let result = await Task.detached(priority: .userInitiated) {
            ObsidianExporter.buildZip()
        }.value

        switch result {
        case .success(let zipURL):
            obsidianExportURL = zipURL
            showObsidianShareSheet = true
        case .failure(let error):
            bannerCenter.show(.init(kind: .error, title: "导出失败：\(error.localizedDescription)", autoDismiss: true))
        }
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

    private var aiModelName: String {
        Secrets.deepSeekModel.isEmpty ? "deepseek-v4-pro" : Secrets.deepSeekModel
    }

    private var aiProviderName: String {
        let base = Secrets.deepSeekBaseURL
        if base.contains("dashscope") { return "Aliyun DashScope" }
        if base.contains("deepseek") { return "DeepSeek" }
        if base.isEmpty { return "DeepSeek" }
        return "Custom"
    }

    private var aiEndpointDisplay: String {
        let base = Secrets.deepSeekBaseURL
        return base.isEmpty ? "https://api.deepseek.com/v1" : base
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

// MARK: - ShareSheet

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - ObsidianExporter

/// Builds an Obsidian-compatible Markdown ZIP from vault/wiki/daily/*.md.
/// Runs on a background thread; returns the temporary zip URL on success.
enum ObsidianExporter {

    static func buildZip() -> Result<URL, Error> {
        let fm = FileManager.default
        let dailyDir = VaultInitializer.vaultURL
            .appendingPathComponent("wiki")
            .appendingPathComponent("daily")

        // Gather daily pages
        let pages: [URL]
        do {
            pages = try fm.contentsOfDirectory(at: dailyDir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "md" && !$0.lastPathComponent.hasPrefix(".") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            return .failure(error)
        }

        guard !pages.isEmpty else {
            return .failure(NSError(domain: "ObsidianExporter", code: 1,
                                   userInfo: [NSLocalizedDescriptionKey: "没有已编译的日记页面可导出"]))
        }

        // Build a temporary directory containing all pages
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("daypage_export_\(Int(Date().timeIntervalSince1970))")
        let docsDir = tmpDir.appendingPathComponent("DayPage")
        let dailyOutDir = docsDir.appendingPathComponent("Daily")
        do {
            try fm.createDirectory(at: dailyOutDir, withIntermediateDirectories: true)
        } catch {
            return .failure(error)
        }

        // Copy and add Obsidian-compatible frontmatter aliases
        for page in pages {
            guard var content = try? String(contentsOf: page, encoding: .utf8) else { continue }
            // Inject aliases field into frontmatter for Obsidian link resolution
            content = injectObsidianAlias(into: content, filename: page.deletingPathExtension().lastPathComponent)
            let dest = dailyOutDir.appendingPathComponent(page.lastPathComponent)
            try? content.write(to: dest, atomically: true, encoding: .utf8)
        }

        // Also copy the wiki index if it exists
        let indexSrc = VaultInitializer.vaultURL.appendingPathComponent("wiki/index.md")
        if fm.fileExists(atPath: indexSrc.path) {
            try? fm.copyItem(at: indexSrc, to: docsDir.appendingPathComponent("index.md"))
        }

        // Share the directory directly — UIActivityViewController accepts a folder URL,
        // iOS will offer it as a zip when sharing via Files/AirDrop/etc.
        return .success(docsDir)
    }

    private static func injectObsidianAlias(into content: String, filename: String) -> String {
        guard content.hasPrefix("---") else { return content }
        let lines = content.components(separatedBy: "\n")
        var result: [String] = []
        var injected = false
        var inFrontmatter = false

        for (i, line) in lines.enumerated() {
            if i == 0 && line.trimmingCharacters(in: .whitespaces) == "---" {
                inFrontmatter = true
                result.append(line)
                continue
            }
            if inFrontmatter && line.trimmingCharacters(in: .whitespaces) == "---" {
                if !injected {
                    result.append("aliases: [\"\(filename)\"]")
                    injected = true
                }
                inFrontmatter = false
            }
            result.append(line)
        }
        return result.joined(separator: "\n")
    }
}

#Preview {
    SettingsView()
}
