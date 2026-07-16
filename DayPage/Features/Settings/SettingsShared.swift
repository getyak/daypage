import SwiftUI
import DayPageStorage
import DayPageServices

// MARK: - ApiKeyKind

/// B2: single source of truth for every API key identifier persisted in the
/// `com.daypage.apikeys` Keychain service. Settings rows and
/// `purgeAllLocalData` both consume this so the two cannot drift.
///
/// `rawValue` MUST match the historical identifier strings the rest of the
/// codebase (Onboarding/ApiKeysPage, Secrets resolution helpers) already
/// uses — renaming them would orphan existing user keychain entries.
///
/// `doubaoASRSecretKey` stays listed for purge coverage of legacy entries,
/// but has no UI anymore: nothing in the codebase ever consumed it.
enum ApiKeyKind: String, CaseIterable {
    case deepSeek             = "deepSeekApiKey"
    case openAIWhisper        = "openAIWhisperApiKey"
    case openWeather          = "openWeatherApiKey"
    case doubaoASRAppID       = "doubaoASRAppID"
    case doubaoASRAccessToken = "doubaoASRAccessToken"
    case doubaoASRSecretKey   = "doubaoASRSecretKey"
}

// MARK: - APITestResult

enum APITestResult {
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

// MARK: - API test result row

struct APITestResultRow: View {
    let result: APITestResult

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: result.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(result.isSuccess ? DSColor.statusSuccess : DSColor.statusError)
            Text(result.message)
                .font(.caption)
                .foregroundColor(result.isSuccess ? DSColor.statusSuccess : DSColor.statusError)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - ApiKeyRowView

/// One credential row: masked value + reveal, edit, and (optionally) a test
/// button that actually does something — rows without a test handler render
/// no button at all, never a dead one.
struct ApiKeyRowView: View {
    let name: String
    let keychainID: String
    let key: String
    let isTesting: Bool
    let result: APITestResult?
    /// nil = this row has no connectivity test; no button is rendered.
    let onTest: (() -> Void)?
    let providerID: String
    var isRequired: Bool = false
    let onEdit: () -> Void

    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: DSSpacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.body)
                    if !key.isEmpty {
                        Text(revealed ? key : "••••••••" + String(key.suffix(2)))
                            .font(DSType.labelSM)
                            .foregroundColor(DSColor.onSurfaceVariant)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .accessibilityIdentifier("api-key-value-\(providerID)")
                    }
                }
                Spacer()

                if !key.isEmpty {
                    Button {
                        revealed.toggle()
                    } label: {
                        Image(systemName: revealed ? "eye" : "eye.slash")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(NSLocalizedString("settings.apikey.reveal.label", comment: ""))
                    .accessibilityIdentifier("api-key-reveal-button-\(providerID)")
                }

                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("api-key-edit-button-\(providerID)")

                if key.isEmpty {
                    Text(isRequired
                         ? NSLocalizedString("settings.apikey.unconfigured", comment: "")
                         : NSLocalizedString("settings.apikey.optional", comment: ""))
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, DSSpacing.sm)
                        .padding(.vertical, 2)
                        .background((isRequired ? Color.red : DSColor.inkSubtle).opacity(0.12))
                        .foregroundColor(isRequired ? .red : DSColor.inkSubtle)
                        .clipShape(Capsule())
                } else if let onTest {
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
                APITestResultRow(result: result)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - ApiKeyEditorSheet

/// Shared editor for single-value credentials (DeepSeek / Whisper / weather).
/// Copy is deliberately generic — the old sheet titled every value "API Key"
/// and hinted "sk-…", which was wrong for most of them.
struct ApiKeyEditorSheet: View {
    let keyName: String
    let keychainID: String
    /// Called after save/clear so the presenting list can refresh.
    let onCommit: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var value: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: DSSpacing.xl) {
                Text(String(format: NSLocalizedString("settings.apikey.editor.title", comment: ""), keyName))
                    .font(.headline)
                    .padding(.top, DSSpacing.sm)

                SecureField(NSLocalizedString("settings.apikey.editor.placeholder", comment: ""), text: $value)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(DSSpacing.md)
                    .dpGlass(.control, in: RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous))
                    .padding(.horizontal)

                HStack {
                    Button(NSLocalizedString("settings.apikey.editor.paste", comment: "")) {
                        if let s = UIPasteboard.general.string { value = s }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(NSLocalizedString("settings.apikey.paste.label", comment: ""))
                    .accessibilityIdentifier("api-key-paste-button")

                    Spacer()

                    Button(NSLocalizedString("settings.apikey.editor.clear", comment: "")) {
                        value = ""
                    }
                    .buttonStyle(.bordered)
                    .tint(DSColor.statusError)
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
                    Button(NSLocalizedString("settings.apikey.editor.cancel", comment: "")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("settings.apikey.editor.save", comment: "")) {
                        // Trim whitespace AND newlines — pasted keys frequently
                        // carry a trailing `\n` which silently 401s the
                        // Authorization header.
                        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty {
                            KeychainHelper.deleteAPIKey(for: keychainID)
                        } else {
                            KeychainHelper.setAPIKey(trimmed, for: keychainID)
                        }
                        onCommit()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .accessibilityLabel(NSLocalizedString("settings.apikey.save.label", comment: ""))
                    .accessibilityIdentifier("api-key-save-button")
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear {
            value = KeychainHelper.getAPIKey(for: keychainID) ?? ""
        }
    }
}

// MARK: - SettingsLabel

/// Label with an explicitly amber-tinted icon. Settings rows used to rely on
/// the List's `.tint(...)` environment for icon color, which SwiftUI drops
/// on row reuse — the same row rendered brand-amber on one pass and system
/// blue on the next. Explicit `foregroundStyle` on the icon is immune.
struct SettingsLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label {
            Text(title)
                .foregroundColor(DSColor.onSurface)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(DSColor.accentOnBg)
        }
    }
}

// MARK: - VerifyBadge

/// Small capsule communicating a four-state verification verdict.
struct VerifyBadge: View {
    enum Kind {
        case neutral   // 未配置
        case pending   // 已填未验证
        case ok        // 已验证
        case error     // 验证失败
    }

