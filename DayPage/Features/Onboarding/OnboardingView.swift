import SwiftUI
import CoreLocation
import AVFoundation
import UserNotifications
import DayPageStorage
import DayPageServices

// MARK: - OnboardingView

struct OnboardingView: View {

    @State private var currentPage: Int
    @Binding var hasOnboarded: Bool

    init(hasOnboarded: Binding<Bool>) {
        _hasOnboarded = hasOnboarded
        _currentPage = State(initialValue: Self.initialPage(arguments: ProcessInfo.processInfo.arguments))
    }

    static func initialPage(arguments: [String]) -> Int {
#if DEBUG
        guard let flag = arguments.firstIndex(of: "-qaOnboardingPage"),
              arguments.indices.contains(flag + 1),
              let page = Int(arguments[flag + 1]),
              (0...4).contains(page) else { return 0 }
        return page
#else
        return 0
#endif
    }

    var body: some View {
        VStack(spacing: 0) {
            OnboardingProgress(currentPage: currentPage, pageCount: 5)

            TabView(selection: $currentPage) {
                WelcomePage(
                    onNext: { currentPage = 1 },
                    hasOnboarded: $hasOnboarded
                )
                .tag(0)
                PermissionsPage(onNext: { currentPage = 2 })
                    .tag(1)
                // 「记录提醒」引导:紧跟权限页,默认开启,引导用户挑一天一次/三次的
                // 记录节奏,并顺势注册定时提醒。可跳过。
                ReminderPage(onNext: { currentPage = 3 })
                    .tag(2)
                // P0 privacy disclosure: must appear BEFORE ApiKeysPage so the
                // user understands which data leaves the device, and to which
                // provider, before they paste any secrets. Issue #25.
                DataFlowPage(onNext: { currentPage = 4 })
                    .tag(3)
                ApiKeysPage(onComplete: {
                    UserDefaults.standard.set(true, forKey: AppSettings.Keys.hasOnboarded)
                    hasOnboarded = true
                })
                .tag(4)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .background(DSColor.backgroundWarm.ignoresSafeArea())
        .tint(DSColor.accentOnBg)
        .onChange(of: currentPage) { _ in
            // The visual page swipe is obvious but VoiceOver otherwise keeps
            // focus on the button that disappeared. Announce the destination
            // as a screen change so focus restarts in the new page's heading.
            UIAccessibility.post(
                notification: .screenChanged,
                argument: currentPageAnnouncement
            )
        }
    }

    private var currentPageAnnouncement: String {
        let keys = [
            "onboarding.welcome.headline",
            "onboarding.permissions.title",
            "onboarding.reminder.title",
            "onboarding.dataflow.title",
            "onboarding.apikeys.title"
        ]
        return NSLocalizedString(keys[currentPage], comment: "Onboarding page VoiceOver announcement")
    }
}

private struct OnboardingProgress: View {
    let currentPage: Int
    let pageCount: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<pageCount, id: \.self) { page in
                Capsule()
                    .fill(page <= currentPage ? DSColor.accentOnBg : DSColor.surfaceSunken)
                    .frame(maxWidth: .infinity)
                    .frame(height: 3)
            }
        }
        .padding(.horizontal, DSSpacing.xl2)
        .padding(.top, DSSpacing.md)
        .padding(.bottom, DSSpacing.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            String(
                format: NSLocalizedString("onboarding.progress", comment: ""),
                currentPage + 1,
                pageCount
            )
        )
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
// MARK: - Page 1.5: Capture Reminder
//
// 「定时召唤记录」引导页。默认帮用户选好一个记录节奏(一天一次/三次),点
// 「开启提醒」即请求通知权限并注册定时提醒;到点系统会用一条轻通知(灵动岛
// 落点)召唤用户记一句。可「暂不」跳过 —— 之后仍能在设置里开。
private struct ReminderPage: View {
    let onNext: () -> Void

