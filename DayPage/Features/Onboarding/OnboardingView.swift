import SwiftUI
import CoreLocation
import AVFoundation
import UserNotifications

// MARK: - OnboardingView

struct OnboardingView: View {

    @State private var currentPage: Int = 0
    @Binding var hasOnboarded: Bool

    var body: some View {
        TabView(selection: $currentPage) {
            WelcomePage(onNext: { currentPage = 1 })
                .tag(0)
            PermissionsPage(onNext: { currentPage = 2 })
                .tag(1)
            // P0 privacy disclosure: must appear BEFORE ApiKeysPage so the
            // user understands which data leaves the device, and to which
            // provider, before they paste any secrets. Issue #25.
            DataFlowPage(onNext: { currentPage = 3 })
                .tag(2)
            ApiKeysPage(onComplete: {
                UserDefaults.standard.set(true, forKey: AppSettings.Keys.hasOnboarded)
                SampleDataSeeder.seedIfNeeded()
                hasOnboarded = true
            })
            .tag(3)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .background(DSColor.backgroundWarm.ignoresSafeArea())
        .tint(DSColor.accentAmber)
    }
}

// MARK: - Page 2.5: Data Flow Disclosure

/// Per-modality outbound-network disclosure shown before the API-keys page.
///
/// DayPage is local-first but optional features (voice transcription, AI
/// daily compilation, weather metadata) DO send data to third-party
/// providers when the user supplies the corresponding API key. The page
/// lists every modality, what bytes leave the device, and to which vendor
/// — so the user can decide which keys to paste on the next page.
///
/// Wording deliberately avoids any "we track you" framing: DayPage itself
/// has no server. The disclosed traffic is the user's own request to the
/// third-party API. The user accepts the disclosure by tapping Continue;
/// the consent flag is persisted so this page is shown exactly once.
private struct DataFlowPage: View {
    let onNext: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Spacer(minLength: 48)

                Image(systemName: "lock.shield")
                    .font(.system(size: 44, weight: .light))
                    .foregroundColor(DSColor.accentAmber)
                    .padding(.bottom, 4)

                Text("onboarding.dataflow.title", bundle: .main)
                    .h1()
                    .foregroundColor(DSColor.onBackgroundPrimary)
                    .multilineTextAlignment(.center)

                Text("onboarding.dataflow.subtitle", bundle: .main)
                    .captionText()
                    .foregroundColor(DSColor.onBackgroundMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)

                VStack(spacing: 12) {
                    DataFlowRow(
                        icon: "mic.fill",
                        feature: NSLocalizedString("onboarding.dataflow.voice.feature", comment: ""),
                        payload: NSLocalizedString("onboarding.dataflow.voice.payload", comment: ""),
                        destination: NSLocalizedString("onboarding.dataflow.voice.destination", comment: "")
                    )
                    DataFlowRow(
                        icon: "sparkles",
                        feature: NSLocalizedString("onboarding.dataflow.compile.feature", comment: ""),
                        payload: NSLocalizedString("onboarding.dataflow.compile.payload", comment: ""),
                        destination: NSLocalizedString("onboarding.dataflow.compile.destination", comment: "")
                    )
                    DataFlowRow(
                        icon: "cloud.sun.fill",
                        feature: NSLocalizedString("onboarding.dataflow.weather.feature", comment: ""),
                        payload: NSLocalizedString("onboarding.dataflow.weather.payload", comment: ""),
                        destination: NSLocalizedString("onboarding.dataflow.weather.destination", comment: "")
                    )
                    DataFlowRow(
                        icon: "photo.fill",
                        feature: NSLocalizedString("onboarding.dataflow.photo.feature", comment: ""),
                        payload: NSLocalizedString("onboarding.dataflow.photo.payload", comment: ""),
                        destination: NSLocalizedString("onboarding.dataflow.photo.destination", comment: "")
                    )
                    DataFlowRow(
                        icon: "ant.fill",
                        feature: NSLocalizedString("onboarding.dataflow.sentry.feature", comment: ""),
                        payload: NSLocalizedString("onboarding.dataflow.sentry.payload", comment: ""),
                        destination: NSLocalizedString("onboarding.dataflow.sentry.destination", comment: "")
                    )
                }

                Text("onboarding.dataflow.footer", bundle: .main)
                    .captionText()
                    .foregroundColor(DSColor.onBackgroundMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)

