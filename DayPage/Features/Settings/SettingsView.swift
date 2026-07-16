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

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authService: AuthService
    @StateObject private var syncMonitor = iCloudSyncMonitor.shared
    @StateObject private var reminderService = CaptureReminderService.shared
    @ObservedObject private var appSettings = AppSettings.shared

    @State private var showAccountSheet = false

    var body: some View {
        NavigationStack {
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
            .tint(DSColor.primary)
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
            .bannerOverlay()
            .sheet(isPresented: $showAccountSheet) {
                AccountSheet()
            }
        }
    }

    // MARK: Account

    private var accountSection: some View {
        Section(NSLocalizedString("settings.account.section", comment: "")) {
            Button {
                showAccountSheet = true
            } label: {
                HStack(spacing: DSSpacing.md) {
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

    // MARK: Hub rows

    private var hubSection: some View {
        Section {
            hubRow(
                title: NSLocalizedString("settings.hub.aivoice", comment: "AI & Voice row"),
                systemImage: "sparkles",
                summary: aiVoiceSummary,
                identifier: "hub-aivoice"
            ) {
                SettingsAIVoiceView()
            }
            hubRow(
                title: NSLocalizedString("settings.hub.reminders", comment: "Reminders row"),
                systemImage: "bell.badge",
                summary: remindersSummary,
                identifier: "hub-reminders"
            ) {
                SettingsRemindersView()
            }
            hubRow(
                title: NSLocalizedString("settings.appearance.section", comment: "Appearance row"),
                systemImage: "circle.lefthalf.filled",
                summary: appSettings.themeMode.label,
                identifier: "hub-appearance"
            ) {
                SettingsAppearanceView()
            }
            hubRow(
                title: NSLocalizedString("settings.hub.syncdata", comment: "Sync & data row"),
                systemImage: "arrow.triangle.2.circlepath",
                summary: syncSummary,
                identifier: "hub-syncdata"
            ) {
                SettingsSyncDataView()
            }
        }
    }

    private var aboutHubSection: some View {
        Section {
            hubRow(
                title: NSLocalizedString("settings.hub.about", comment: "About row"),
                systemImage: "info.circle",
                summary: appVersion,
                identifier: "hub-about"
            ) {
                SettingsAboutView()
            }
        }
    }

    @ViewBuilder
    private func hubRow<Destination: View>(
        title: String,
        systemImage: String,
        summary: String,
        identifier: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack {
                SettingsLabel(title: title, systemImage: systemImage)
                Spacer()
                Text(summary)
                    .font(DSType.labelSM)
                    .foregroundColor(DSColor.onSurfaceVariant)
                    .lineLimit(1)
            }
        }
        .accessibilityIdentifier(identifier)
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
            : String(format: NSLocalizedString("settings.reminder.count", value: "%d 条", comment: ""), count)
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
