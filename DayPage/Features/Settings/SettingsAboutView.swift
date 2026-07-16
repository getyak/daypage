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
        .tint(DSColor.primary)
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
                    Text("Build")
                        .foregroundColor(DSColor.onSurface)
                    Spacer()
                    Text(buildNumber)
                        .foregroundColor(DSColor.onSurfaceVariant)
                        .font(.caption)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings-build-row")
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
        .tint(DSColor.primary)
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

#Preview {
    NavigationStack { SettingsAboutView() }
}
