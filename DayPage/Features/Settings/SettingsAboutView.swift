import SwiftUI
import DayPageStorage
import DayPageServices

// MARK: - SettingsAboutView

/// "关于" — version/build (tap to copy), plus the developer options entry.
/// Developer options (feature flags, offline simulation, the analytics
/// debug board) are hidden until the Build row is tapped five times; the
/// unlock persists. Regular users never meet 13 experiment toggles.
@MainActor
struct SettingsAboutView: View {

    private static let devUnlockedKey = "settingsDevOptionsUnlocked"

    @State private var didCopyVersion = false
    @State private var devUnlocked = UserDefaults.standard.bool(forKey: Self.devUnlockedKey)
    @State private var buildTapCount = 0
    @StateObject private var bannerCenter = BannerCenter.shared

    var body: some View {
        List {
            Group {
                aboutSection
                if devUnlocked {
                    developerEntrySection
                }
            }
            .listRowBackground(DSColor.surfaceWhite)
        }
        .scrollContentBackground(.hidden)
        .background(DSColor.bgWarm.ignoresSafeArea())
        .tint(DSColor.accentOnBg)
        .navigationTitle(NSLocalizedString("settings.hub.about", comment: "About page title"))
        .navigationBarTitleDisplayMode(.inline)
        .bannerOverlay()
    }

    // MARK: About

