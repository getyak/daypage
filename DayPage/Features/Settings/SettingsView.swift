import SwiftUI
import CoreLocation
import AVFoundation
import DayPageStorage
import DayPageServices

// MARK: - ApiKeyKind

/// B2: single source of truth for every API key identifier persisted in the
/// `com.daypage.apikeys` Keychain service. Both the apiKeysSection rows and
/// the `purgeAllLocalData` clear-button consume this so the two cannot drift.
///
/// `rawValue` MUST match the historical identifier strings the rest of the
/// codebase (Onboarding/ApiKeysPage, Secrets resolution helpers) already
/// uses — renaming them would orphan existing user keychain entries.
enum ApiKeyKind: String, CaseIterable {
    case deepSeek         = "deepSeekApiKey"
    case openAIWhisper    = "openAIWhisperApiKey"
    case openWeather      = "openWeatherApiKey"
}

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

    // #785: iOS → Web sync config. Mirrors SyncSettings (UserDefaults baseURL +
    // Keychain API key); edits are committed on submit and re-install the
    // uploader so changes take effect without an app restart.
    @State private var webSyncBaseURL: String = SyncSettings.baseURLString ?? ""
    @State private var webSyncAPIKey: String = SyncSettings.apiKey ?? ""
    @State private var webSyncSaved: Bool = false
    @StateObject private var syncQueue = SyncQueueService.shared

    // Press-to-talk fallback toggle (US-008).
    @AppStorage(AppSettings.Keys.usePressToTalk) private var usePressToTalk: Bool = true

    // C4 fix: master switch for any third-party AI/cloud call (compile, voice
    // transcription). Default true; user can disable to enter "local only" mode.
    @AppStorage(AppSettings.Keys.aiFeaturesEnabled) private var aiFeaturesEnabled: Bool = true

    // Issue #20: 2am 编译完成本地通知开关。Default true.
    // BackgroundCompilationService.sendSuccessNotification 在发送前 guard 此值。
    @AppStorage(AppSettings.Keys.notifyCompile) private var notifyCompile: Bool = true

    // API key editing sheet
    @State private var editingKeyName: String = ""
    @State private var editingKeyID: String = ""        // Keychain identifier
    @State private var editingKeyValue: String = ""
    @State private var showApiKeyEditor = false
    @State private var keyRefreshToken: UUID = UUID()   // bump to force apiKeysSection redraw

    // B1: per-key reveal toggle. Set member = keychainID currently revealed.
    // Default is masked (••••••••); tapping eye flips for one row at a time.
    @State private var revealedKeys: Set<String> = []

    // Account sheet
    @EnvironmentObject private var authService: AuthService
    @State private var showAccountSheet = false

    // Data section state
    @State private var vaultSizeLabel: String = NSLocalizedString("settings.data.vault.computing", comment: "")
    @State private var showExportAlert = false
    @State private var exportResult: String? = nil

    // Obsidian export
    @State private var isExportingObsidian = false
    /// Issue #12: whole-vault zip export (see `exportFullVault`).
    @State private var isExportingFullVault = false
    /// Issue #12: URL of the just-produced vault zip, shown via ShareSheet.
    @State private var fullVaultExportURL: URL? = nil
    /// Issue #6 (2026-07-03): unified error surface using AppError's
    /// three-part contract. Bound below via `.appErrorAlert(...)`.
    @State private var appError: AppError? = nil
    /// Issue #20 (2026-07-03): LLM usage tracker + monthly budget.
    @StateObject private var usageTracker = LLMUsageTracker.shared
    @State private var monthlyBudget: Int = LLMUsageTracker.shared.monthlyBudget
    @State private var obsidianExportURL: URL? = nil
    @State private var showObsidianShareSheet = false

    // Confirmation dialogs for destructive operations
    @State private var showCleanupConfirm = false
    @State private var showClearSampleConfirm = false
    // C3 fix: two-step confirmation for irreversible vault purge.
    @State private var showPurgeAllConfirm = false

    // Tap-to-copy confirmation for the About → version row.
    // Briefly true after the user taps the version row to copy it to the
    // clipboard, swapping the value for a "已复制" checkmark for ~1.5s.
    @State private var didCopyVersion = false

    // R4-MEDIUM #39 — drives the Experiments section toggles.
    @StateObject private var flagStore = FeatureFlagStore.shared

    // R8 — debug toggle for the offline-mode simulation. Flipping this
    // posts `.simulateOfflineChanged` so NetworkMonitor recomputes its
    // published `isOnline` without waiting for a real NWPath update.
    @AppStorage(AppSettings.Keys.debugSimulateOffline) private var simulateOffline: Bool = false

    var body: some View {
        NavigationStack {
            List {
                accountSection
                apiKeysSection
                aiEngineSection
                aiUsageSection
                notificationsSection
                permissionsSection
                appearanceSection
                timeZoneSection
                iCloudSyncSection
                webSyncSection
                dataSection
                experimentsSection
                analyticsDebugSection
                aboutSection
            }
            .appErrorAlert($appError)
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
                keychainID: ApiKeyKind.deepSeek.rawValue,
                key: Secrets.resolvedDeepSeekApiKey,
                isTesting: deepSeekTesting,
                result: deepSeekResult,
                onTest: { Task { await testDeepSeek() } },
                providerID: "deepseek"
            )
            apiKeyRow(
                name: "OpenAI Whisper",
                keychainID: ApiKeyKind.openAIWhisper.rawValue,
                key: Secrets.resolvedOpenAIWhisperApiKey,
                isTesting: whisperTesting,
                result: whisperResult,
                onTest: { Task { await testWhisper() } },
                providerID: "whisper"
            )
            apiKeyRow(
                name: "OpenWeatherMap",
                keychainID: ApiKeyKind.openWeather.rawValue,
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
                        // B1: default render is fully masked + last 2 chars so the
                        // value is recognizable without leaking the secret. The
                        // user can opt in to reveal via the eye button below.
                        let revealed = revealedKeys.contains(keychainID)
                        Text(revealed ? key : "••••••••" + String(key.suffix(2)))
                            .font(DSType.labelSM)
                            .foregroundColor(DSColor.onSurfaceVariant)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .accessibilityIdentifier("api-key-value-\(providerID)")
                    }
                }
                Spacer()

                // B1: eye toggle. Only meaningful once a key exists — hide for
                // empty rows to avoid a dangling icon on first-run state.
                if !key.isEmpty {
                    let revealed = revealedKeys.contains(keychainID)
                    Button {
                        if revealed {
                            revealedKeys.remove(keychainID)
                        } else {
                            revealedKeys.insert(keychainID)
                        }
                    } label: {
                        Image(systemName: revealed ? "eye" : "eye.slash")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(NSLocalizedString("settings.apikey.reveal.label", comment: ""))
                    .accessibilityIdentifier("api-key-reveal-button-\(providerID)")
                }

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

            // Theme (dark mode) — DSPicker to match 日式美术馆 visual language
            DSPicker(
                title: NSLocalizedString("settings.appearance.darkmode", comment: ""),
                selection: $appSettings.themeMode,
                options: ThemeMode.allCases.map { (value: $0, label: $0.label) }
            ) {
                Label(NSLocalizedString("settings.appearance.darkmode", comment: ""), systemImage: "moon.fill")
            }
            .onChange(of: appSettings.themeMode) { _ in Haptics.soft() }

            // Accent color — DSPicker
            DSPicker(
                title: NSLocalizedString("settings.appearance.accent", comment: ""),
                selection: $appSettings.accentColor,
                options: AccentColorOption.allCases.map { (value: $0, label: $0.label) }
            ) {
                Label(NSLocalizedString("settings.appearance.accent", comment: ""), systemImage: "paintpalette")
            }
            .onChange(of: appSettings.accentColor) { _ in Haptics.soft() }

            // Font size adjustment — first SettingsView migration to DSPicker
            // (DSPicker pilot; remaining Pickers below stay native for now).
            DSPicker(
                title: NSLocalizedString("settings.appearance.fontsize", comment: ""),
                selection: $appSettings.fontSizeAdjust,
                options: FontSizeAdjust.allCases.map { (value: $0, label: $0.label) }
            ) {
                Label(NSLocalizedString("settings.appearance.fontsize", comment: ""), systemImage: "textformat.size")
            }
            .onChange(of: appSettings.fontSizeAdjust) { _ in Haptics.soft() }

            // Card density — DSPicker
            DSPicker(
                title: NSLocalizedString("settings.appearance.density", comment: ""),
                selection: $appSettings.cardDensity,
                options: CardDensity.allCases.map { (value: $0, label: $0.label) }
            ) {
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
                Image(systemName: "icloud")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(DSColor.accentOnBg)
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
            DSPicker(
                title: NSLocalizedString("settings.icloud.attachment.policy", comment: ""),
                selection: Binding(
                    get: { appSettings.attachmentPolicy },
                    set: { appSettings.attachmentPolicy = $0 }
                ),
                options: [
                    (value: AttachmentPolicy.onDemand,
                     label: NSLocalizedString("settings.icloud.attachment.ondemand", comment: "")),
                    (value: AttachmentPolicy.alwaysLocal,
                     label: NSLocalizedString("settings.icloud.attachment.alwayslocal", comment: ""))
                ]
            ) {
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

    // MARK: - Web Sync Section (#785)

    /// iOS → Web 同步配置。用户在 web Settings → API Keys 生成 `write` scope
    /// 的 key,这里填 web 地址 + key,App 写的 memo 会自动推送到 web 端。
    private var webSyncSection: some View {
        Section {
            // Web 地址
            HStack {
                Label("Web 地址", systemImage: "globe")
                Spacer()
                TextField("https://daypage.app", text: $webSyncBaseURL)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.URL)
                    .foregroundColor(DSColor.onSurfaceVariant)
                    .accessibilityIdentifier("sync-baseurl-field")
            }

            // API Key（敏感,用 SecureField）
            HStack {
                Label("API Key", systemImage: "key.fill")
                Spacer()
                SecureField("粘贴 web 生成的 key", text: $webSyncAPIKey)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .foregroundColor(DSColor.onSurfaceVariant)
                    .accessibilityIdentifier("sync-apikey-field")
            }

            // 保存 + 立即同步
            Button {
                saveWebSyncConfig()
            } label: {
                HStack {
                    Label(webSyncSaved ? "已保存" : "保存并同步",
                          systemImage: webSyncSaved ? "checkmark.circle.fill" : "arrow.up.circle")
                    Spacer()
                    if SyncSettings.isConfigured {
                        Text("已配置").font(DSType.labelSM).foregroundColor(.green)
                    }
                }
            }
            .accessibilityIdentifier("sync-save-button")

            // 待同步状态
            if syncQueue.pendingCount > 0 {
                HStack {
                    Label("待同步", systemImage: "clock.arrow.circlepath")
                    Spacer()
                    Text("\(syncQueue.pendingCount) 条")
                        .font(DSType.labelSM)
                        .foregroundColor(.orange)
                }
            } else if SyncSettings.isConfigured {
                HStack {
                    Label("已全部同步", systemImage: "checkmark.icloud")
                    Spacer()
                }
                .foregroundColor(DSColor.onSurfaceVariant)
            }
        } header: {
            Text("同步到 Web")
        } footer: {
            Text("在 web 端 设置 → API Keys 生成一个带 write 权限的 key,粘贴到这里。App 写下的 memo 会自动同步到你的 web 账号。")
                .font(.caption)
        }
    }

    /// Commit the sync config to SyncSettings, re-install the uploader, and
    /// kick a flush so any backlog goes out immediately.
    private func saveWebSyncConfig() {
        SyncSettings.baseURLString = webSyncBaseURL
        SyncSettings.apiKey = webSyncAPIKey
        // Reflect normalization back into the field.
        webSyncBaseURL = SyncSettings.baseURLString ?? ""
        SyncQueueObserver.shared.installConfiguredUploader()
        webSyncSaved = true
        Task { await SyncQueueService.shared.flushIfOnline() }
        // Reset the "已保存" affordance after a beat.
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { webSyncSaved = false }
        }
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

            // Issue #12 (2026-07-03): 导出全部 vault (zip). 与 Obsidian
            // export 差异：包含 raw memo 原文、assets 目录、entities、
            // hot cache——用户可以真正"带走全部数据"，符合 backlog #12
            // "隐私说明 + 一键导出"。
            Button(action: { Task { await exportFullVault() } }) {
                if isExportingFullVault {
                    HStack {
                        Label("正在打包全部 vault …", systemImage: "shippingbox")
                        Spacer()
                        ProgressView().scaleEffect(0.8)
                    }
                } else {
                    Label("导出全部 vault (zip)", systemImage: "shippingbox")
                }
            }
            .disabled(isExportingFullVault)
            .accessibilityIdentifier("settings-export-full-vault")

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

            // C3 fix: GDPR right-to-be-forgotten entry. Purges the local vault
            // (raw, wiki, exports), wipes API keys from Keychain, and resets
            // onboarding flags so the user returns to a fresh state. Two-step
            // confirmation is intentional — this is irreversible on-device.
            Button(role: .destructive, action: { showPurgeAllConfirm = true }) {
                Label(NSLocalizedString("settings.data.purge_all.button", comment: "Delete all local data button"),
                      systemImage: "trash.fill")
            }
            .accessibilityIdentifier("settings-purge-all-button")
            .confirmationDialog(
                NSLocalizedString("settings.data.purge_all.confirm.title", comment: ""),
                isPresented: $showPurgeAllConfirm,
                titleVisibility: .visible
            ) {
                Button(NSLocalizedString("settings.data.purge_all.confirm.action", comment: ""), role: .destructive) {
                    purgeAllLocalData()
                }
                Button(NSLocalizedString("settings.common.cancel", comment: ""), role: .cancel) {}
            } message: {
                Text(NSLocalizedString("settings.data.purge_all.confirm.message", comment: ""))
            }

            if let result = exportResult {
                Text(result)
                    .font(.caption)
                    .foregroundColor(DSColor.onSurfaceVariant)
            }
        }
        .onAppear { computeVaultSize() }
    }

    // MARK: - Experiments Section (R4-MEDIUM #39)
    //
    // Renders one Toggle per FeatureFlag.allCases, backed by FeatureFlagStore.
    // Defaults are all "on" so the toggles look pre-checked — flipping a
    // toggle off is the user-facing kill switch for a recent feature.

    private var experimentsSection: some View {
        Section {
            ForEach(FeatureFlag.allCases, id: \.rawValue) { flag in
                Toggle(
                    flag.title,
                    isOn: Binding(
                        get: { flagStore.isEnabled(flag) },
                        set: { flagStore.set(flag, enabled: $0) }
                    )
                )
                .accessibilityIdentifier("experiments-flag-\(flag.rawValue)")
            }

            // R8 — debug-only toggle that forces NetworkMonitor.isOnline=false
            // so the user can verify the SyncQueue banner + offline capture
            // flow without putting the device into airplane mode. We post
            // an explicit notification because @AppStorage doesn't deliver
            // cross-actor KVO reliably under the MainActor model.
            Toggle(NSLocalizedString(
                "settings.experiments.simulate_offline",
                value: "模拟离线模式",
                comment: "Experiments: force NetworkMonitor offline for testing"
            ), isOn: $simulateOffline)
            .accessibilityIdentifier("experiments-simulate-offline")
            .onChange(of: simulateOffline) { _ in
                NotificationCenter.default.post(name: .simulateOfflineChanged, object: nil)
            }
        } header: {
            Text(NSLocalizedString("settings.experiments.section", comment: ""))
        } footer: {
            Text(NSLocalizedString("settings.experiments.footer", comment: ""))
                .font(.caption)
                .foregroundColor(DSColor.onSurfaceVariant)
        }
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
                            .foregroundColor(DSColor.accentOnBg)
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
            // C4 fix: master enable toggle. When off, CompilationService and
            // VoiceService skip every outbound LLM call regardless of API key
            // state — true offline mode without revoking keys.
            Toggle(isOn: $aiFeaturesEnabled) {
                Label(NSLocalizedString("settings.ai.enabled", comment: "AI features master toggle"),
                      systemImage: "sparkles")
            }
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

    // MARK: - Analytics Debug Section (Issue #18 · 2026-07-03)
    //
    // Local product-analytics debug board. Reads the same JSONL
    // AnalyticsService.record writes to, so any redaction we do downstream
    // is visible here first. Deliberately terse — this is a diagnostic
    // surface, not a growth dashboard.

    private var analyticsDebugSection: some View {
        let counts = AnalyticsService.shared.todaysCounts()
        let recent = AnalyticsService.shared.recentEvents(limit: 12).reversed()
        return Section {
            if counts.isEmpty {
                Text("今天还没有事件")
                    .font(DSType.labelSM)
                    .foregroundColor(DSColor.inkSubtle)
            } else {
                ForEach(counts.sorted(by: { $0.key < $1.key }), id: \.key) { (name, count) in
                    HStack {
                        Text(name).font(DSType.labelSM)
                        Spacer()
                        Text("\(count)").font(DSType.labelSM).foregroundColor(DSColor.onSurfaceVariant)
                    }
                }
            }
            if !recent.isEmpty {
                DisclosureGroup("最近 \(recent.count) 条事件") {
                    ForEach(Array(recent.enumerated()), id: \.offset) { _, evt in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(evt.name).font(DSType.labelSM)
                            Text(evt.at).font(DSType.mono9).foregroundColor(DSColor.inkSubtle)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            Button(role: .destructive) {
                AnalyticsService.shared.reset()
            } label: {
                Label("清空调试事件", systemImage: "trash")
            }
        } header: {
            Text("调试看板 · 事件流")
        } footer: {
            Text("显示 vault/.analytics/events.jsonl 里今天的事件计数与最近 12 条。仅本机可见。")
                .font(.caption)
        }
    }

    // MARK: - AI Usage Section (Issue #20 · 2026-07-03)
    //
    // Renders the current month's approximate LLM token spend (chars/4),
    // a monthly budget stepper, and an inline banner when we've crossed
    // 80% of it. The tracker lives in DayPageKit so both foreground and
    // background compiles feed the same bucket; this view just presents.

    private var aiUsageSection: some View {
        Section {
            let usage = usageTracker.currentMonthUsage()
            HStack {
                Label("本月累计 (估算)", systemImage: "gauge.with.needle")
                Spacer()
                Text("\(usage.totalTokens) tokens")
                    .foregroundColor(DSColor.onSurfaceVariant)
                    .font(DSType.labelSM)
            }
            HStack {
                Label("活跃天数", systemImage: "calendar")
                Spacer()
                Text("\(usage.daysWithActivity) / 30")
                    .foregroundColor(DSColor.onSurfaceVariant)
                    .font(DSType.labelSM)
            }
            Stepper(value: $monthlyBudget, in: 0...5_000_000, step: 50_000) {
                HStack {
                    Label("月度上限", systemImage: "target")
                    Spacer()
                    Text(monthlyBudget == 0 ? "未设置" : "\(monthlyBudget)")
                        .foregroundColor(DSColor.onSurfaceVariant)
                        .font(DSType.labelSM)
                }
            }
            .onChange(of: monthlyBudget) { newValue in
                usageTracker.monthlyBudget = newValue
            }
            if usageTracker.hasCrossedBudgetWarning {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(DSColor.accentOnBg)
                    Text("已经用掉本月预算的 80% —— 可以考虑调低编译频率或提高上限。")
                        .font(DSType.labelSM)
                        .foregroundColor(DSColor.inkPrimary)
                }
                .padding(8)
                .background(DSColor.amberSoft)
                .cornerRadius(8)
                .accessibilityIdentifier("settings.ai.usage.warning")
            }
        } header: {
            Text("AI 用量")
        } footer: {
            Text("按 tokens ≈ 字符数 / 4 估算，涵盖 daily 编译、weekly 回顾、追问过去等所有 LLM 调用。数据仅保存在设备本地。")
                .font(.caption)
        }
    }

    // MARK: - Notifications Section (Issue #20)

    private var notificationsSection: some View {
        Section {
            Toggle(isOn: $notifyCompile) {
                Label(
                    NSLocalizedString(
                        "settings.notifications.compile",
                        value: "编译完成通知",
                        comment: "Toggle: send a local notification once nightly Daily Page compile finishes"
                    ),
                    systemImage: "bell.badge"
                )
            }
        } header: {
            Text(NSLocalizedString(
                "settings.notifications.section_title",
                value: "通知",
                comment: "Settings section title for local-notification controls"
            ))
        } footer: {
            Text(NSLocalizedString(
                "settings.notifications.footer",
                value: "凌晨 2:00 后台自动编译完成时，会发本地通知到锁屏。",
                comment: "Footer explaining when the compile-complete notification fires"
            ))
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

        guard let endpoint = URL(string: "https://api.openai.com/v1/models") else { return }
        var req = URLRequest(url: endpoint)
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

    // C3 fix (GDPR right-to-be-forgotten): wipe local user-generated state.
    // Scope is intentionally local-only — cloud account deletion (Supabase) is
    // a separate flow and out of scope for this entry point, so this is named
    // "Delete All Local Data" in copy. Includes:
    //   • the vault directory (raw memos, wiki, exports)
    //   • all API keys in Keychain (com.daypage.apikeys)
    //   • onboarding / engagement flags so the user starts fresh
    private func purgeAllLocalData() {
        let fm = FileManager.default
        var failures: [String] = []

        // 1. Vault directory.
        let vaultURL = VaultInitializer.vaultURL
        if fm.fileExists(atPath: vaultURL.path) {
            do {
                try fm.removeItem(at: vaultURL)
            } catch {
                failures.append("vault: \(error.localizedDescription)")
            }
        }

        // 2. API keys in Keychain. B2: drive off ApiKeyKind so this can never
        // drift from apiKeysSection again. Previously this passed the wrong
        // identifiers ("deepseek" instead of "deepSeekApiKey"), so the
        // "Delete All Local Data" button silently left every API key behind.
        for kind in ApiKeyKind.allCases {
            KeychainHelper.deleteAPIKey(for: kind.rawValue)
        }

        // 3. UserDefaults — reset onboarding + engagement keys. Targeted rather
        // than removePersistentDomain so we don't nuke Apple-managed defaults.
        let store = UserDefaults.standard
        let keysToReset: [String] = [
            AppSettings.Keys.hasOnboarded,
            AppSettings.Keys.authSkipped,
            AppSettings.Keys.dataFlowDisclosureAcceptedAt,
            AppSettings.Keys.memoSaveCount,
            AppSettings.Keys.lastSyncBannerDate,
            AppSettings.Keys.onThisDayDismissed,
            AppSettings.Keys.dailyPageSwipeHintShown,
            AppSettings.Keys.writeSheetRailHintShown,
            AppSettings.Keys.memoSwipeHintShown,
            AppSettings.Keys.streakMilestonesShown,
            AppSettings.Keys.exportLongPressHintShown,
            AppSettings.Keys.summaryCopyHintShown,
            AppSettings.Keys.migrationCompletedAt,
            AppSettings.Keys.graphHiddenTypes,
        ]
        for key in keysToReset { store.removeObject(forKey: key) }

        // 4. Surface result. On failure, the user should know what survived so
        // they can decide whether to retry or escalate. On success, F7: hold
        // the banner (no auto-dismiss) and remind the user that this is a
        // local-only purge — cloud account deletion is a separate flow.
        if failures.isEmpty {
            bannerCenter.show(AppBannerModel(
                kind: .success,
                title: NSLocalizedString("settings.data.purge_all.done", comment: ""),
                subtitle: NSLocalizedString("settings.data.purge_all.done.subtitle",
                                            comment: "Hint that cloud account stays + restart suggestion"),
                autoDismiss: false
            ))
        } else {
            bannerCenter.show(AppBannerModel(
                kind: .error,
                title: NSLocalizedString("settings.data.purge_all.partial", comment: ""),
                subtitle: failures.joined(separator: " · "),
                autoDismiss: false
            ))
        }
    }

    // MARK: - Obsidian Export

    // MARK: - Issue #12 · 全 vault 一键导出 (2026-07-03)

    /// Uses `VaultExportService.exportVaultZip(.all)` — this is the
    /// canonical Kit-side helper, unlike `ObsidianExporter` which is
    /// tailored for Obsidian's markdown-only workflow. On success we hand
    /// the zip to the system share sheet through `fullVaultExportURL`.
    private func exportFullVault() async {
        isExportingFullVault = true
        defer { isExportingFullVault = false }
        do {
            let zip = try await VaultExportService.shared.exportVaultZip(includes: .all)
            fullVaultExportURL = zip
            showObsidianShareSheet = true
            obsidianExportURL = zip
        } catch {
            // Issue #6 (2026-07-03) — migrate from a naked banner to the
            // AppError three-part contract (what happened / why / what to
            // do). Retry actually retries the export instead of asking the
            // user to hunt for the button again.
            appError = AppError(
                title: "全 vault 导出失败",
                reason: "\(error.localizedDescription) — 磁盘空间不足或 iCloud 正在同步时最常见。",
                primary: AppError.Action(label: "再试一次") {
                    Task { await exportFullVault() }
                },
                secondary: AppError.Action(label: "先算了", perform: {})
            )
        }
    }

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
