import SwiftUI
import DayPageStorage
import DayPageServices

// MARK: - DoubaoConfigView

/// Unified Doubao (火山引擎) speech credentials page.
///
/// Replaces the three disconnected API-key rows: credentials are edited as
/// the pair they actually are (App ID + Access Token — `hasCredentials`
/// requires both), and "test connection" runs a REAL transcription against
/// BOTH production endpoints, echoing the recognized text back. The legacy
/// Secret Key field is gone: nothing in the codebase ever consumed it.
@MainActor
struct DoubaoConfigView: View {

    @StateObject private var tester = DoubaoConnectivityTester()
    @StateObject private var bannerCenter = BannerCenter.shared

    @State private var appID: String = KeychainHelper.getAPIKey(for: ApiKeyKind.doubaoASRAppID.rawValue) ?? ""
    @State private var accessToken: String = KeychainHelper.getAPIKey(for: ApiKeyKind.doubaoASRAccessToken.rawValue) ?? ""
    @State private var revealToken = false
    /// Bumped after save/test so the badge (computed off UserDefaults +
    /// Keychain) re-evaluates.
    @State private var stateRefresh = UUID()

    private var verification: DoubaoVerification.State {
        _ = stateRefresh
        return DoubaoVerification.state
    }

    private var savedAppID: String { KeychainHelper.getAPIKey(for: ApiKeyKind.doubaoASRAppID.rawValue) ?? "" }
    private var savedToken: String { KeychainHelper.getAPIKey(for: ApiKeyKind.doubaoASRAccessToken.rawValue) ?? "" }

    private var isDirty: Bool {
        appID.trimmingCharacters(in: .whitespacesAndNewlines) != savedAppID
            || accessToken.trimmingCharacters(in: .whitespacesAndNewlines) != savedToken
    }

    var body: some View {
        List {
            Group {
                statusSection
                credentialsSection
                testSection
            }
            .listRowBackground(DSColor.surfaceWhite)
        }
        .scrollContentBackground(.hidden)
        .background(DSColor.bgWarm.ignoresSafeArea())
        .tint(DSColor.primary)
        .navigationTitle(NSLocalizedString("settings.doubao.nav.title", comment: "Doubao config page title"))
        .navigationBarTitleDisplayMode(.inline)
        .bannerOverlay()
    }

    // MARK: Status