    private var aboutSection: some View {
        Section {
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

            Button(action: buildRowTapped) {
                HStack {
                    Text(NSLocalizedString("settings.about.build", comment: "App build number"))
                        .foregroundColor(DSColor.onSurface)
                    Spacer()
                    Text(buildNumber)
                        .foregroundColor(DSColor.onSurfaceVariant)
                        .font(.caption)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings-build-row")

            NavigationLink {
                SettingsPrivacyView()
            } label: {
                SettingsLabel(
                    title: NSLocalizedString("settings.privacy.entry", comment: "Privacy & data row"),
                    systemImage: "hand.raised"
                )
            }
            .accessibilityIdentifier("settings-privacy-link")

            NavigationLink {
                SettingsDiagnosticsView()
            } label: {
                SettingsLabel(
                    title: NSLocalizedString("settings.diagnostics.entry", comment: "Diagnostics settings row"),
                    systemImage: "stethoscope"
                )
            }
            .accessibilityIdentifier("settings-diagnostics-link")
        } footer: {
            if !devUnlocked, buildTapCount >= 2 {
                Text(String(format: NSLocalizedString("settings.about.dev_unlock_progress", comment: "N more taps to unlock"), 5 - buildTapCount))
                    .font(.caption)
            }
        }
    }

    /// Five taps on Build unlocks developer options, persisted.
    private func buildRowTapped() {
        guard !devUnlocked else { return }
        buildTapCount += 1
        if buildTapCount >= 5 {
            devUnlocked = true
            UserDefaults.standard.set(true, forKey: Self.devUnlockedKey)
            Haptics.success()
            bannerCenter.show(AppBannerModel(
                kind: .info,
                title: NSLocalizedString("settings.dev.unlocked", comment: "Developer options unlocked banner"),
                autoDismiss: true
            ))
        } else if buildTapCount >= 2 {
            Haptics.soft()
        }
    }

    private var developerEntrySection: some View {
        Section {
            NavigationLink {
                SettingsDeveloperView()
            } label: {
                SettingsLabel(title: NSLocalizedString("settings.dev.entry", comment: "Developer options row"), systemImage: "hammer")
            }
            .accessibilityIdentifier("settings-developer-link")
        }
    }

    private func copyVersionInfo() {
        UIPasteboard.general.string = "DayPage \(appVersion) (\(buildNumber))"
        Haptics.success()
        withAnimation(Motion.fade) { didCopyVersion = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(Motion.fade) { didCopyVersion = false }
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
}

// MARK: - SettingsDiagnosticsView

/// User-visible, content-free support snapshot. This intentionally exposes
/// operational metadata only; memo text, attachments, email, and tokens never
/// enter the view or its clipboard summary.
@MainActor
struct SettingsDiagnosticsView: View {
    @EnvironmentObject private var authService: AuthService
    @StateObject private var syncQueue = SyncQueueService.shared
    @StateObject private var networkMonitor = NetworkMonitor.shared
    @StateObject private var bannerCenter = BannerCenter.shared

    var body: some View {
        List {
            Group {
                runtimeSection
                authSection
                syncSection
                copySection
            }
            .listRowBackground(DSColor.surfaceWhite)
        }
        .scrollContentBackground(.hidden)
        .background(DSColor.bgWarm.ignoresSafeArea())
        .tint(DSColor.accentOnBg)
        .navigationTitle(NSLocalizedString("settings.diagnostics.title", comment: "Diagnostics page title"))
        .navigationBarTitleDisplayMode(.inline)
        .bannerOverlay()
    }

    private var runtimeSection: some View {
        Section(NSLocalizedString("settings.diagnostics.runtime", comment: "Runtime diagnostics section")) {
            diagnosticRow(
                title: NSLocalizedString("settings.diagnostics.sentry", comment: "Sentry status"),
                value: SentryReporter.isSentryEnabled
                    ? NSLocalizedString("settings.diagnostics.enabled", comment: "Enabled")
                    : NSLocalizedString("settings.diagnostics.disabled", comment: "Disabled")
            )
            diagnosticRow(
                title: NSLocalizedString("settings.diagnostics.network", comment: "Network status"),
                value: networkMonitor.isOnline
                    ? NSLocalizedString("settings.diagnostics.online", comment: "Online")
                    : NSLocalizedString("settings.diagnostics.offline", comment: "Offline")
            )
            diagnosticRow(
                title: NSLocalizedString("settings.about.version", comment: "App version"),
                value: "\(appVersion) (\(buildNumber))"
            )
        }
    }

    @ViewBuilder
    private var authSection: some View {
        Section(NSLocalizedString("settings.diagnostics.auth", comment: "Auth diagnostics section")) {
            if let failure = authService.lastFailureDiagnostic {
                diagnosticRow(
                    title: NSLocalizedString("settings.diagnostics.last_failure", comment: "Last failure"),
                    value: displayDate(failure.occurredAt)
                )
                diagnosticRow(
                    title: NSLocalizedString("settings.diagnostics.stage_code", comment: "Stage and code"),
                    value: "\(failure.stage) / \(failure.code)"
                )
                diagnosticRow(
                    title: NSLocalizedString("settings.diagnostics.reference", comment: "Reference ID"),
                    value: shortReference(failure.correlationID)
                )
            } else {
                Text(NSLocalizedString("settings.diagnostics.no_auth_failure", comment: "No auth failure"))
                    .font(DSType.labelSM)
                    .foregroundColor(DSColor.onSurfaceVariant)
            }
        }
    }

    private var syncSection: some View {
        let health = syncQueue.syncHealth
        return Section(NSLocalizedString("settings.diagnostics.sync", comment: "Sync diagnostics section")) {
            diagnosticRow(
                title: NSLocalizedString("settings.diagnostics.pending", comment: "Pending sync count"),
                value: String(syncQueue.pendingCount)
            )
            diagnosticRow(
                title: NSLocalizedString("settings.diagnostics.last_attempt", comment: "Last sync attempt"),
                value: health.lastAttemptAt.map(displayDate) ?? "—"
            )
            diagnosticRow(
                title: NSLocalizedString("settings.diagnostics.last_success", comment: "Last sync success"),
                value: health.lastSuccessAt.map(displayDate) ?? "—"
            )
            if let code = health.lastFailureCode {
                diagnosticRow(
                    title: NSLocalizedString("settings.diagnostics.last_error", comment: "Last sync error"),
                    value: "\(health.lastFailureStage ?? "unknown") / \(code)"
                )
                diagnosticRow(
                    title: NSLocalizedString("settings.diagnostics.failure_count", comment: "Failure count"),
                    value: String(health.consecutiveFailureCount)
                )
            }
            if let reference = health.lastCorrelationID {
                diagnosticRow(
                    title: NSLocalizedString("settings.diagnostics.reference", comment: "Reference ID"),
                    value: shortReference(reference)
                )
            }
        }
    }

    private var copySection: some View {
        Section {
            Button(action: copyDiagnostics) {
                Label(
                    NSLocalizedString("settings.diagnostics.copy", comment: "Copy diagnostics button"),
                    systemImage: "doc.on.doc"
                )
            }
            .accessibilityIdentifier("settings-diagnostics-copy")
        } footer: {
            Text(NSLocalizedString("settings.diagnostics.privacy", comment: "Diagnostics privacy note"))
                .font(.caption)
                .foregroundColor(DSColor.onSurfaceVariant)
        }
    }

    private func diagnosticRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DSSpacing.md) {
            Text(title)
                .foregroundColor(DSColor.onSurface)
            Spacer(minLength: DSSpacing.md)
            Text(value)
                .font(DSType.labelSM)
                .foregroundColor(DSColor.onSurfaceVariant)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    private func copyDiagnostics() {
        UIPasteboard.general.string = diagnosticSummary
        Haptics.success()
        bannerCenter.show(AppBannerModel(
            kind: .info,
            title: NSLocalizedString("settings.diagnostics.copied", comment: "Diagnostics copied banner"),
            autoDismiss: true
        ))
    }

    private var diagnosticSummary: String {
        let health = syncQueue.syncHealth
        let auth = authService.lastFailureDiagnostic
        return [
            "DayPage Diagnostics",
            "app=\(appVersion)",
            "build=\(buildNumber)",
            "os=\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            "sentry=\(SentryReporter.isSentryEnabled ? "enabled" : "disabled")",
            "network=\(networkMonitor.isOnline ? "online" : "offline")",
            "auth_failure_at=\(isoDate(auth?.occurredAt))",
            "auth_provider=\(auth?.provider ?? "-")",
            "auth_stage=\(auth?.stage ?? "-")",
            "auth_code=\(auth?.code ?? "-")",
            "auth_http_status=\(auth?.httpStatus.map(String.init) ?? "-")",
            "auth_correlation_id=\(auth?.correlationID ?? "-")",
            "sync_pending=\(syncQueue.pendingCount)",
            "sync_last_attempt=\(isoDate(health.lastAttemptAt))",
            "sync_last_success=\(isoDate(health.lastSuccessAt))",
            "sync_last_failure=\(isoDate(health.lastFailureAt))",
            "sync_stage=\(health.lastFailureStage ?? "-")",
            "sync_code=\(health.lastFailureCode ?? "-")",
            "sync_http_status=\(health.lastHTTPStatus.map(String.init) ?? "-")",
            "sync_correlation_id=\(health.lastCorrelationID ?? "-")",
            "sync_consecutive_failures=\(health.consecutiveFailureCount)",
        ].joined(separator: "\n")
    }

    private func shortReference(_ value: String) -> String {
        String(value.prefix(8)).uppercased()
    }

    private func displayDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }

    private func isoDate(_ date: Date?) -> String {
        guard let date else { return "-" }
        return ISO8601DateFormatter().string(from: date)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
}

// MARK: - SettingsDeveloperView

/// Feature flags, offline simulation, and the local analytics debug board.
/// Diagnostic surface — deliberately terse.
@MainActor
struct SettingsDeveloperView: View {

    @StateObject private var flagStore = FeatureFlagStore.shared

    // R8 — force NetworkMonitor offline for testing without airplane mode.
    @AppStorage(AppSettings.Keys.debugSimulateOffline) private var simulateOffline: Bool = false

    var body: some View {
        List {
            Group {
                experimentsSection
                analyticsDebugSection
            }
            .listRowBackground(DSColor.surfaceWhite)
        }
        .scrollContentBackground(.hidden)
        .background(DSColor.bgWarm.ignoresSafeArea())
        .tint(DSColor.accentOnBg)
        .navigationTitle(NSLocalizedString("settings.dev.title", comment: "Developer options page title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Experiments (R4-MEDIUM #39)

    private var experimentsSection: some View {
        Section {
            ForEach(FeatureFlag.allCases, id: \.rawValue) { flag in
                Toggle(
                    flag.title,
                    isOn: Binding(
                        get: { flagStore.isEnabled(flag) },
                        set: {
                            Haptics.selection()
                            flagStore.set(flag, enabled: $0)
                        }
                    )
                )
                .accessibilityIdentifier("experiments-flag-\(flag.rawValue)")
            }

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

    // MARK: Analytics debug (Issue #18)

    private var analyticsDebugSection: some View {
        let counts = AnalyticsService.shared.todaysCounts()
        let recent = AnalyticsService.shared.recentEvents(limit: 12).reversed()
        return Section {
            if counts.isEmpty {
                Text(NSLocalizedString("settings.analytics.empty", comment: "No events today"))
                    .font(DSType.labelSM)
                    .foregroundColor(DSColor.inkMuted)
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
                DisclosureGroup(String(format: NSLocalizedString("settings.analytics.recent", comment: "Recent N events"), recent.count)) {
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
                Haptics.warn()
                AnalyticsService.shared.reset()
            } label: {
                Label(NSLocalizedString("settings.analytics.clear", comment: "Clear debug events"), systemImage: "trash")
            }
        } header: {
            Text(NSLocalizedString("settings.analytics.section", comment: "Analytics debug board header"))
        } footer: {
            Text(NSLocalizedString("settings.analytics.footer", comment: "What the board shows"))
                .font(.caption)
        }
    }
}

// MARK: - SettingsPrivacyView

/// "隐私与数据" — the in-app privacy and data explanation (issue #922),
/// reachable from About. Reuses the Settings list style. This screen is the
/// app's current privacy/data-flow explanation; it deliberately carries NO
/// external privacy-policy link (daypage.app/privacy is not published — a 404
/// link must never ship). Crash diagnostics consent is toggled here.
@MainActor
struct SettingsPrivacyView: View {

    @State private var diagnosticsOptIn = DiagnosticsConsent.isOptedIn

    var body: some View {
        List {
            Group {
                dataSection
                syncSection
                voiceAISection
                diagnosticsSection
            }
            .listRowBackground(DSColor.surfaceWhite)
        }
        .scrollContentBackground(.hidden)
        .background(DSColor.bgWarm.ignoresSafeArea())
        .tint(DSColor.accentOnBg)
        .navigationTitle(NSLocalizedString("settings.privacy.title", comment: "Privacy & data page title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Your data

    private var dataSection: some View {
        Section {
            privacyRow(
                icon: "internaldrive",
                title: NSLocalizedString("settings.privacy.local.title", comment: "Local-first storage row"),
                body: NSLocalizedString("settings.privacy.local.body", comment: "Notes and attachments are local-first")
            )
        } header: {
            Text(NSLocalizedString("settings.privacy.section.data", comment: "Your data section header"))
        }
    }

    // MARK: Optional sync

    private var syncSection: some View {
        Section {
            privacyRow(
                icon: "icloud",
                title: NSLocalizedString("settings.privacy.icloud.title", comment: "iCloud row"),
                body: NSLocalizedString("settings.privacy.icloud.body", comment: "iCloud copies the vault")
            )
            privacyRow(
                icon: "person.crop.circle",
                title: NSLocalizedString("settings.privacy.accountsync.title", comment: "Account sync row"),
                body: NSLocalizedString("settings.privacy.accountsync.body", comment: "Signed-in sync uploads notes/audio/images; not E2E")
            )
        } header: {
            Text(NSLocalizedString("settings.privacy.section.sync", comment: "Optional sync section header"))
        }
    }

    // MARK: Voice & AI

    private var voiceAISection: some View {
        Section {
            privacyRow(
                icon: "mic",
                title: NSLocalizedString("settings.privacy.voice.title", comment: "Voice transcription row"),
                body: NSLocalizedString("settings.privacy.voice.body", comment: "Audio goes to Doubao or Whisper when configured")
            )
            privacyRow(
                icon: "sparkles",
                title: NSLocalizedString("settings.privacy.ai.title", comment: "AI features row"),
                body: NSLocalizedString("settings.privacy.ai.body", comment: "Selected context goes to the configured AI provider")
            )
            privacyRow(
                icon: "key",
                title: NSLocalizedString("settings.privacy.keys.title", comment: "API keys row"),
                body: NSLocalizedString("settings.privacy.keys.body", comment: "Keys optional and billed separately")
            )
        } header: {
            Text(NSLocalizedString("settings.privacy.section.voiceai", comment: "Voice & AI section header"))
        }
    }

    // MARK: Crash diagnostics (opt-in)

    private var diagnosticsSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { diagnosticsOptIn },
                set: { newValue in
                    Haptics.selection()
                    diagnosticsOptIn = newValue
                    // Persisted consent (default off). The registered change
                    // handler starts/closes the live SDK; the Kit-side event
                    // gate blocks every future event on revocation.
                    DiagnosticsConsent.setOptedIn(newValue)
                }
            )) {
                SettingsLabel(
                    title: NSLocalizedString("settings.privacy.diagnostics.toggle", comment: "Crash diagnostics toggle"),
                    systemImage: "waveform.path.ecg"
                )
            }
            .accessibilityIdentifier("settings-privacy-diagnostics-toggle")
            .accessibilityHint(NSLocalizedString("settings.privacy.diagnostics.hint", comment: "Toggle hint"))
        } header: {
            Text(NSLocalizedString("settings.privacy.section.diagnostics", comment: "Crash diagnostics section header"))
        } footer: {
            Text(NSLocalizedString("settings.privacy.diagnostics.body", comment: "What opt-in diagnostics upload and that revocation cannot recall past events"))
                .font(.caption)
                .foregroundColor(DSColor.onSurfaceVariant)
        }
    }

    // MARK: Row

    private func privacyRow(icon: String, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            SettingsLabel(title: title, systemImage: icon)
            Text(body)
                .font(DSType.labelSM)
                .foregroundColor(DSColor.onSurfaceVariant)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    NavigationStack { SettingsAboutView() }
        .environmentObject(AuthService.shared)
}