                Button(action: {
                    // Persist consent so future builds (and the API-keys
                    // settings screen) can verify the user saw this
                    // disclosure before any third-party traffic.
                    UserDefaults.standard.set(
                        Date().timeIntervalSince1970,
                        forKey: AppSettings.Keys.dataFlowDisclosureAcceptedAt
                    )
                    onNext()
                }) {
                    Text("onboarding.dataflow.continue", bundle: .main)
                        .bodyText()
                        .foregroundColor(DSColor.surfaceWhite)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(DSColor.accentAmber)
                        .cornerRadius(DSSpacing.radiusCard)
                }
                .padding(.top, 8)
                .accessibilityIdentifier("onboarding.dataflow.continue")

                Spacer(minLength: 48)
            }
            .padding(.horizontal, 24)
        }
    }
}

private struct DataFlowRow: View {
    let icon: String
    let feature: String
    let payload: String
    let destination: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(DSColor.accentAmber)
                .frame(width: 28)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(feature)
                    .bodyText()
                    .foregroundColor(DSColor.onBackgroundPrimary)
                Text(payload)
                    .captionText()
                    .foregroundColor(DSColor.onBackgroundMuted)
                Text(destination)
                    .captionText()
                    .foregroundColor(DSColor.accentAmber)
            }

            Spacer()
        }
        .padding(DSSpacing.cardInner)
        .background(DSColor.surfaceWhite)
        .cornerRadius(DSSpacing.radiusCard)
        .surfaceElevatedShadow()
    }
}

// MARK: - Page 1: Welcome

private struct WelcomePage: View {
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Illustration
            ZStack {
                Circle()
                    .fill(DSColor.accentSoft)
                    .frame(width: 120, height: 120)
                Image(systemName: "pencil.and.scribble")
                    .font(.system(size: 48, weight: .light))
                    .foregroundColor(DSColor.accentAmber)
            }

            VStack(spacing: 12) {
                Text("DayPage")
                    .h1()
                    .foregroundColor(DSColor.onBackgroundPrimary)

                Text("onboarding.welcome.slogan", bundle: .main)
                    .bodyText()
                    .foregroundColor(DSColor.onBackgroundMuted)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            Button(action: onNext) {
                Text("onboarding.welcome.begin", bundle: .main)
                    .bodyText()
                    .foregroundColor(DSColor.surfaceWhite)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(DSColor.accentAmber)
                    .cornerRadius(DSSpacing.radiusCard)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
        }
        .padding(.horizontal, 24)
    }
}

// MARK: - Page 2: Permissions

private struct PermissionsPage: View {
    let onNext: () -> Void

    @State private var micStatus: PermissionStatus = .unknown
    @State private var locationStatus: PermissionStatus = .unknown
    @State private var notifStatus: PermissionStatus = .unknown

    private enum PermissionStatus {
        case unknown, granted, denied
        var label: String {
            switch self {
            case .unknown: return NSLocalizedString("onboarding.permissions.status.unknown", comment: "")
            case .granted: return NSLocalizedString("onboarding.permissions.status.granted", comment: "")
            case .denied: return NSLocalizedString("onboarding.permissions.status.denied", comment: "")
            }
        }
        var color: Color {
            switch self {
            case .unknown: return DSColor.accentAmber
            case .granted: return DSColor.successGreen
            case .denied: return DSColor.errorRed
            }
        }
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("onboarding.permissions.title", bundle: .main)
                .h1()
                .foregroundColor(DSColor.onBackgroundPrimary)

            Text("onboarding.permissions.subtitle", bundle: .main)
                .captionText()
                .foregroundColor(DSColor.onBackgroundMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)

            VStack(spacing: 12) {
                permissionCard(
                    icon: "mic.fill",
                    title: NSLocalizedString("onboarding.permissions.mic.title", comment: ""),
                    description: NSLocalizedString("onboarding.permissions.mic.description", comment: ""),
                    status: micStatus
                ) {
                    requestMicrophone()
                }

                permissionCard(
                    icon: "location.fill",
                    title: NSLocalizedString("onboarding.permissions.location.title", comment: ""),
                    description: NSLocalizedString("onboarding.permissions.location.description", comment: ""),
                    status: locationStatus
                ) {
                    requestLocation()
                }

                permissionCard(
                    icon: "bell.fill",
                    title: NSLocalizedString("onboarding.permissions.notifications.title", comment: ""),
                    description: NSLocalizedString("onboarding.permissions.notifications.description", comment: ""),
                    status: notifStatus
                ) {
                    requestNotifications()
                }
            }

            Spacer()

            Button(action: onNext) {
                Text("onboarding.permissions.next", bundle: .main)
                    .bodyText()
                    .foregroundColor(DSColor.surfaceWhite)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(DSColor.accentAmber)
                    .cornerRadius(DSSpacing.radiusCard)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
        }
        .padding(.horizontal, 24)
        .onAppear { checkCurrentStatuses() }
    }