    @State private var selected: ReminderPreset = .once
    @State private var isRequesting = false

    var body: some View {
        ScrollView {
            VStack(spacing: DSSpacing.xl) {
                Spacer(minLength: 48)

                Image(systemName: "bell.badge")
                    .font(.system(size: 44, weight: .light))
                    .foregroundColor(DSColor.accentOnBg)
                    .padding(.bottom, DSSpacing.xs)
                    .accessibilityHidden(true)

                Text("onboarding.reminder.title", bundle: .main)
                    .h1()
                    .foregroundColor(DSColor.onBackgroundPrimary)
                    .multilineTextAlignment(.center)

                Text("onboarding.reminder.subtitle", bundle: .main)
                    .captionText()
                    .foregroundColor(DSColor.onBackgroundMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DSSpacing.md)

                // 频率选择:一天一次(晚) / 早中晚三次。
                VStack(spacing: DSSpacing.md) {
                    ReminderPresetRow(
                        title: NSLocalizedString("settings.reminder.preset.once", comment: ""),
                        detail: NSLocalizedString("onboarding.reminder.once.detail", comment: ""),
                        isSelected: selected == .once,
                        onTap: { selected = .once }
                    )
                    ReminderPresetRow(
                        title: NSLocalizedString("settings.reminder.preset.thrice", comment: ""),
                        detail: NSLocalizedString("onboarding.reminder.thrice.detail", comment: ""),
                        isSelected: selected == .thrice,
                        onTap: { selected = .thrice }
                    )
                }

                Button(action: {
                    guard !isRequesting else { return }
                    isRequesting = true
                    Task { @MainActor in
                        await CaptureReminderService.shared.enableFromOnboarding(preset: selected)
                        isRequesting = false
                        onNext()
                    }
                }) {
                    Text(isRequesting
                         ? NSLocalizedString("onboarding.reminder.enabling", comment: "")
                         : NSLocalizedString("onboarding.reminder.enable", comment: ""))
                }
                .buttonStyle(.dsPrimary(size: .large, font: DSType.bodyMD))
                .disabled(isRequesting)
                .padding(.top, DSSpacing.sm)
                .accessibilityIdentifier("onboarding.reminder.enable")

                Button(action: skipReminders) {
                    Text("onboarding.reminder.skip", bundle: .main)
                        .captionText()
                        .foregroundColor(DSColor.inkTertiaryAA)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("onboarding.reminder.skip")

                Spacer(minLength: 48)
            }
            .padding(.horizontal, DSSpacing.xl2)
        }
    }

    private func skipReminders() {
        // Skipping here is the user's last notification decision in the
        // onboarding journey. Respect it so the app does not throw an
        // uncontextualized system prompt over the first Today screen.
        UserDefaults.standard.set(true, forKey: AppSettings.Keys.hasRequestedNotifications)
        onNext()
    }
}

private struct ReminderPresetRow: View {
    let title: String
    let detail: String
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: DSSpacing.md) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundColor(isSelected ? DSColor.accentAmber : DSColor.onBackgroundMuted)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: DSSpacing.xs) {
                    Text(title)
                        .bodyText()
                        .foregroundColor(DSColor.onBackgroundPrimary)
                    Text(detail)
                        .captionText()
                        .foregroundColor(DSColor.onBackgroundMuted)
                }

                Spacer()
            }
            .padding(DSSpacing.cardInner)
            .background(DSColor.surfaceWhite)
            .cornerRadius(DSRadius.md)
            .overlay(
                RoundedRectangle(cornerRadius: DSRadius.md)
                    .strokeBorder(isSelected ? DSColor.accentAmber : Color.clear, lineWidth: 1.5)
            )
            .surfaceElevatedShadow()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("onboarding.reminder.preset.\(title)")
    }
}

