import SwiftUI
import DayPageStorage
import DayPageServices

// MARK: - SettingsSyncDataView

/// "同步与数据" — iCloud sync, iOS→Web sync, time zone (memo dating), data
/// export, and the danger zone. Destructive actions live in their own
/// section at the very bottom: red appears there and nowhere else.
@MainActor
struct SettingsSyncDataView: View {

    @StateObject private var bannerCenter = BannerCenter.shared
    @StateObject private var syncMonitor = iCloudSyncMonitor.shared
    @StateObject private var syncQueue = SyncQueueService.shared
    @ObservedObject private var appSettings = AppSettings.shared

    // #785: iOS → Web sync config (UserDefaults baseURL + Keychain API key).
    @State private var webSyncBaseURL: String = SyncSettings.baseURLString ?? ""
    @State private var webSyncAPIKey: String = SyncSettings.apiKey ?? ""
    @State private var webSyncSaved: Bool = false

    // Data section state
    @State private var vaultSizeLabel: String = NSLocalizedString("settings.data.vault.computing", comment: "")
    @State private var exportResult: String? = nil
    @State private var isExportingObsidian = false
    @State private var isExportingFullVault = false
    @State private var obsidianExportURL: URL? = nil
    @State private var showObsidianShareSheet = false
    @State private var appError: AppError? = nil

    // Destructive confirmations
    @State private var showCleanupConfirm = false
    @State private var showClearSampleConfirm = false
    @State private var showPurgeAllConfirm = false