    private func permissionCard(
        icon: String,
        title: String,
        description: String,
        status: PermissionStatus,
        onGrant: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(DSColor.accentAmber)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).bodyText().foregroundColor(DSColor.onBackgroundPrimary)
                Text(description).captionText().foregroundColor(DSColor.onBackgroundMuted)
            }

            Spacer()

            Button(action: onGrant) {
                Text(status.label)
                    .captionText()
                    .foregroundColor(status == .unknown ? DSColor.surfaceWhite : status.color)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(status == .unknown ? DSColor.accentAmber : DSColor.surfaceSunken)
                    .cornerRadius(DSSpacing.radiusSmall)
            }
            .disabled(status != .unknown)
        }
        .padding(DSSpacing.cardInner)
        .background(DSColor.surfaceWhite)
        .cornerRadius(DSSpacing.radiusCard)
        .surfaceElevatedShadow()
    }

    private func checkCurrentStatuses() {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: micStatus = .granted
        case .denied: micStatus = .denied
        default: micStatus = .unknown
        }

        let locAuth = CLLocationManager().authorizationStatus
        switch locAuth {
        case .authorizedAlways, .authorizedWhenInUse: locationStatus = .granted
        case .denied, .restricted: locationStatus = .denied
        default: locationStatus = .unknown
        }

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
                case .authorized, .provisional: notifStatus = .granted
                case .denied: notifStatus = .denied
                default: notifStatus = .unknown
                }
            }
        }
    }

    private func requestMicrophone() {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async {
                micStatus = granted ? .granted : .denied
            }
        }
    }

    private func requestLocation() {
        LocationService.shared.requestPermissionIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            checkCurrentStatuses()
        }
    }

    private func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async {
                notifStatus = granted ? .granted : .denied
            }
        }
    }
}

// MARK: - Page 3: API Keys

private struct ApiKeysPage: View {
    let onComplete: () -> Void

    @State private var deepSeekKey: String = ""
    @State private var openAIKey: String = ""
    @State private var openWeatherKey: String = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 48)

                Text("onboarding.apikeys.title", bundle: .main)
                    .h1()
                    .foregroundColor(DSColor.onBackgroundPrimary)

                Text("onboarding.apikeys.subtitle", bundle: .main)
                    .captionText()
                    .foregroundColor(DSColor.onBackgroundMuted)
                    .multilineTextAlignment(.center)

                VStack(spacing: 12) {
                    apiKeyField(
                        label: NSLocalizedString("onboarding.apikeys.deepseek.label", comment: ""),
                        placeholder: "sk-...",
                        text: $deepSeekKey
                    )
                    apiKeyField(
                        label: NSLocalizedString("onboarding.apikeys.openai.label", comment: ""),
                        placeholder: "sk-...",
                        text: $openAIKey
                    )
                    apiKeyField(
                        label: NSLocalizedString("onboarding.apikeys.openweather.label", comment: ""),
                        placeholder: "xxxxxxxx",
                        text: $openWeatherKey
                    )
                }

                Button(action: saveAndComplete) {
                    Text("onboarding.apikeys.complete", bundle: .main)
                        .bodyText()
                        .foregroundColor(DSColor.surfaceWhite)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(DSColor.accentAmber)
                        .cornerRadius(DSSpacing.radiusCard)
                }
                .padding(.top, 8)

                Spacer(minLength: 48)
            }
            .padding(.horizontal, 24)
        }
    }

    private func apiKeyField(label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .captionText()
                .foregroundColor(DSColor.onBackgroundMuted)

            HStack {
                SecureField(placeholder, text: text)
                    .bodyText()
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                Button("粘贴") {
                    if let s = UIPasteboard.general.string {
                        text.wrappedValue = s
                    }
                }
                .captionText()
                .foregroundColor(DSColor.accentAmber)
            }
            .padding(12)
            .background(DSColor.surfaceSunken)
            .cornerRadius(DSSpacing.radiusSmall)
        }
    }

    private func saveAndComplete() {
        // US-002: API keys are stored in Keychain (not UserDefaults) to prevent iCloud backup exposure.
        if !deepSeekKey.isEmpty {
            KeychainHelper.setAPIKey(deepSeekKey, for: "deepSeekApiKey")
        }
        if !openAIKey.isEmpty {
            KeychainHelper.setAPIKey(openAIKey, for: "openAIWhisperApiKey")
        }
        if !openWeatherKey.isEmpty {
            KeychainHelper.setAPIKey(openWeatherKey, for: "openWeatherApiKey")
        }
        onComplete()
    }
}