private struct DataFlowPage: View {
    let onNext: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: DSSpacing.xl) {
                Spacer(minLength: DSSpacing.xl2)

                Image(systemName: "lock.shield")
                    .font(.system(size: 44, weight: .light))
                    .foregroundColor(DSColor.accentOnBg)
                    .padding(.bottom, DSSpacing.xs)
                    .accessibilityHidden(true)

                Text("onboarding.dataflow.title", bundle: .main)
                    .h1()
                    .foregroundColor(DSColor.onBackgroundPrimary)
                    .multilineTextAlignment(.center)

                Text("onboarding.dataflow.subtitle", bundle: .main)
                    .captionText()
                    .foregroundColor(DSColor.onBackgroundMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DSSpacing.md)

                VStack(spacing: DSSpacing.md) {
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
                    // Issue #922: disclose that optional iCloud / signed-in
                    // account sync may upload notes, audio, and images — and
                    // that sync is not end-to-end encrypted.
                    DataFlowRow(
                        icon: "icloud.and.arrow.up.fill",
                        feature: NSLocalizedString("onboarding.dataflow.sync.feature", comment: ""),
                        payload: NSLocalizedString("onboarding.dataflow.sync.payload", comment: ""),
                        destination: NSLocalizedString("onboarding.dataflow.sync.destination", comment: "")
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
                    .padding(.horizontal, DSSpacing.md)
                    .padding(.top, DSSpacing.xs)

                Spacer(minLength: DSSpacing.xl2)
            }
            .padding(.horizontal, DSSpacing.xl2)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [DSColor.backgroundWarm.opacity(0), DSColor.backgroundWarm],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: DSSpacing.lg)
                .allowsHitTesting(false)

                Button(action: acceptAndContinue) {
                    Text("onboarding.dataflow.continue", bundle: .main)
                }
                .buttonStyle(.dsPrimary(size: .large, font: DSType.bodyMD))
                .accessibilityIdentifier("onboarding.dataflow.continue")
                .padding(.horizontal, DSSpacing.xl2)
                .padding(.bottom, DSSpacing.md)
                .background(DSColor.backgroundWarm)
            }
        }
    }

    private func acceptAndContinue() {
        // Persist consent so future builds (and the API-keys settings screen)
        // can verify the user saw this disclosure before third-party traffic.
        UserDefaults.standard.set(
            Date().timeIntervalSince1970,
            forKey: AppSettings.Keys.dataFlowDisclosureAcceptedAt
        )
        onNext()
    }
}

private struct DataFlowRow: View {
    let icon: String
    let feature: String
    let payload: String
    let destination: String

