import SwiftUI
import AVFoundation
import DayPageStorage
import DayPageServices

// MARK: - SettingsAIVoiceView

/// "AI 与语音" — everything a user reaches for when compilation or dictation
/// misbehaves, in one place: the LLM engine (credentials, usage, budget), the
/// speech-to-text stack (provider, Doubao pair + real test, Whisper key, mic
/// permission), and other external services (weather).
///
/// This page absorbs what used to be scattered across three sections: the
/// old "API Keys" list, the ASR rows hidden inside "Appearance", and the
/// microphone row in "Permissions".
@MainActor
struct SettingsAIVoiceView: View {

    @StateObject private var bannerCenter = BannerCenter.shared
    @StateObject private var usageTracker = LLMUsageTracker.shared

    // C4: master switch for any third-party AI/cloud call.
    @AppStorage(AppSettings.Keys.aiFeaturesEnabled) private var aiFeaturesEnabled: Bool = true

    // Press-to-talk fallback toggle (US-008).
    @AppStorage(AppSettings.Keys.usePressToTalk) private var usePressToTalk: Bool = true

    @State private var asrProvider: ASRProvider = ASRSettings.active
    @State private var monthlyBudget: Int = LLMUsageTracker.shared.monthlyBudget

    // Per-key test state
    @State private var deepSeekTesting = false
    @State private var whisperTesting = false
    @State private var weatherTesting = false
    @State private var deepSeekResult: APITestResult?
    @State private var whisperResult: APITestResult?
    @State private var weatherResult: APITestResult?

    // Editor sheet
    @State private var editingKeyName = ""
    @State private var editingKeyID = ""
    @State private var showApiKeyEditor = false
    @State private var keyRefreshToken = UUID()

    var body: some View {
        List {
            Group {
                aiEngineSection
                aiUsageSection
                voiceSection
                otherServicesSection
            }
            .listRowBackground(DSColor.surfaceWhite)
        }
        .scrollContentBackground(.hidden)
        .background(DSColor.bgWarm.ignoresSafeArea())
        .tint(DSColor.primary)
        .navigationTitle(NSLocalizedString("settings.hub.aivoice", comment: "AI & Voice page title"))
        .navigationBarTitleDisplayMode(.inline)
        // Popping back from DoubaoConfigView must refresh the verification
        // badge, which is computed off UserDefaults and not observable.
        .onAppear { keyRefreshToken = UUID() }
        .bannerOverlay()
        .sheet(isPresented: $showApiKeyEditor) {
            ApiKeyEditorSheet(keyName: editingKeyName, keychainID: editingKeyID) {
                keyRefreshToken = UUID()
            }
        }
    }

    // MARK: AI Engine

    private var aiEngineSection: some View {
        Section {
            let _ = keyRefreshToken
            Toggle(isOn: $aiFeaturesEnabled) {
                SettingsLabel(title: NSLocalizedString("settings.ai.enabled", comment: "AI features master toggle"), systemImage: "sparkles")
            }
            ApiKeyRowView(
                name: "DeepSeek",
                keychainID: ApiKeyKind.deepSeek.rawValue,
                key: Secrets.resolvedDeepSeekApiKey,
                isTesting: deepSeekTesting,
                result: deepSeekResult,
                onTest: { Task { await testDeepSeek() } },
                providerID: "deepseek",
                isRequired: true,
                onEdit: { edit(name: "DeepSeek", id: ApiKeyKind.deepSeek.rawValue) }
            )
            infoRow(label: NSLocalizedString("settings.ai.model", comment: ""), systemImage: "cpu", value: aiModelName)
            infoRow(label: NSLocalizedString("settings.ai.provider", comment: ""), systemImage: "server.rack", value: aiProviderName)
            infoRow(label: NSLocalizedString("settings.ai.endpoint", comment: ""), systemImage: "network", value: aiEndpointDisplay, truncate: true)
        } header: {
            Text(NSLocalizedString("settings.ai.section_title", comment: ""))
        } footer: {
            Text(NSLocalizedString("settings.ai.footer", comment: ""))
                .font(.caption)
        }
    }

    private var aiUsageSection: some View {
        Section {
            let usage = usageTracker.currentMonthUsage()
            infoRow(
                label: NSLocalizedString("settings.ai.usage.month_total", comment: "Month-to-date estimated usage"),
                systemImage: "gauge.with.needle",
                value: String(format: NSLocalizedString("settings.ai.usage.tokens_format", comment: ""), usage.totalTokens)
            )
            infoRow(
                label: NSLocalizedString("settings.ai.usage.active_days", comment: "Active days row"),
                systemImage: "calendar",
                value: "\(usage.daysWithActivity) / 30"
            )
            Stepper(value: $monthlyBudget, in: 0...5_000_000, step: 50_000) {
                HStack {
                    SettingsLabel(title: NSLocalizedString("settings.ai.usage.budget", comment: "Monthly budget"), systemImage: "target")
                    Spacer()
                    Text(monthlyBudget == 0
                         ? NSLocalizedString("settings.ai.usage.budget.unset", comment: "")
                         : "\(monthlyBudget)")
                        .foregroundColor(DSColor.onSurfaceVariant)
                        .font(DSType.labelSM)
                }
            }
            .onChange(of: monthlyBudget) { newValue in
                usageTracker.monthlyBudget = newValue
            }
            if usageTracker.hasCrossedBudgetWarning {
                HStack(spacing: DSSpacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(DSColor.accentOnBg)
                    Text(NSLocalizedString("settings.ai.usage.warning", comment: "80% budget warning"))
                        .font(DSType.labelSM)
                        .foregroundColor(DSColor.inkPrimary)
                }
                .padding(DSSpacing.sm)
                .background(DSColor.amberSoft)
                .cornerRadius(8)
                .accessibilityIdentifier("settings.ai.usage.warning")
            }
        } header: {
            Text(NSLocalizedString("settings.ai.usage.section", comment: "AI usage section header"))
        } footer: {
            Text(NSLocalizedString("settings.ai.usage.footer", comment: "How usage is estimated"))
                .font(.caption)
        }
    }