    var body: some View {
        List {
            Group {
                iCloudSyncSection
                webSyncSection
                timeZoneSection
                dataSection
                dangerSection
            }
            .listRowBackground(DSColor.surfaceWhite)
        }
        .scrollContentBackground(.hidden)
        .background(DSColor.bgWarm.ignoresSafeArea())
        .tint(DSColor.primary)
        .appErrorAlert($appError)
        .navigationTitle(NSLocalizedString("settings.hub.syncdata", comment: "Sync & data page title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { computeVaultSize() }
        .bannerOverlay()
        .sheet(isPresented: $showObsidianShareSheet, onDismiss: {
            obsidianExportURL = nil
        }) {
            if let url = obsidianExportURL {
                ShareSheet(activityItems: [url])
                    .ignoresSafeArea()
            }
        }
    }

    // MARK: iCloud

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
                    .fill(DSColor.statusSuccess)
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
                    .foregroundColor(DSColor.statusError)
                VStack(alignment: .leading, spacing: 2) {
                    Text(NSLocalizedString("settings.icloud.error", comment: "")).font(.body).fontWeight(.medium).foregroundColor(DSColor.statusError)
                    Text(message)
                        .font(.caption)
                        .foregroundColor(DSColor.statusError)
                        .lineLimit(2)
                }
            }
        }
    }

    private var iCloudNotConfiguredCard: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            HStack(spacing: DSSpacing.sm) {
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
            Button(action: openSystemSettings) {
                Label(NSLocalizedString("settings.icloud.enable.button", comment: ""), systemImage: "arrow.up.right.square")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, DSSpacing.xs)
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
                SettingsLabel(title: NSLocalizedString("settings.icloud.attachment.policy", comment: ""), systemImage: "square.and.arrow.down")
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
        Haptics.warn()
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
        Haptics.warn()
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
        if cal.isDateInToday(date) {
            formatter.dateFormat = NSLocalizedString("settings.icloud.lastsync.today_format", comment: "Today HH:mm")
        } else {
            formatter.dateFormat = NSLocalizedString("settings.icloud.lastsync.date_format", comment: "Month day HH:mm")
        }
        return formatter.string(from: date)
    }

    // MARK: Web sync (#785)

    private var webSyncSection: some View {
        Section {
            HStack {
                SettingsLabel(title: NSLocalizedString("settings.websync.url", comment: "Web address row"), systemImage: "globe")
                Spacer()
                TextField("https://daypage.app", text: $webSyncBaseURL)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.URL)
                    .foregroundColor(DSColor.onSurfaceVariant)
                    .accessibilityIdentifier("sync-baseurl-field")
            }

            HStack {
                SettingsLabel(title: "API Key", systemImage: "key.fill")
                Spacer()
                SecureField(NSLocalizedString("settings.websync.key.placeholder", comment: "Paste key placeholder"), text: $webSyncAPIKey)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .foregroundColor(DSColor.onSurfaceVariant)
                    .accessibilityIdentifier("sync-apikey-field")
            }

            Button {
                saveWebSyncConfig()
            } label: {
                HStack {
                    SettingsLabel(
                        title: webSyncSaved
                            ? NSLocalizedString("settings.websync.saved", comment: "Saved state")
                            : NSLocalizedString("settings.websync.save", comment: "Save & sync button"),
                        systemImage: webSyncSaved ? "checkmark.circle.fill" : "arrow.up.circle")
                    Spacer()
                    if SyncSettings.isConfigured {
                        Text(NSLocalizedString("settings.websync.configured", comment: "Configured badge"))
                            .font(DSType.labelSM).foregroundColor(DSColor.statusSuccess)
                    }
                }
            }
            .accessibilityIdentifier("sync-save-button")

            if syncQueue.pendingCount > 0 {
                HStack {
                    SettingsLabel(title: NSLocalizedString("settings.websync.pending", comment: "Pending row"), systemImage: "clock.arrow.circlepath")
                    Spacer()
                    Text(String(format: NSLocalizedString("settings.websync.pending_count", comment: "N items"), syncQueue.pendingCount))
                        .font(DSType.labelSM)
                        .foregroundColor(DSColor.statusWarning)
                }
            } else if SyncSettings.isConfigured {
                HStack {
                    Label(NSLocalizedString("settings.websync.all_synced", comment: "All synced row"), systemImage: "checkmark.icloud")
                        .foregroundStyle(DSColor.onSurfaceVariant, DSColor.onSurfaceVariant)
                    Spacer()
                }
                .foregroundColor(DSColor.onSurfaceVariant)
            }
        } header: {
            Text(NSLocalizedString("settings.websync.section", comment: "Web sync section header"))
        } footer: {
            Text(NSLocalizedString("settings.websync.footer", comment: "How to generate a write-scope key"))
                .font(.caption)
        }
    }

    private func saveWebSyncConfig() {
        SyncSettings.baseURLString = webSyncBaseURL
        SyncSettings.apiKey = webSyncAPIKey
        webSyncBaseURL = SyncSettings.baseURLString ?? ""
        SyncQueueObserver.shared.installConfiguredUploader()
        webSyncSaved = true
        Task { await SyncQueueService.shared.flushIfOnline() }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { webSyncSaved = false }
        }
    }

    // MARK: Time zone

    private var timeZoneSection: some View {
        Section {
            NavigationLink(destination: TimeZonePickerView(
                selected: appSettings.preferredTimeZone,
                onSelect: { tz in
                    appSettings.preferredTimeZone = tz
                    BackgroundCompilationService.shared.scheduleIfNeeded()
                }
            )) {
                HStack {
                    SettingsLabel(title: NSLocalizedString("settings.timezone.preferred", comment: ""), systemImage: "clock.badge.questionmark")
                    Spacer()
                    Text(appSettings.preferredTimeZone.localizedLabel)
                        .font(.caption)
                        .foregroundColor(DSColor.onSurfaceVariant)
                }
            }
            if appSettings.preferredTimeZone.identifier != TimeZone.current.identifier {
                Button(role: .destructive) {
                    Haptics.warn()
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

    // MARK: Data

    private var dataSection: some View {
        Section {
            HStack {
                SettingsLabel(title: NSLocalizedString("settings.data.vault_size", comment: ""), systemImage: "internaldrive")
                Spacer()
                Text(vaultSizeLabel)
                    .font(.caption)
                    .foregroundColor(DSColor.onSurfaceVariant)
            }

            Button(action: exportAll) {
                SettingsLabel(title: NSLocalizedString("settings.data.export_archive", comment: ""), systemImage: "archivebox")
            }

            Button(action: { Task { await exportObsidianVault() } }) {
                if isExportingObsidian {
                    HStack {
                        Label(NSLocalizedString("settings.data.exporting", comment: ""), systemImage: "square.and.arrow.up")
                        Spacer()
                        ProgressView().scaleEffect(0.8)
                    }
                } else {
                    SettingsLabel(title: NSLocalizedString("settings.data.export_obsidian", comment: ""), systemImage: "square.and.arrow.up")
                }
            }
            .disabled(isExportingObsidian)

            // Issue #12: 全量导出 (zip) — raw memos、assets、entities 一并带走。
            Button(action: { Task { await exportFullVault() } }) {
                if isExportingFullVault {
                    HStack {
                        Label(NSLocalizedString("settings.data.export_full.working", comment: "Zipping in progress"), systemImage: "shippingbox")
                        Spacer()
                        ProgressView().scaleEffect(0.8)
                    }
                } else {
                    SettingsLabel(title: NSLocalizedString("settings.data.export_full", comment: "Export everything (zip)"), systemImage: "shippingbox")
                }
            }
            .disabled(isExportingFullVault)
            .accessibilityIdentifier("settings-export-full-vault")

            if let result = exportResult {
                Text(result)
                    .font(.caption)
                    .foregroundColor(DSColor.onSurfaceVariant)
            }
        } header: {
            Text(NSLocalizedString("settings.data.section", comment: ""))
        }
    }

    // MARK: Danger zone

    /// Destructive actions, isolated: red appears in this section and
    /// nowhere else on the page.
    private var dangerSection: some View {
        Section {
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
                        Haptics.warn()
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

            // C3: GDPR right-to-be-forgotten. Local-only by design.
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
                    Haptics.warn()  // irreversible on-device wipe — the strongest cue
                    purgeAllLocalData()
                }
                Button(NSLocalizedString("settings.common.cancel", comment: ""), role: .cancel) {}
            } message: {
                Text(NSLocalizedString("settings.data.purge_all.confirm.message", comment: ""))
            }
        } header: {
            Text(NSLocalizedString("settings.danger.section", comment: "Danger zone header"))
        } footer: {
            Text(NSLocalizedString("settings.danger.footer", comment: "Danger zone explainer"))
                .font(.caption)
        }
    }

    // MARK: Data helpers

    private func computeVaultSize() {
        Task.detached(priority: .utility) {
            let vaultURL = VaultInitializer.vaultURL
            let fm = FileManager.default
            var totalBytes: Int64 = 0
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
            let label = dayCount > 0 ? String(format: NSLocalizedString("settings.data.vault.days_size", comment: ""), dayCount, sizeLabel) : sizeLabel
            await MainActor.run { self.vaultSizeLabel = label }
        }
    }

    /// True for a raw day-file name of the form `YYYY-MM-DD.md`.
    private nonisolated static func isDayFileName(_ name: String) -> Bool {
        guard name.hasSuffix(".md") else { return false }
        let stem = String(name.dropLast(3))
        let parts = stem.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2 else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    private func exportAll() {
        exportResult = NSLocalizedString("settings.data.export.use_archive", comment: "")
        bannerCenter.show(.init(kind: .info, title: NSLocalizedString("settings.data.export.archive_banner", comment: "")))
    }

    /// Issue #12 · full-vault zip via the canonical Kit-side helper.
    private func exportFullVault() async {
        isExportingFullVault = true
        defer { isExportingFullVault = false }
        do {
            let zip = try await VaultExportService.shared.exportVaultZip(includes: .all)
            showObsidianShareSheet = true
            obsidianExportURL = zip
        } catch {
            appError = AppError(
                title: NSLocalizedString("settings.data.export_full.failed.title", comment: "Full export failed"),
                reason: String(format: NSLocalizedString("settings.data.export_full.failed.reason", comment: "Reason + common causes"), error.localizedDescription),
                primary: AppError.Action(label: NSLocalizedString("settings.common.retry", comment: "Retry")) {
                    Task { await exportFullVault() }
                },
                secondary: AppError.Action(label: NSLocalizedString("settings.common.dismiss", comment: "Dismiss"), perform: {})
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

    // C3 fix (GDPR): wipe local user-generated state. Scope is local-only —
    // cloud account deletion (Supabase) is a separate flow.
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

        // 2. API keys in Keychain — driven off ApiKeyKind so this can never
        // drift from the credential rows again.
        for kind in ApiKeyKind.allCases {
            KeychainHelper.deleteAPIKey(for: kind.rawValue)
        }
        DoubaoVerification.invalidate()

        // 3. UserDefaults — targeted reset of onboarding + engagement keys.
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

        // 4. Surface result.
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

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
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

        let tmpDir = fm.temporaryDirectory.appendingPathComponent("daypage_export_\(Int(Date().timeIntervalSince1970))")
        let docsDir = tmpDir.appendingPathComponent("DayPage")
        let dailyOutDir = docsDir.appendingPathComponent("Daily")
        do {
            try fm.createDirectory(at: dailyOutDir, withIntermediateDirectories: true)
        } catch {
            return .failure(error)
        }

        for page in pages {
            guard var content = try? String(contentsOf: page, encoding: .utf8) else { continue }
            content = injectObsidianAlias(into: content, filename: page.deletingPathExtension().lastPathComponent)
            let dest = dailyOutDir.appendingPathComponent(page.lastPathComponent)
            try? content.write(to: dest, atomically: true, encoding: .utf8)
        }

        let indexSrc = VaultInitializer.vaultURL.appendingPathComponent("wiki/index.md")
        if fm.fileExists(atPath: indexSrc.path) {
            try? fm.copyItem(at: indexSrc, to: docsDir.appendingPathComponent("index.md"))
        }

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
    NavigationStack { SettingsSyncDataView() }
}
