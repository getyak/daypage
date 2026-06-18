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
    @State private var vaultSizeLabel: String = NSLocalizedString("settings.data.vault.computing", comment: "")
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
            .navigationTitle(NSLocalizedString("settings.nav.title", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("settings.nav.close", comment: "")) { dismiss() }
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
                Text(String(format: NSLocalizedString("settings.apikey.editor.title", comment: ""), editingKeyName))
                    .font(.headline)
                    .padding(.top, 8)

                SecureField(NSLocalizedString("settings.apikey.editor.placeholder", comment: ""), text: $editingKeyValue)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(DSSpacing.md)
                    // #771: API-key field → glass engine (.control). Engine owns rim.
                    .dpGlass(.control, in: RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous))
                    .padding(.horizontal)

                HStack {
                    Button(NSLocalizedString("settings.apikey.editor.paste", comment: "")) {
                        if let s = UIPasteboard.general.string { editingKeyValue = s }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(NSLocalizedString("settings.apikey.paste.label", comment: ""))
                    .accessibilityIdentifier("api-key-paste-button")

                    Spacer()

                    Button(NSLocalizedString("settings.apikey.editor.clear", comment: "")) {
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
            .navigationTitle(NSLocalizedString("settings.apikey.editor.nav.title", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("settings.apikey.editor.cancel", comment: "")) { showApiKeyEditor = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("settings.apikey.editor.save", comment: "")) {
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
        Section(NSLocalizedString("settings.account.section", comment: "")) {
            Button {
                showAccountSheet = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle")
                        .font(DSType.h2)
                        .foregroundColor(DSColor.onSurfaceVariant)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(authService.session?.user.email ?? NSLocalizedString("settings.account.signed_out", comment: ""))
                            .font(DSType.bodyMD)
                            .foregroundColor(DSColor.onBackgroundPrimary)
                        Text(authService.session == nil ? NSLocalizedString("settings.account.tap_to_sign_in", comment: "") : NSLocalizedString("settings.account.manage", comment: ""))
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
                providerID: "openweather",
                isRequired: false
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
        providerID: String = "",
        isRequired: Bool = true
    ) -> some View {
        let badgeColor: Color = isRequired ? .red : DSColor.inkSubtle
        let badgeLabel = isRequired
            ? NSLocalizedString("settings.apikey.unconfigured", comment: "")
            : NSLocalizedString("settings.apikey.optional", comment: "")
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.body)
                    if key.isEmpty {
                        Text(badgeLabel)
                            .font(.caption)
                            .foregroundColor(badgeColor)
                    } else {
                        Text("…" + String(key.suffix(4)))
                            .font(DSType.labelSM)
                            .foregroundColor(DSColor.onSurfaceVariant)
                    }
                }
                Spacer()
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
                    Text(badgeLabel)
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(badgeColor.opacity(0.12))
                        .foregroundColor(badgeColor)
                        .clipShape(Capsule())
                } else {
                    Button(action: onTest) {
                        if isTesting {
                            ProgressView().controlSize(.mini)
                        } else {
                            Text(NSLocalizedString("settings.apikey.test_connection", comment: ""))
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
                        .foregroundColor(result.isSuccess ? DSColor.statusSuccess : DSColor.statusError)
                    Text(result.message)
                        .font(.caption)
                        .foregroundColor(result.isSuccess ? DSColor.statusSuccess : DSColor.statusError)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Permissions Section

    private var permissionsSection: some View {
        Section(NSLocalizedString("settings.permission.section", comment: "")) {
            // Microphone
            HStack {
                Label(NSLocalizedString("settings.permission.mic", comment: ""), systemImage: "mic.fill")
                Spacer()
                micStatusView
            }
            .contentShape(Rectangle())
            .onTapGesture { openSettings() }

            // Location
            HStack {
                Label(NSLocalizedString("settings.permission.location", comment: ""), systemImage: "location.fill")
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
                        Text(NSLocalizedString("settings.permission.passive.enabled", comment: ""))
                        Text(NSLocalizedString("settings.permission.passive.subtitle", comment: ""))
                            .font(.caption)
                            .foregroundColor(DSColor.onSurfaceVariant)
                    }
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(DSColor.statusSuccess)
                }
            } else {
                Button(action: { locationService.requestAlwaysAuthorization() }) {
                    Label(NSLocalizedString("settings.permission.passive.enable_button", comment: ""), systemImage: "location.circle")
                }
            }
        }
    }

    @ViewBuilder
    private var micStatusView: some View {
        let status = AVAudioSession.sharedInstance().recordPermission
        switch status {
        case .granted:
            Text(NSLocalizedString("settings.permission.mic.granted", comment: "")).font(.caption).foregroundColor(DSColor.statusSuccess)
        case .denied:
            Text(NSLocalizedString("settings.permission.mic.denied", comment: "")).font(.caption).foregroundColor(DSColor.statusError)
        default:
            Text(NSLocalizedString("settings.permission.mic.undetermined", comment: "")).font(.caption).foregroundColor(DSColor.statusWarning)
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
                Label(NSLocalizedString("settings.appearance.darkmode", comment: ""), systemImage: "moon.fill")
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
                Label(NSLocalizedString("settings.appearance.accent", comment: ""), systemImage: "paintpalette")
            }
            .onChange(of: appSettings.accentColor) { _ in Haptics.soft() }

            // Font size adjustment
            Picker(selection: $appSettings.fontSizeAdjust) {
                ForEach(FontSizeAdjust.allCases, id: \.self) { adjust in
                    Text(adjust.label).tag(adjust)
                }
            } label: {
                Label(NSLocalizedString("settings.appearance.fontsize", comment: ""), systemImage: "textformat.size")
            }
            .onChange(of: appSettings.fontSizeAdjust) { _ in Haptics.soft() }

            // Card density
            Picker(selection: $appSettings.cardDensity) {
                ForEach(CardDensity.allCases, id: \.self) { density in
                    Text(density.label).tag(density)
                }
            } label: {
                Label(NSLocalizedString("settings.appearance.density", comment: ""), systemImage: "rectangle.expand.vertical")
            }
            .onChange(of: appSettings.cardDensity) { _ in Haptics.soft() }

            // Press-to-talk (US-008). Invert the binding so the visible label reads
            // "Use legacy voice recording" per the PRD's legacy-fallback copy.
            Toggle(isOn: Binding(
                get: { !usePressToTalk },
                set: { usePressToTalk = !$0 }
            )) {
                Label(NSLocalizedString("settings.appearance.legacy_voice", comment: ""), systemImage: "mic.circle")
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
                Picker(NSLocalizedString("settings.appearance.onthisday.refresh_time", comment: ""), selection: $onThisDayRefreshHour) {
                    Text(NSLocalizedString("settings.appearance.onthisday.midnight", comment: "")).tag(0)
                    Text(NSLocalizedString("settings.appearance.onthisday.dawn", comment: "")).tag(6)
                    Text(NSLocalizedString("settings.appearance.onthisday.morning", comment: "")).tag(9)
                }
                .accessibilityIdentifier("onthisday-refresh-hour-picker")
                .onChange(of: onThisDayRefreshHour) { val in
                    OnThisDayScheduler.shared.refreshHour = val
                }
            }
        } header: {
            Text(NSLocalizedString("settings.appearance.section", comment: ""))
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
                Text(NSLocalizedString("settings.appearance.preview.kicker", comment: ""))
                    .font(DSType.mono10)
                    .tracking(1.0)
                    .textCase(.uppercase)
                    .foregroundColor(accent)
            }
            Text(NSLocalizedString("settings.appearance.preview.body", comment: ""))
                .bodyMDStyle()
                .foregroundColor(DSColor.onBackgroundPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(NSLocalizedString("settings.appearance.preview.hint", comment: ""))
                .bodySMStyle()
                .foregroundColor(DSColor.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        // #771: live type-preview card → glass engine (.panel), keeping its
        // dynamic accent emphasis stroke on top.
        .dpGlass(.panel, in: RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
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
                    Label(NSLocalizedString("settings.timezone.preferred", comment: ""), systemImage: "clock.badge.questionmark")
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
                    Label(NSLocalizedString("settings.timezone.reset", comment: ""), systemImage: "arrow.counterclockwise")
                }
            }
        } header: {
            Text(NSLocalizedString("settings.timezone.section", comment: ""))
        } footer: {
            Text(NSLocalizedString("settings.timezone.footer", comment: ""))
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
            Text(NSLocalizedString("settings.icloud.section", comment: ""))
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
                    Text(NSLocalizedString("settings.icloud.connected", comment: "")).font(.body).fontWeight(.medium)
                    Text(L10n.Settings.iCloudDrive).font(.caption).foregroundColor(DSColor.onSurfaceVariant)
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
                    Text(NSLocalizedString("settings.icloud.syncing", comment: "")).font(.body).fontWeight(.medium)
                    Text(String(format: NSLocalizedString("settings.icloud.pending_files", comment: ""), pendingFiles))
                        .font(.caption)
                        .foregroundColor(DSColor.onSurfaceVariant)
                }
            }

        case .error(let message):
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(NSLocalizedString("settings.icloud.error", comment: "")).font(.body).fontWeight(.medium).foregroundColor(.red)
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
                    Text(NSLocalizedString("settings.icloud.enable.title", comment: ""))
                        .font(.body)
                        .fontWeight(.semibold)
                    Text(NSLocalizedString("settings.icloud.enable.subtitle", comment: ""))
                        .font(.caption)
                        .foregroundColor(DSColor.onSurfaceVariant)
                }
            }
            Button(action: openSettings) {
                Label(NSLocalizedString("settings.icloud.enable.button", comment: ""), systemImage: "arrow.up.right.square")
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
                Text(NSLocalizedString("settings.icloud.attachment.ondemand", comment: "")).tag(AttachmentPolicy.onDemand)
                Text(NSLocalizedString("settings.icloud.attachment.alwayslocal", comment: "")).tag(AttachmentPolicy.alwaysLocal)
            } label: {
                Label(NSLocalizedString("settings.icloud.attachment.policy", comment: ""), systemImage: "square.and.arrow.down")
            }
        }
    }

    @ViewBuilder
    private var rollbackButton: some View {
        if let migratedAt = appSettings.migrationCompletedAt,
           Date().timeIntervalSince(migratedAt) < 30 * 24 * 3600 {
            Button(role: .destructive, action: rollbackToLocal) {
                Label(NSLocalizedString("settings.icloud.rollback.button", comment: ""), systemImage: "arrow.counterclockwise")
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
            title: NSLocalizedString("settings.icloud.rollback.done", comment: ""),
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
                Label(NSLocalizedString("settings.icloud.cleanup.button", comment: ""), systemImage: "trash")
            }
            .accessibilityLabel(NSLocalizedString("settings.cleanup_backup.label", comment: ""))
            .accessibilityHint(NSLocalizedString("settings.cleanup_backup.hint", comment: ""))
            .accessibilityIdentifier("settings-cleanup-backup-button")
            .confirmationDialog(
                NSLocalizedString("settings.icloud.cleanup.confirm.title", comment: ""),
                isPresented: $showCleanupConfirm,
                titleVisibility: .visible
            ) {
                Button(NSLocalizedString("settings.icloud.cleanup.confirm.action", comment: ""), role: .destructive, action: cleanupLocalBackup)
                Button(NSLocalizedString("settings.common.cancel", comment: ""), role: .cancel) {}
            } message: {
                Text(NSLocalizedString("settings.icloud.cleanup.confirm.message", comment: ""))
            }
        }
    }

    private func cleanupLocalBackup() {
        do {
            try VaultMigrationService.shared.deleteLocalBackup()
            bannerCenter.show(AppBannerModel(
                kind: .info,
                title: NSLocalizedString("settings.icloud.cleanup.done", comment: ""),
                autoDismiss: true
            ))
        } catch {
            bannerCenter.show(AppBannerModel(
                kind: .error,
                title: String(format: NSLocalizedString("settings.icloud.cleanup.failed", comment: ""), error.localizedDescription),
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
        Section(NSLocalizedString("settings.data.section", comment: "")) {
            HStack {
                Label(NSLocalizedString("settings.data.vault_size", comment: ""), systemImage: "internaldrive")
                Spacer()
                Text(vaultSizeLabel)
                    .font(.caption)
                    .foregroundColor(DSColor.onSurfaceVariant)
            }

            Button(action: exportAll) {
                Label(NSLocalizedString("settings.data.export_archive", comment: ""), systemImage: "archivebox")
            }
            .foregroundColor(DSColor.onSurfaceVariant)

            Button(action: { Task { await exportObsidianVault() } }) {
                if isExportingObsidian {
                    HStack {
                        Label(NSLocalizedString("settings.data.exporting", comment: ""), systemImage: "square.and.arrow.up")
                        Spacer()
                        ProgressView().scaleEffect(0.8)
                    }
                } else {
                    Label(NSLocalizedString("settings.data.export_obsidian", comment: ""), systemImage: "square.and.arrow.up")
                }
            }
            .disabled(isExportingObsidian)

            if SampleDataSeeder.hasSeededSamples {
                Button(role: .destructive, action: { showClearSampleConfirm = true }) {
                    Label(NSLocalizedString("settings.data.clear_sample.button", comment: ""), systemImage: "trash")
                }
                .accessibilityLabel(NSLocalizedString("settings.clear_sample.label", comment: ""))
                .accessibilityHint(NSLocalizedString("settings.clear_sample.hint", comment: ""))
                .accessibilityIdentifier("settings-clear-sample-button")
                .confirmationDialog(
                    NSLocalizedString("settings.data.clear_sample.confirm.title", comment: ""),
                    isPresented: $showClearSampleConfirm,
                    titleVisibility: .visible
                ) {
                    Button(NSLocalizedString("settings.data.clear_sample.confirm.action", comment: ""), role: .destructive) {
                        SampleDataSeeder.clearSampleData()
                        bannerCenter.show(AppBannerModel(
                            kind: .success,
                            title: NSLocalizedString("settings.data.clear_sample.done", comment: ""),
                            autoDismiss: true
                        ))
                    }
                    Button(NSLocalizedString("settings.common.cancel", comment: ""), role: .cancel) {}
                } message: {
                    Text(NSLocalizedString("settings.data.clear_sample.confirm.message", comment: ""))
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
        Section(NSLocalizedString("settings.about.section", comment: "")) {
            // Tap to copy "DayPage <version> (<build>)" to the clipboard, so the
            // exact version can be pasted into a support request or bug report.
            Button(action: copyVersionInfo) {
                HStack {
                    Text(NSLocalizedString("settings.about.version", comment: ""))
                        .foregroundColor(DSColor.onSurface)
                    Spacer()
                    if didCopyVersion {
                        Label(NSLocalizedString("settings.about.copied", comment: ""), systemImage: "checkmark")
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
            deepSeekResult = .failure(String(format: NSLocalizedString("settings.test.url_invalid", comment: ""), baseURL))
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
                deepSeekResult = .success(String(format: NSLocalizedString("settings.test.success_model", comment: ""), model))
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
                whisperResult = .success(NSLocalizedString("settings.test.success_whisper", comment: ""))
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
                weatherResult = .success(NSLocalizedString("settings.test.success_weather", comment: ""))
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
        case 401, 403: return NSLocalizedString("settings.test.hint.key_invalid_or_forbidden", comment: "")
        case 404: return NSLocalizedString("settings.test.hint.url_not_found", comment: "")
        case 429: return NSLocalizedString("settings.test.hint.rate_limited", comment: "")
        case 500...599: return NSLocalizedString("settings.test.hint.server_error", comment: "")
        default: return NSLocalizedString("settings.test.hint.request_failed", comment: "")
        }
    }

    private func hintForOpenAI(status: Int) -> String {
        switch status {
        case 401, 403: return NSLocalizedString("settings.test.hint.key_invalid_or_forbidden", comment: "")
        case 404: return NSLocalizedString("settings.test.hint.url_not_found", comment: "")
        case 429: return NSLocalizedString("settings.test.hint.rate_or_quota", comment: "")
        case 500...599: return NSLocalizedString("settings.test.hint.server_error", comment: "")
        default: return NSLocalizedString("settings.test.hint.request_failed", comment: "")
        }
    }

    private func hintForOpenWeather(status: Int) -> String {
        switch status {
        case 401: return NSLocalizedString("settings.test.hint.key_invalid", comment: "")
        case 404: return NSLocalizedString("settings.test.hint.url_not_found_short", comment: "")
        case 429: return NSLocalizedString("settings.test.hint.free_quota_exhausted", comment: "")
        case 500...599: return NSLocalizedString("settings.test.hint.server_error", comment: "")
        default: return NSLocalizedString("settings.test.hint.request_failed", comment: "")
        }
    }

    private func hintForNetwork(error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut: return NSLocalizedString("settings.test.net.timeout", comment: "")
            case NSURLErrorNotConnectedToInternet: return NSLocalizedString("settings.test.net.no_internet", comment: "")
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
                return NSLocalizedString("settings.test.hint.url_not_found", comment: "")
            case NSURLErrorNetworkConnectionLost: return NSLocalizedString("settings.test.net.connection_lost", comment: "")
            default: return String(format: NSLocalizedString("settings.test.net.error", comment: ""), nsError.localizedDescription)
            }
        }
        return String(format: NSLocalizedString("settings.test.net.connect_failed", comment: ""), nsError.localizedDescription)
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
            let label = dayCount > 0 ? String(format: NSLocalizedString("settings.data.vault.days_size", comment: ""), dayCount, sizeLabel) : sizeLabel
            await MainActor.run { self.vaultSizeLabel = label }
        }
    }

    /// True for a raw day-file name of the form `YYYY-MM-DD.md`.
    /// `nonisolated` so it can be called from the detached vault-size task,
    /// which runs off the main actor.
    private nonisolated static func isDayFileName(_ name: String) -> Bool {
        guard name.hasSuffix(".md") else { return false }
        let stem = String(name.dropLast(3))
        let parts = stem.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2 else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    private func exportAll() {
        // Export is not implemented here; direct the user to the Archive tab.
        exportResult = NSLocalizedString("settings.data.export.use_archive", comment: "")
        bannerCenter.show(.init(kind: .info, title: NSLocalizedString("settings.data.export.archive_banner", comment: "")))
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
            bannerCenter.show(.init(kind: .error, title: String(format: NSLocalizedString("settings.data.export.failed", comment: ""), error.localizedDescription), autoDismiss: true))
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
        case .notDetermined: return NSLocalizedString("settings.permission.location.notdetermined", comment: "")
        case .denied: return NSLocalizedString("settings.permission.location.denied", comment: "")
        case .restricted: return NSLocalizedString("settings.permission.location.restricted", comment: "")
        case .authorizedWhenInUse: return NSLocalizedString("settings.permission.location.wheninuse", comment: "")
        case .authorizedAlways: return NSLocalizedString("settings.permission.location.always", comment: "")
        @unknown default: return NSLocalizedString("settings.permission.location.unknown", comment: "")
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
                                   userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("settings.data.export.no_pages", comment: "")]))
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
