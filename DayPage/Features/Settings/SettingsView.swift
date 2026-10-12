import SwiftUI
import DayPageStorage
import DayPageServices

// MARK: - SettingsView

/// Settings hub — six groups, hub-and-spoke. The first level is a map:
/// each row carries a live status summary (Doubao verification, reminder
/// count, theme, iCloud state) so the page answers "what's the state"
/// without drilling in. Details live in the sub-pages:
///
///   账户            — sign-in state (AccountSheet)
///   AI 与语音       — SettingsAIVoiceView (LLM engine, ASR stack, services)
///   提醒与通知      — SettingsRemindersView
///   外观            — SettingsAppearanceView
///   同步与数据      — SettingsSyncDataView (iCloud, web, export, danger zone)
///   关于            — SettingsAboutView (+ hidden developer options)
///
/// Replaces the previous 14-section flat list (2,000+ lines in one file).
@MainActor
struct SettingsView: View {

    enum Route: String, Hashable {
        case aiVoice
        case reminders
        case systemAccess
        case appearance
        case syncData
        case about

        static func initial(arguments: [String]) -> Route? {
            #if DEBUG
            guard let index = arguments.firstIndex(of: "-qaSettingsPage"),
                  arguments.indices.contains(index + 1) else { return nil }
            switch arguments[index + 1].lowercased() {
            case "aivoice": return .aiVoice
            case "reminders": return .reminders
            case "systemaccess", "system-access": return .systemAccess
            case "appearance": return .appearance
            case "syncdata": return .syncData
            case "about": return .about
            default: return nil
            }
            #else
            return nil
            #endif
        }
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authService: AuthService
    @Environment(\.dynamicTypeSize) private var userDynamicTypeSize
    @StateObject private var syncMonitor = iCloudSyncMonitor.shared
    @StateObject private var reminderService = CaptureReminderService.shared
    @ObservedObject private var appSettings = AppSettings.shared

    @State private var showAccountSheet = false
    @State private var path: [Route]