    let kind: Kind
    let text: String

    private var fg: Color {
        switch kind {
        case .neutral: return DSColor.inkSubtle
        case .pending: return DSColor.statusWarning
        case .ok:      return DSColor.statusSuccess
        case .error:   return DSColor.statusError
        }
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, DSSpacing.sm)
            .padding(.vertical, 2)
            .background(fg.opacity(0.12))
            .foregroundColor(fg)
            .clipShape(Capsule())
    }
}

// MARK: - Doubao badge helper

extension DoubaoVerification.State {
    var badgeKind: VerifyBadge.Kind {
        switch self {
        case .notConfigured: return .neutral
        case .unverified:    return .pending
        case .verified:      return .ok
        case .failed:        return .error
        }
    }

    var badgeText: String {
        switch self {
        case .notConfigured:
            return NSLocalizedString("settings.doubao.state.not_configured", comment: "")
        case .unverified:
            return NSLocalizedString("settings.doubao.state.unverified", comment: "")
        case .verified:
            return NSLocalizedString("settings.doubao.state.verified", comment: "")
        case .failed:
            return NSLocalizedString("settings.doubao.state.failed", comment: "")
        }
    }
}

// MARK: - Network error hints (shared by connectivity tests)

enum SettingsTestHints {

    static func network(_ error: Error) -> String {
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

    static func deepSeek(status: Int) -> String {
        switch status {
        case 401, 403: return NSLocalizedString("settings.test.hint.key_invalid_or_forbidden", comment: "")
        case 404: return NSLocalizedString("settings.test.hint.url_not_found", comment: "")
        case 429: return NSLocalizedString("settings.test.hint.rate_limited", comment: "")
        case 500...599: return NSLocalizedString("settings.test.hint.server_error", comment: "")
        default: return NSLocalizedString("settings.test.hint.request_failed", comment: "")
        }
    }

    static func openAI(status: Int) -> String {
        switch status {
        case 401, 403: return NSLocalizedString("settings.test.hint.key_invalid_or_forbidden", comment: "")
        case 404: return NSLocalizedString("settings.test.hint.url_not_found", comment: "")
        case 429: return NSLocalizedString("settings.test.hint.rate_or_quota", comment: "")
        case 500...599: return NSLocalizedString("settings.test.hint.server_error", comment: "")
        default: return NSLocalizedString("settings.test.hint.request_failed", comment: "")
        }
    }

    static func openWeather(status: Int) -> String {
        switch status {
        case 401: return NSLocalizedString("settings.test.hint.key_invalid", comment: "")
        case 404: return NSLocalizedString("settings.test.hint.url_not_found_short", comment: "")
        case 429: return NSLocalizedString("settings.test.hint.free_quota_exhausted", comment: "")
        case 500...599: return NSLocalizedString("settings.test.hint.server_error", comment: "")
        default: return NSLocalizedString("settings.test.hint.request_failed", comment: "")
        }
    }
}
