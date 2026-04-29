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
            ApiKeysPage(onComplete: {
                UserDefaults.standard.set(true, forKey: AppSettings.Keys.hasOnboarded)
                SampleDataSeeder.seedIfNeeded()
                hasOnboarded = true
            })
            .tag(2)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .background(DSColor.backgroundWarm.ignoresSafeArea())
        .tint(DSColor.accentAmber)
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

                Text("Dump today, let AI compile tomorrow")
                    .bodyText()
                    .foregroundColor(DSColor.onBackgroundMuted)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            Button(action: onNext) {
                Text("开始")
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
            case .unknown: return "授权"
            case .granted: return "已授权"
            case .denied: return "已拒绝"
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

            Text("开放权限")
                .h1()
                .foregroundColor(DSColor.onBackgroundPrimary)

            Text("以下权限让 DayPage 更好地服务你，可随时在系统设置中更改")
                .captionText()
                .foregroundColor(DSColor.onBackgroundMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)

            VStack(spacing: 12) {
                permissionCard(
                    icon: "mic.fill",
                    title: "麦克风",
                    description: "录音后用 AI 转写成文字",
                    status: micStatus
                ) {
                    requestMicrophone()
                }

                permissionCard(
                    icon: "location.fill",
                    title: "位置",
                    description: "自动记录你在哪里",
                    status: locationStatus
                ) {
                    requestLocation()
                }

                permissionCard(
                    icon: "bell.fill",
                    title: "通知",
                    description: "每日编译完成后提醒你",
                    status: notifStatus
                ) {
                    requestNotifications()
                }
            }

            Spacer()

            Button(action: onNext) {
                Text("下一步")
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

                Text("配置 API Key")
                    .h1()
                    .foregroundColor(DSColor.onBackgroundPrimary)

                Text("填入你的 API Key，或跳过稍后在设置中配置")
                    .captionText()
                    .foregroundColor(DSColor.onBackgroundMuted)
                    .multilineTextAlignment(.center)

                VStack(spacing: 12) {
                    apiKeyField(
                        label: "DeepSeek (AI 编译)",
                        placeholder: "sk-...",
                        text: $deepSeekKey
                    )
                    apiKeyField(
                        label: "OpenAI Whisper (语音转写)",
                        placeholder: "sk-...",
                        text: $openAIKey
                    )
                    apiKeyField(
                        label: "OpenWeather (天气)",
                        placeholder: "xxxxxxxx",
                        text: $openWeatherKey
                    )
                }

                Button(action: saveAndComplete) {
                    Text("开始使用")
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
                TextField(placeholder, text: text)
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
        // API keys are in a generated file; we write to UserDefaults as a runtime override
        // (GeneratedSecrets.swift reads from environment; store in UserDefaults for runtime use)
        if !deepSeekKey.isEmpty {
            UserDefaults.standard.set(deepSeekKey, forKey: AppSettings.Keys.runtimeDeepSeekKey)
        }
        if !openAIKey.isEmpty {
            UserDefaults.standard.set(openAIKey, forKey: AppSettings.Keys.runtimeOpenAIKey)
        }
        if !openWeatherKey.isEmpty {
            UserDefaults.standard.set(openWeatherKey, forKey: AppSettings.Keys.runtimeOpenWeatherKey)
        }
        onComplete()
    }
}