    // MARK: Voice

    private var voiceSection: some View {
        Section {
            let _ = keyRefreshToken
            // Speech-to-text backend. Every provider degrades to on-device
            // recognition when its credentials are missing, so switching here
            // can reduce transcription quality but never break capture.
            Picker(selection: $asrProvider) {
                ForEach(ASRProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            } label: {
                SettingsLabel(title: NSLocalizedString("settings.voice.asr_provider", comment: "Speech-to-text backend"), systemImage: "waveform")
            }
            .accessibilityIdentifier("asr-provider-picker")
            .onChange(of: asrProvider) { newValue in
                Haptics.selection()
                ASRSettings.override = newValue
            }

            // Doubao unified credentials + real transcription test.
            NavigationLink {
                DoubaoConfigView()
            } label: {
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(NSLocalizedString("settings.doubao.title", comment: ""))
                            Text(NSLocalizedString("settings.doubao.row.subtitle", comment: "App ID + Access Token"))
                                .font(DSType.labelSM)
                                .foregroundColor(DSColor.onSurfaceVariant)
                        }
                    } icon: {
                        Image(systemName: "waveform.badge.mic")
                            .foregroundStyle(DSColor.accentOnBg)
                    }
                    Spacer()
                    let state = DoubaoVerification.state
                    VerifyBadge(kind: state.badgeKind, text: state.badgeText)
                }
            }
            .accessibilityIdentifier("doubao-config-link")

            ApiKeyRowView(
                name: "OpenAI Whisper",
                keychainID: ApiKeyKind.openAIWhisper.rawValue,
                key: Secrets.resolvedOpenAIWhisperApiKey,
                isTesting: whisperTesting,
                result: whisperResult,
                onTest: { Task { await testWhisper() } },
                providerID: "whisper",
                onEdit: { edit(name: "OpenAI Whisper", id: ApiKeyKind.openAIWhisper.rawValue) }
            )

            // Microphone permission, inline — the third place users used to
            // hunt for when dictation failed.
            HStack {
                SettingsLabel(title: NSLocalizedString("settings.permission.mic", comment: ""), systemImage: "mic.fill")
                Spacer()
                micStatusView
            }
            .contentShape(Rectangle())
            .onTapGesture { openSystemSettings() }

            // Press-to-talk (US-008). Inverted binding: the visible label
            // reads "use legacy voice recording" per the PRD's copy.
            Toggle(isOn: Binding(
                get: { !usePressToTalk },
                set: {
                    Haptics.selection()
                    usePressToTalk = !$0
                }
            )) {
                SettingsLabel(title: NSLocalizedString("settings.appearance.legacy_voice", comment: ""), systemImage: "mic.circle")
            }
        } header: {
            Text(NSLocalizedString("settings.voice.section", comment: "Voice section header"))
        } footer: {
            Text(NSLocalizedString("settings.voice.footer", comment: "Degradation behaviour explainer"))
                .font(.caption)
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

    // MARK: Other services

    private var otherServicesSection: some View {
        Section {
            let _ = keyRefreshToken
            ApiKeyRowView(
                name: "OpenWeatherMap",
                keychainID: ApiKeyKind.openWeather.rawValue,
                key: Secrets.resolvedOpenWeatherApiKey,
                isTesting: weatherTesting,
                result: weatherResult,
                onTest: { Task { await testWeather() } },
                providerID: "openweather",
                onEdit: { edit(name: "OpenWeatherMap", id: ApiKeyKind.openWeather.rawValue) }
            )
        } header: {
            Text(NSLocalizedString("settings.services.section", comment: "Other services header"))
        } footer: {
            Text(NSLocalizedString("settings.services.footer", comment: "What weather key is used for"))
                .font(.caption)
        }
    }

    // MARK: Helpers

    private func edit(name: String, id: String) {
        editingKeyName = name
        editingKeyID = id
        showApiKeyEditor = true
    }

    @ViewBuilder
    private func infoRow(label: String, systemImage: String, value: String, truncate: Bool = false) -> some View {
        HStack {
            SettingsLabel(title: label, systemImage: systemImage)
            Spacer()
            Text(value)
                .foregroundColor(DSColor.onSurfaceVariant)
                .font(DSType.labelSM)
                .lineLimit(1)
                .truncationMode(truncate ? .middle : .tail)
        }
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
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

    // MARK: Connectivity tests

    private func testDeepSeek() async {
        deepSeekTesting = true
        deepSeekResult = nil
        defer { deepSeekTesting = false }

        let key = Secrets.resolvedDeepSeekApiKey
        guard !key.isEmpty else { return }

        // Mirror CompilationService.callDeepSeek URL resolution so the test
        // hits the same endpoint production does.
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
                deepSeekResult = .failure("HTTP \(code) · \(SettingsTestHints.deepSeek(status: code))")
            }
        } catch {
            deepSeekResult = .failure(SettingsTestHints.network(error))
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
                whisperResult = .failure("HTTP \(code) · \(SettingsTestHints.openAI(status: code))")
            }
        } catch {
            whisperResult = .failure(SettingsTestHints.network(error))
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
                weatherResult = .failure("HTTP \(code) · \(SettingsTestHints.openWeather(status: code))")
            }
        } catch {
            weatherResult = .failure(SettingsTestHints.network(error))
        }
    }
}

#Preview {
    NavigationStack { SettingsAIVoiceView() }
}