    var body: some View {
        HStack(alignment: .top, spacing: DSSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(DSColor.accentOnBg)
                .frame(width: 28)
                .padding(.top, 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(feature)
                    .bodyText()
                    .foregroundColor(DSColor.onBackgroundPrimary)
                Text(payload)
                    .captionText()
                    .foregroundColor(DSColor.onBackgroundMuted)
                Text(destination)
                    .captionText()
                    .foregroundColor(DSColor.accentOnBg)
            }

            Spacer()
        }
        .padding(DSSpacing.cardInner)
        .background(DSColor.surfaceWhite)
        .cornerRadius(DSRadius.md)
        .surfaceElevatedShadow()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Page 1: Welcome
//
// Issue #1 (2026-07-02) — the previous WelcomePage was a bare "DayPage +
// slogan + Get Started" screen. New users could not tell in 5 seconds what
// the product is or who it is for. This version keeps the warm-cream
// aesthetic (small illustration, quiet type) but adds:
//   1. a target-audience tagline chip (who this is for)
//   2. a headline that names the mechanism (dump → AI → journal + graph)
//   3. three benefit rows anchoring capture / compile / graph
//   4. a dual CTA: primary "Start writing", secondary "See a sample journal"
// The secondary CTA seeds SampleDataSeeder and jumps straight past
// onboarding — the same code path Issue #2 uses from the Today empty state.

private struct WelcomePage: View {
    let onNext: () -> Void
    @Binding var hasOnboarded: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var usesAccessibilityLayout: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    var body: some View {
        ScrollView {
            VStack(spacing: usesAccessibilityLayout ? DSSpacing.md : DSSpacing.lg) {
                Spacer(minLength: usesAccessibilityLayout ? DSSpacing.sm : DSSpacing.xl2)

                if usesAccessibilityLayout {
                    HStack(alignment: .firstTextBaseline, spacing: DSSpacing.sm) {
                        Image(systemName: "pencil.and.scribble")
                            .font(.system(size: 20, weight: .light))
                            .accessibilityHidden(true)
                        Text("onboarding.welcome.tagline", bundle: .main)
                            .font(DSType.mono10)
                            .tracking(1.2)
                            .textCase(.uppercase)
                    }
                    .foregroundColor(DSColor.accentOnBg)
                    .padding(.horizontal, DSSpacing.md)
                    .padding(.vertical, DSSpacing.sm)
                    .background(DSColor.accentSoft)
                    .cornerRadius(8)
                    .dynamicTypeSize(.xSmall ... .xxxLarge)
                } else {
                    ZStack {
                        Circle()
                            .fill(DSColor.accentSoft)
                            .frame(width: 76, height: 76)
                        Image(systemName: "pencil.and.scribble")
                            .font(.system(size: 34, weight: .light))
                            .foregroundColor(DSColor.accentOnBg)
                    }
                    .accessibilityHidden(true)

                    Text("onboarding.welcome.tagline", bundle: .main)
                        .font(DSType.mono10)
                        .tracking(1.4)
                        .textCase(.uppercase)
                        .foregroundColor(DSColor.accentOnBg)
                        .padding(.horizontal, DSSpacing.md)
                        .padding(.vertical, 6)
                        .background(DSColor.accentSoft)
                        .cornerRadius(8)
                }

                Text("onboarding.welcome.headline", bundle: .main)
                    .font(DSFonts.serif(size: 20, weight: .regular, relativeTo: .title3))
                    .foregroundColor(DSColor.onBackgroundPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DSSpacing.sm)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    // The display line is decorative/summary copy; cap it at
                    // the largest standard size so it does not become a
                    // full-screen wall of type. The detailed benefit rows
                    // below still honor accessibility sizes and remain
                    // vertically scrollable.
                    .dynamicTypeSize(.xSmall ... .xxxLarge)
                    .minimumScaleFactor(0.75)

                Text("onboarding.welcome.slogan", bundle: .main)
                    .captionText()
                    .foregroundColor(DSColor.onBackgroundMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .dynamicTypeSize(.xSmall ... .accessibility2)

                VStack(spacing: 10) {
                    benefitRow(
                        icon: "square.and.pencil",
                        titleKey: "onboarding.welcome.benefit1.title",
                        bodyKey: "onboarding.welcome.benefit1.body"
                    )
                    benefitRow(
                        icon: "sparkles",
                        titleKey: "onboarding.welcome.benefit2.title",
                        bodyKey: "onboarding.welcome.benefit2.body"
                    )
                    benefitRow(
                        icon: "point.3.connected.trianglepath.dotted",
                        titleKey: "onboarding.welcome.benefit3.title",
                        bodyKey: "onboarding.welcome.benefit3.body"
                    )
                }
                .padding(.top, DSSpacing.xs)

                if usesAccessibilityLayout {
                    Button(action: showSample) {
                        Text("onboarding.welcome.try_sample", bundle: .main)
                            .bodyText()
                            .foregroundColor(DSColor.accentOnBg)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .dynamicTypeSize(.xSmall ... .accessibility1)
                    .accessibilityIdentifier("onboarding.welcome.try_sample")
                }

                Spacer(minLength: DSSpacing.xl2)
            }
            .padding(.horizontal, DSSpacing.xl2)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: DSSpacing.xs) {
                Button(action: startLocally) {
                    Text("onboarding.apikeys.complete.local", bundle: .main)
                }
                .buttonStyle(.dsPrimary(size: .large, font: DSType.bodyMD))
                .accessibilityIdentifier("onboarding.welcome.begin")

                Button(action: onNext) {
                    Text("onboarding.welcome.customize", bundle: .main)
                        .font(.footnote)
                        .foregroundColor(DSColor.accentOnBg)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("onboarding.welcome.customize")

                if !usesAccessibilityLayout {
                    Button(action: showSample) {
                        Text("onboarding.welcome.try_sample", bundle: .main)
                            .bodyText()
                            .foregroundColor(DSColor.accentOnBg)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("onboarding.welcome.try_sample")
                }
            }
            .padding(.horizontal, DSSpacing.xl2 + DSSpacing.sm)
            .padding(.top, DSSpacing.sm)
            .padding(.bottom, DSSpacing.xs)
            .background(DSColor.backgroundWarm)
            .dynamicTypeSize(.xSmall ... .accessibility1)
        }
    }

    private func startLocally() {
        // A first note does not require permissions, an account, reminders or
        // provider credentials. Enhanced features remain opt-in in Settings.
        UserDefaults.standard.set(false, forKey: AppSettings.Keys.aiFeaturesEnabled)
        UserDefaults.standard.set(true, forKey: AppSettings.Keys.authSkipped)
        // The direct-writing choice should not immediately open another
        // blocking setup overlay. The full setup path retains the coach marks.
        UserDefaults.standard.set(true, forKey: InputBarTutorialOverlay.completionKey)
        UserDefaults.standard.set(true, forKey: AppSettings.Keys.hasOnboarded)
        hasOnboarded = true
    }

    private func showSample() {
        UserDefaults.standard.set(true, forKey: AppSettings.Keys.hasOnboarded)
        SampleDataSeeder.seedIfNeeded()
        AnalyticsService.shared.record(
            AnalyticsService.Name.welcomeCtaSample,
            props: ["surface": "welcome"]
        )
        hasOnboarded = true
    }

    private func benefitRow(icon: String, titleKey: String, bodyKey: String) -> some View {
        HStack(alignment: .top, spacing: DSSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(DSColor.accentOnBg)
                .frame(width: 28)
                .padding(.top, 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(titleKey), bundle: .main)
                    .bodyText()
                    .foregroundColor(DSColor.onBackgroundPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(LocalizedStringKey(bodyKey), bundle: .main)
                    .captionText()
                    .foregroundColor(DSColor.onBackgroundMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(usesAccessibilityLayout ? DSSpacing.md : DSSpacing.lg)
        .background(DSColor.surfaceWhite)
        .cornerRadius(DSRadius.md)
        .surfaceElevatedShadow()
        // Issue #15 (2026-07-03): SE 375pt × Accessibility3 audit —
        // benefit rows previously clipped their body line at AX2+ because
        // no fixedSize was applied. Vertical fixedSize on both Texts
        // + capping the row at accessibility3 keeps the tallest row
        // from pushing the CTA off-screen.
        .dynamicTypeSize(.xSmall ... .accessibility2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Page 2: Permissions

private struct PermissionsPage: View {
    let onNext: () -> Void

    @State private var micStatus: PermissionStatus = .unknown
    @State private var locationStatus: PermissionStatus = .unknown
    @State private var notifStatus: PermissionStatus = .unknown

    // B3: re-poll permission state whenever the app returns to the foreground.
    // Required because iOS routes the user to Settings.app to change Location
    // and Notifications, and the onboarding sheet stays mounted the entire
    // time — without scenePhase awareness the row labels would be stuck on
    // whatever they showed before the user left.
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
        ScrollView {
            VStack(spacing: dynamicTypeSize.isAccessibilitySize ? DSSpacing.lg : DSSpacing.xl2) {
                Spacer(minLength: dynamicTypeSize.isAccessibilitySize ? DSSpacing.md : DSSpacing.xl2)

                Text("onboarding.permissions.title", bundle: .main)
                    .h1()
                    .foregroundColor(DSColor.onBackgroundPrimary)
                    .multilineTextAlignment(.center)
                    .dynamicTypeSize(.xSmall ... .accessibility2)

                Text("onboarding.permissions.subtitle", bundle: .main)
                    .captionText()
                    .foregroundColor(DSColor.onBackgroundMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DSSpacing.sm)
                    .fixedSize(horizontal: false, vertical: true)
                    .dynamicTypeSize(.xSmall ... .accessibility2)

                VStack(spacing: DSSpacing.md) {
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

                Spacer(minLength: DSSpacing.xl2)
            }
            .padding(.horizontal, DSSpacing.xl2)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Always reachable even when the three cards become multi-line at
            // accessibility sizes. Permission prompts stay optional.
            Button(action: onNext) {
                Text("onboarding.permissions.next", bundle: .main)
            }
            .buttonStyle(.dsPrimary(size: .large, font: DSType.bodyMD))
            .dynamicTypeSize(.xSmall ... .accessibility1)
            .padding(.horizontal, DSSpacing.xl2)
            .padding(.vertical, DSSpacing.sm)
            .background(DSColor.backgroundWarm)
        }
        .onAppear { pollAllPermissions() }
        // B3: re-poll on every foreground transition so a trip through
        // Settings.app instantly updates the row labels here.
        .onChange(of: scenePhase) { phase in
            if phase == .active { pollAllPermissions() }
        }
    }

    private func permissionCard(
        icon: String,
        title: String,
        description: String,
        status: PermissionStatus,
        onGrant: @escaping () -> Void
    ) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: DSSpacing.md) {
                    HStack(alignment: .firstTextBaseline, spacing: DSSpacing.md) {
                        Image(systemName: icon)
                            .font(.system(size: 20))
                            .foregroundColor(DSColor.accentOnBg)
                            .frame(width: 32)
                            .accessibilityHidden(true)
                        Text(title)
                            .bodyText()
                            .foregroundColor(DSColor.onBackgroundPrimary)
                    }

                    Text(description)
                        .captionText()
                        .foregroundColor(DSColor.onBackgroundMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    permissionButton(title: title, status: status, onGrant: onGrant)
                }
            } else {
                HStack(spacing: DSSpacing.lg) {
                    Image(systemName: icon)
                        .font(.system(size: 20))
                        .foregroundColor(DSColor.accentOnBg)
                        .frame(width: 32)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).bodyText().foregroundColor(DSColor.onBackgroundPrimary)
                        Text(description).captionText().foregroundColor(DSColor.onBackgroundMuted)
                    }

                    Spacer()
                    permissionButton(title: title, status: status, onGrant: onGrant)
                }
            }
        }
        .padding(DSSpacing.cardInner)
        .background(DSColor.surfaceWhite)
        .cornerRadius(DSRadius.md)
        .surfaceElevatedShadow()
        .dynamicTypeSize(.xSmall ... .accessibility2)
    }

    private func permissionButton(
        title: String,
        status: PermissionStatus,
        onGrant: @escaping () -> Void
    ) -> some View {
        Button(action: onGrant) {
            Text(status.label)
                .captionText()
                .foregroundColor(status == .unknown ? DSColor.surfaceWhite : status.color)
                .padding(.horizontal, DSSpacing.md)
                .padding(.vertical, 6)
                .background(status == .unknown ? DSColor.accentAmber : DSColor.surfaceSunken)
                .cornerRadius(8)
        }
        .minTapTarget()
        .disabled(status != .unknown)
        .accessibilityLabel("\(title), \(status.label)")
    }

    /// B3: single entry point that refreshes mic/location/notification status.
    /// Called from onAppear, scenePhase=.active, and immediately after each
    /// request callback — replaces the previous 1s asyncAfter race.
    private func pollAllPermissions() {
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
        // B3: drop the 1s asyncAfter — it both raced the system prompt (often
        // re-reading "not determined" before the user tapped Allow) and left
        // stale state forever if the user took longer than 1s to decide. The
        // scenePhase observer in body now handles the come-back-from-prompt
        // case; we also poll synchronously here for the in-app prompt that
        // doesn't backgound the app.
        LocationService.shared.requestPermissionIfNeeded()
        pollAllPermissions()
    }

    private func requestNotifications() {
        UserDefaults.standard.set(true, forKey: AppSettings.Keys.hasRequestedNotifications)
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
            VStack(spacing: DSSpacing.xl2) {
                Spacer(minLength: 48)

                Text("onboarding.apikeys.title", bundle: .main)
                    .h1()
                    .foregroundColor(DSColor.onBackgroundPrimary)

                Text("onboarding.apikeys.subtitle", bundle: .main)
                    .captionText()
                    .foregroundColor(DSColor.onBackgroundMuted)
                    .multilineTextAlignment(.center)

                VStack(spacing: DSSpacing.md) {
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

                // Issue #922: starting locally is the clear primary completion
                // when no keys are entered — keys are optional and billed
                // separately by their providers. With keys entered the same
                // button saves them (non-empty fields only) and completes.
                Button(action: saveAndComplete) {
                    Text(hasAnyEnteredKey
                         ? NSLocalizedString("onboarding.apikeys.complete.save", comment: "Save entered keys and start")
                         : NSLocalizedString("onboarding.apikeys.complete.local", comment: "Start locally without AI keys"))
                }
                .buttonStyle(.dsPrimary(size: .large, font: DSType.bodyMD))
                .padding(.top, DSSpacing.sm)
                .accessibilityIdentifier("onboarding-apikeys-complete")

                // B5: dedicated skip path. Pasting keys here is optional; the
                // user can always wire them up later in Settings → API Keys.
                // We deliberately bypass `saveAndComplete` so an empty field
                // can never get committed into Keychain.
                Button {
                    onComplete()
                } label: {
                    Text(NSLocalizedString("onboarding.apikeys.skip", comment: ""))
                        .font(.footnote)
                        .foregroundColor(DSColor.inkTertiaryAA)
                        .underline()
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .padding(.top, DSSpacing.xs)
                .accessibilityIdentifier("onboarding-apikeys-skip")

                Spacer(minLength: 48)
            }
            .padding(.horizontal, DSSpacing.xl2)
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

                Button(NSLocalizedString("onboarding.apikeys.paste", comment: "")) {
                    if let s = UIPasteboard.general.string {
                        text.wrappedValue = s
                    }
                }
                .captionText()
                .foregroundColor(DSColor.accentOnBg)
                .minTapTarget()
                .accessibilityLabel(String(
                    format: NSLocalizedString("onboarding.apikeys.paste.a11y", comment: ""),
                    label
                ))
            }
            .padding(DSSpacing.md)
            .background(DSColor.surfaceSunken)
            .cornerRadius(8)
        }
    }

    private var hasAnyEnteredKey: Bool {
        ![deepSeekKey, openAIKey, openWeatherKey].allSatisfy {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func saveAndComplete() {
        // US-002: API keys are stored in Keychain (not UserDefaults) to prevent iCloud backup exposure.
        let trimmedDeepSeekKey = deepSeekKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOpenAIKey = openAIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOpenWeatherKey = openWeatherKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDeepSeekKey.isEmpty {
            KeychainHelper.setAPIKey(trimmedDeepSeekKey, for: "deepSeekApiKey")
        }
        if !trimmedOpenAIKey.isEmpty {
            KeychainHelper.setAPIKey(trimmedOpenAIKey, for: "openAIWhisperApiKey")
        }
        if !trimmedOpenWeatherKey.isEmpty {
            KeychainHelper.setAPIKey(trimmedOpenWeatherKey, for: "openWeatherApiKey")
        }
        onComplete()
    }
}