    init(initialRoute: Route? = nil) {
        let resolved = initialRoute ?? Route.initial(arguments: ProcessInfo.processInfo.arguments)
        _path = State(initialValue: resolved.map { [$0] } ?? [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Group {
                    accountSection
                    hubSection
                    aboutHubSection
                }
                .listRowBackground(DSColor.surfaceWhite)
            }
            .scrollContentBackground(.hidden)
            .background(DSColor.bgWarm.ignoresSafeArea())
            .tint(DSColor.accentOnBg)
            .accessibilityIdentifier("settings-list")
            .navigationTitle(NSLocalizedString("settings.nav.title", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Route.self, destination: destination)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("settings.nav.close", comment: "")) { dismiss() }
                        .accessibilityLabel(NSLocalizedString("settings.close.label", comment: ""))
                        .accessibilityIdentifier("settings-close-button")
                }
            }
            .bannerOverlay()
            .sheet(isPresented: $showAccountSheet) {
                AccountSheet()
            }
        }
        // Settings is dense navigation chrome rather than long-form reading.
        // AX4–AX5 system scaling makes section headers and trailing summaries
        // consume entire rows on compact phones; cap this hub at AX2 while the
        // content remains scrollable and VoiceOver keeps full strings.
        .dynamicTypeSize(.xSmall ... .accessibility2)
    }

    // MARK: Account

    private var accountSection: some View {
        Section(NSLocalizedString("settings.account.section", comment: "")) {
            Button {
                showAccountSheet = true
            } label: {
                Group {
                    if userDynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: DSSpacing.sm) {
                            HStack(spacing: DSSpacing.md) {
                                Image(systemName: "person.crop.circle")
                                    .font(DSType.h2)
                                    .foregroundColor(DSColor.inkMuted)
                                    .accessibilityHidden(true)
                                Text(authService.session?.user.email ?? NSLocalizedString("settings.account.signed_out", comment: ""))
                                    .font(DSType.bodyMD)
                                    .foregroundColor(DSColor.onBackgroundPrimary)
                            }
                            Text(authService.session == nil ? NSLocalizedString("settings.account.tap_to_sign_in", comment: "") : NSLocalizedString("settings.account.manage", comment: ""))
                                .font(DSType.labelSM)
                                .foregroundColor(DSColor.inkMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        HStack(spacing: DSSpacing.md) {
                            Image(systemName: "person.crop.circle")
                                .font(DSType.h2)
                                .foregroundColor(DSColor.inkMuted)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(authService.session?.user.email ?? NSLocalizedString("settings.account.signed_out", comment: ""))
                                    .font(DSType.bodyMD)
                                    .foregroundColor(DSColor.onBackgroundPrimary)
                                Text(authService.session == nil ? NSLocalizedString("settings.account.tap_to_sign_in", comment: "") : NSLocalizedString("settings.account.manage", comment: ""))
                                    .font(DSType.labelSM)
                                    .foregroundColor(DSColor.inkMuted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(DSType.caption)
                                .foregroundColor(DSColor.inkMuted)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Hub rows

    private var hubSection: some View {
        Section {
            hubRow(
                title: NSLocalizedString("settings.hub.aivoice", comment: "AI & Voice row"),
                systemImage: "sparkles",
                summary: aiVoiceSummary,
                identifier: "hub-aivoice",
                route: .aiVoice
            )
            hubRow(
                title: NSLocalizedString("settings.hub.reminders", comment: "Reminders row"),
                systemImage: "bell.badge",
                summary: remindersSummary,
                identifier: "hub-reminders",
                route: .reminders
            )
            hubRow(
                title: NSLocalizedString("settings.hub.system_access", comment: "System access row"),
                systemImage: "hand.raised",
                summary: NSLocalizedString("settings.hub.system_access.summary", comment: "System access summary"),
                identifier: "hub-system-access",
                route: .systemAccess
            )
            hubRow(
                title: NSLocalizedString("settings.appearance.section", comment: "Appearance row"),
                systemImage: "circle.lefthalf.filled",
                summary: appSettings.themeMode.label,
                identifier: "hub-appearance",
                route: .appearance
            )
            hubRow(
                title: NSLocalizedString("settings.hub.syncdata", comment: "Sync & data row"),
                systemImage: "arrow.triangle.2.circlepath",
                summary: syncSummary,
                identifier: "hub-syncdata",
                route: .syncData
            )
        }
    }

    private var aboutHubSection: some View {
        Section {
            hubRow(
                title: NSLocalizedString("settings.hub.about", comment: "About row"),
                systemImage: "info.circle",
                summary: appVersion,
                identifier: "hub-about",
                route: .about
            )
        }
    }

    @ViewBuilder
    private func hubRow(
        title: String,
        systemImage: String,
        summary: String,
        identifier: String,
        route: Route
    ) -> some View {
        NavigationLink(value: route) {
            Group {
                if userDynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: DSSpacing.xs) {
                        SettingsLabel(title: title, systemImage: systemImage)
                        Text(summary)
                            .font(DSType.labelSM)
                            .foregroundColor(DSColor.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    HStack {
                        SettingsLabel(title: title, systemImage: systemImage)
                        Spacer()
                        Text(summary)
                            .font(DSType.labelSM)
                            .foregroundColor(DSColor.inkMuted)
                            .lineLimit(1)
                    }
                }
            }
        }
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .aiVoice: SettingsAIVoiceView()
        case .reminders: SettingsRemindersView()
        case .systemAccess: SystemAccessView(model: SystemActionRuntime.shared.model)
        case .appearance: SettingsAppearanceView()
        case .syncData: SettingsSyncDataView()
        case .about: SettingsAboutView()
        }
    }

    // MARK: Summaries

    private var aiVoiceSummary: String {
        switch DoubaoVerification.state {
        case .verified:
            return String(format: NSLocalizedString("settings.hub.aivoice.summary.verified", comment: "Provider verified summary"),
                          ASRSettings.active.displayName)
        case .failed:
            return NSLocalizedString("settings.hub.aivoice.summary.failed", comment: "Verification failed summary")
        case .unverified:
            return NSLocalizedString("settings.hub.aivoice.summary.unverified", comment: "Unverified summary")
        case .notConfigured:
            return ASRSettings.active.displayName
        }
    }

    private var remindersSummary: String {
        let count = reminderService.reminders.filter { $0.enabled }.count
        return count == 0
            ? NSLocalizedString("settings.hub.reminders.summary.none", comment: "No reminders summary")
            : String(format: NSLocalizedString("settings.hub.reminders.summary.active", comment: "Enabled reminders summary"), count)
    }

    private var syncSummary: String {
        switch syncMonitor.status {
        case .notConfigured:
            return NSLocalizedString("settings.hub.sync.summary.off", comment: "iCloud off summary")
        case .connected:
            return NSLocalizedString("settings.hub.sync.summary.on", comment: "iCloud on summary")
        case .syncing:
            return NSLocalizedString("settings.hub.sync.summary.syncing", comment: "Syncing summary")
        case .error:
            return NSLocalizedString("settings.hub.sync.summary.error", comment: "Sync error summary")
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
}

#Preview {
    SettingsView()
}