    private var statusSection: some View {
        Section {
            HStack(spacing: DSSpacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(NSLocalizedString("settings.doubao.title", comment: "Doubao provider display name"))
                        .font(.body)
                        .fontWeight(.semibold)
                    Text(statusSubtitle)
                        .font(DSType.labelSM)
                        .foregroundColor(DSColor.onSurfaceVariant)
                }
                Spacer()
                VerifyBadge(kind: verification.badgeKind, text: verification.badgeText)
                    .accessibilityIdentifier("doubao-status-badge")
            }
            .padding(.vertical, 2)
        } footer: {
            Text(NSLocalizedString("settings.doubao.status.footer", comment: "Explains what Doubao powers"))
                .font(.caption)
        }
    }

    private var statusSubtitle: String {
        switch verification {
        case .verified(let date):
            let fmt = DateFormatter()
            fmt.dateFormat = NSLocalizedString("settings.doubao.verified_at_format", comment: "Verified timestamp format")
            return String(format: NSLocalizedString("settings.doubao.verified_at", comment: "Last verified at"), fmt.string(from: date))
        case .failed(let what):
            return String(format: NSLocalizedString("settings.doubao.failed_at", comment: "Which endpoint failed"), what)
        case .unverified:
            return NSLocalizedString("settings.doubao.subtitle.unverified", comment: "Configured but never tested")
        case .notConfigured:
            return NSLocalizedString("settings.doubao.subtitle.not_configured", comment: "Needs both credentials")
        }
    }

    // MARK: Credentials

    private var credentialsSection: some View {
        Section {
            credentialField(
                label: "App ID",
                text: $appID,
                placeholder: NSLocalizedString("settings.doubao.appid.placeholder", comment: "Numeric app id placeholder"),
                secure: false,
                identifier: "doubao-appid-field"
            )
            credentialField(
                label: "Access Token",
                text: $accessToken,
                placeholder: NSLocalizedString("settings.doubao.token.placeholder", comment: "Access token placeholder"),
                secure: !revealToken,
                identifier: "doubao-token-field"
            )

            Button {
                saveCredentials()
            } label: {
                HStack {
                    Label(NSLocalizedString("settings.doubao.save", comment: "Save credentials button"),
                          systemImage: "checkmark.circle")
                    Spacer()
                    if !isDirty && DoubaoASRConfig.hasCredentials {
                        Text(NSLocalizedString("settings.doubao.saved", comment: "Saved state"))
                            .font(DSType.labelSM)
                            .foregroundColor(DSColor.statusSuccess)
                    }
                }
            }
            .disabled(!isDirty)
            .accessibilityIdentifier("doubao-save-button")
        } header: {
            Text(NSLocalizedString("settings.doubao.credentials.section", comment: "Credentials section header"))
        } footer: {
            Text(NSLocalizedString("settings.doubao.credentials.footer", comment: "Where to obtain the pair"))
                .font(.caption)
        }
    }

    @ViewBuilder
    private func credentialField(
        label: String,
        text: Binding<String>,
        placeholder: String,
        secure: Bool,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(DSType.mono10)
                    .tracking(1.0)
                    .textCase(.uppercase)
                    .foregroundColor(DSColor.onSurfaceVariant)
                Spacer()
                if label == "Access Token", !text.wrappedValue.isEmpty {
                    Button {
                        revealToken.toggle()
                    } label: {
                        Image(systemName: revealToken ? "eye" : "eye.slash")
                            .font(.caption2)
                            .foregroundColor(DSColor.onSurfaceVariant)
                    }
                    .buttonStyle(.plain)
                }
            }
            Group {
                if secure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .font(.body.monospaced())
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier(identifier)
        }
        .padding(.vertical, 4)
    }

    private func saveCredentials() {
        let id = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)

        if id.isEmpty {
            KeychainHelper.deleteAPIKey(for: ApiKeyKind.doubaoASRAppID.rawValue)
        } else {
            KeychainHelper.setAPIKey(id, for: ApiKeyKind.doubaoASRAppID.rawValue)
        }
        if token.isEmpty {
            KeychainHelper.deleteAPIKey(for: ApiKeyKind.doubaoASRAccessToken.rawValue)
        } else {
            KeychainHelper.setAPIKey(token, for: ApiKeyKind.doubaoASRAccessToken.rawValue)
        }
        appID = id
        accessToken = token

        // New credentials — any previous verification verdict is stale.
        DoubaoVerification.invalidate()
        stateRefresh = UUID()
        Haptics.success()
        bannerCenter.show(AppBannerModel(
            kind: .success,
            title: NSLocalizedString("settings.doubao.saved.banner", comment: "Credentials saved banner"),
            autoDismiss: true
        ))
    }

    // MARK: Real-transcription test

    private var testSection: some View {
        Section {
            Button {
                Task {
                    await tester.run()
                    stateRefresh = UUID()
                }
            } label: {
                HStack {
                    Label(
                        tester.isRunning
                            ? NSLocalizedString("settings.doubao.test.running", comment: "Test in progress")
                            : NSLocalizedString("settings.doubao.test.run", comment: "Run real transcription test"),
                        systemImage: "waveform.badge.mic"
                    )
                    Spacer()
                    if tester.isRunning {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(tester.isRunning || !DoubaoASRConfig.hasCredentials || isDirty)
            .accessibilityIdentifier("doubao-run-test-button")

            if isDirty {
                Label(NSLocalizedString("settings.doubao.test.save_first", comment: "Save before testing hint"),
                      systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundColor(DSColor.statusWarning)
            }

            stepRow(
                title: NSLocalizedString("settings.doubao.step.credentials", comment: "Credentials check step"),
                state: tester.credentialStep
            )
            stepRow(
                title: NSLocalizedString("settings.doubao.step.file", comment: "File endpoint step"),
                subtitle: "volc.bigasr.auc_turbo",
                state: tester.fileStep
            )
            stepRow(
                title: NSLocalizedString("settings.doubao.step.stream", comment: "Streaming endpoint step"),
                subtitle: "volc.bigasr.sauc.duration",
                state: tester.streamStep
            )
        } header: {
            Text(NSLocalizedString("settings.doubao.test.section", comment: "Real transcription test header"))
        } footer: {
            Text(String(format: NSLocalizedString("settings.doubao.test.footer", comment: "Explains the sample phrase"), DoubaoConnectivityTester.expectedPhrase))
                .font(.caption)
        }
    }

    @ViewBuilder
    private func stepRow(title: String, subtitle: String? = nil, state: DoubaoConnectivityTester.StepState) -> some View {
        HStack(alignment: .top, spacing: DSSpacing.sm) {
            stepIcon(state)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                if let subtitle {
                    Text(subtitle)
                        .font(DSType.mono9)
                        .foregroundColor(DSColor.inkSubtle)
                }
                switch state {
                case .passed(let detail):
                    Text(detail)
                        .font(.caption)
                        .foregroundColor(DSColor.statusSuccess)
                        .fixedSize(horizontal: false, vertical: true)
                case .failed(let message):
                    Text(message)
                        .font(.caption)
                        .foregroundColor(DSColor.statusError)
                        .fixedSize(horizontal: false, vertical: true)
                case .idle, .running:
                    EmptyView()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func stepIcon(_ state: DoubaoConnectivityTester.StepState) -> some View {
        switch state {
        case .idle:
            Image(systemName: "circle.dotted")
                .font(.subheadline)
                .foregroundColor(DSColor.inkSubtle)
        case .running:
            ProgressView().controlSize(.mini)
        case .passed:
            Image(systemName: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundColor(DSColor.statusSuccess)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.subheadline)
                .foregroundColor(DSColor.statusError)
        }
    }
}

#Preview {
    NavigationStack { DoubaoConfigView() }
}
