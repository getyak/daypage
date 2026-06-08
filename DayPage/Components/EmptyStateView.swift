import SwiftUI

// MARK: - EmptyStateView

struct EmptyStateView: View {
    let title: LocalizedStringKey
    var subtitle: String?
    var ctaLabel: String?
    var ctaAction: (() -> Void)?
    var showOrbAccent: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    private let maxIdlePulses = 3

    /// 0 = all hidden, 1 = orb visible, 2 = title, 3 = subtitle, 4 = CTA
    @State private var revealStep: Int = 0
    @State private var breathing = false
    @State private var ctaGlow = false
    @State private var revealTask: Task<Void, Never>?
    @State private var idlePulseTask: Task<Void, Never>?

    /// Captured once on appear so the tint stays stable across the breathing animation.
    @State private var orbTint: Color = TimeOfDay.from(Date()).tint
    /// Tracks which TimeOfDay bucket is currently displayed; avoids float-equality churn.
    @State private var tintBucket: Int = TimeOfDay.from(Date()).bucketIndex

    private let tintTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 20) {
                titleSection
                if let subtitle {
                    Text(subtitle)
                        .font(DSType.bodyMD)
                        .foregroundColor(DSColor.inkMuted)
                        .multilineTextAlignment(.center)
                        .dynamicTypeSize(.xSmall ... .accessibility5)
                        .padding(.horizontal, 8)
                        .opacity(revealStep >= 3 ? 1 : 0)
                        .scaleEffect(revealStep >= 3 ? 1 : 0.96)
                        .offset(y: revealStep >= 3 ? 0 : 6)
                        .animation(Motion.rise, value: revealStep >= 3)
                }
            }
            .accessibilityElement(children: .combine)
            if let label = ctaLabel, let action = ctaAction {
                ctaButton(label: label, action: action)
                    .opacity(revealStep >= 4 ? 1 : 0)
                    .scaleEffect(revealStep >= 4 ? 1 : 0.96)
                    .offset(y: revealStep >= 4 ? 0 : 8)
                    .animation(Motion.rise, value: revealStep >= 4)
                    .shadow(
                        color: DSColor.accentAmber.opacity(ctaGlow ? 0.5 : 0),
                        radius: ctaGlow ? 16 : 0
                    )
                    .animation(
                        reduceMotion ? nil : .easeOut(duration: 0.6),
                        value: ctaGlow
                    )
            }
        }
        .padding(.horizontal, 32)
        .onReceive(tintTimer) { now in
            guard showOrbAccent else { return }
            let tod = TimeOfDay.from(now)
            guard tod.bucketIndex != tintBucket else { return }
            tintBucket = tod.bucketIndex
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.8)) {
                orbTint = tod.tint
            }
        }
        .onAppear {
            orbTint = TimeOfDay.from(Date()).tint
            if reduceMotion {
                revealStep = 4
                breathing = false
            } else {
                breathing = true
                revealTask = Task { @MainActor in
                    revealStep = 1  // orb blooms
                    if !voiceOverEnabled { Haptics.rigid(intensity: 0.25) }
                    try? await Task.sleep(nanoseconds: 70_000_000)
                    guard !Task.isCancelled else { return }
                    revealStep = 2  // title rises
                    if !voiceOverEnabled { Haptics.rigid(intensity: 0.35) }
                    try? await Task.sleep(nanoseconds: 70_000_000)
                    guard !Task.isCancelled else { return }
                    revealStep = 3  // subtitle
                    if !voiceOverEnabled { Haptics.rigid(intensity: 0.45) }
                    try? await Task.sleep(nanoseconds: 70_000_000)
                    guard !Task.isCancelled else { return }
                    revealStep = 4  // CTA
                    if ctaAction != nil {
                        if let label = ctaLabel {
                            UIAccessibility.post(notification: .announcement, argument: label)
                        }
                        try? await Task.sleep(nanoseconds: 70_000_000)
                        guard !Task.isCancelled else { return }
                        Haptics.soft()
                        await pulseCTA()
                        guard !voiceOverEnabled else { return }
                        idlePulseTask = Task { @MainActor in
                            for _ in 0..<maxIdlePulses {
                                try? await Task.sleep(nanoseconds: 6_000_000_000)
                                guard !Task.isCancelled, !reduceMotion, !voiceOverEnabled else { return }
                                await pulseCTA()
                            }
                        }
                    }
                }
            }
        }
        .onDisappear {
            revealTask?.cancel()
            revealTask = nil
            idlePulseTask?.cancel()
            idlePulseTask = nil
        }
    }

    // MARK: - Private

    private func pulseCTA() async {
        ctaGlow = true
        try? await Task.sleep(nanoseconds: 600_000_000)
        ctaGlow = false
    }

    @ViewBuilder
    private var titleSection: some View {
        ZStack {
            if showOrbAccent {
                orbAccent
            }
            Text(title)
                .font(DSType.serifDisplay28)
                .foregroundColor(DSColor.inkPrimary)
                .multilineTextAlignment(.center)
                .dynamicTypeSize(.xSmall ... .accessibility2)
                .minimumScaleFactor(0.7)
                .opacity(revealStep >= 2 ? 1 : 0)
                .scaleEffect(revealStep >= 2 ? 1 : 0.96)
                .offset(y: revealStep >= 2 ? 0 : 6)
                .animation(Motion.rise, value: revealStep >= 2)
        }
    }

    private var orbAccent: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        orbTint.opacity(0.22),
                        orbTint.opacity(0.10),
                        Color.clear
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: 30
                )
            )
            .frame(width: 60, height: 60)
            .blur(radius: 10)
            .scaleEffect(revealStep >= 1
                ? (reduceMotion ? 1.0 : (breathing ? 1.12 : 0.92))
                : 0.6)
            .opacity(revealStep >= 1
                ? (reduceMotion ? 0.85 : (breathing ? 1.0 : 0.7))
                : 0)
            .animation(
                reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.72),
                value: revealStep >= 1
            )
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 2.4).repeatForever(autoreverses: true),
                value: breathing
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func ctaButton(label: String, action: @escaping () -> Void) -> some View {
        Button(action: {
            Haptics.tapConfirm()
            action()
        }) {
            Text(label)
                .font(DSType.sectionLabel)
                .textCase(.uppercase)
                .tracking(1.5)
                .foregroundColor(Color.white)
                .multilineTextAlignment(.center)
                .dynamicTypeSize(.xSmall ... .accessibility2)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(DSColor.amberDeep)
                .clipShape(Capsule())
        }
        .buttonStyle(PressableScaleStyle(reduceMotion: reduceMotion))
    }
}

// MARK: - PressableScaleStyle

private struct PressableScaleStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect((!reduceMotion && configuration.isPressed) ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(
                reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7),
                value: configuration.isPressed
            )
    }
}

// MARK: - Factory Methods

extension EmptyStateView {
    /// Today tab — no memos yet.
    static func todayBlank(ctaAction: @escaping () -> Void, subtitleOverride: String? = nil) -> EmptyStateView {
        EmptyStateView(
            title: L10n.Empty.todayBlankTitle,
            subtitle: subtitleOverride ?? L10n.Empty.todayBlankSubtitle,
            ctaLabel: L10n.Empty.todayBlankCta,
            ctaAction: ctaAction,
            showOrbAccent: true
        )
    }

    /// Today tab — memos exist but no signal cards generated.
    static func todayNoSignals(ctaAction: (() -> Void)? = nil, subtitleOverride: String? = nil) -> EmptyStateView {
        EmptyStateView(
            title: L10n.Empty.todayNoSignalsTitle,
            subtitle: subtitleOverride ?? L10n.Empty.todayNoSignalsSubtitle,
            ctaLabel: ctaAction != nil ? L10n.Empty.todayBlankCta : nil,
            ctaAction: ctaAction,
            showOrbAccent: true
        )
    }

    /// Archive — selected day has no compiled page.
    static func archiveDayEmpty(ctaAction: @escaping () -> Void) -> EmptyStateView {
        EmptyStateView(
            title: L10n.Empty.archiveDayTitle,
            subtitle: L10n.Empty.archiveDaySubtitle,
            ctaLabel: L10n.Empty.archiveDayCta,
            ctaAction: ctaAction,
            showOrbAccent: false
        )
    }

    /// Archive — selected month has no entries.
    static func archiveMonthEmpty(ctaAction: @escaping () -> Void, subtitleOverride: String? = nil) -> EmptyStateView {
        EmptyStateView(
            title: L10n.Empty.archiveMonthEmptyTitle,
            subtitle: subtitleOverride ?? L10n.Empty.archiveMonthEmptySubtitle,
            ctaLabel: L10n.Empty.archiveMonthEmptyCta,
            ctaAction: ctaAction,
            showOrbAccent: true
        )
    }

    /// Graph — nodes exist but current search/filter matches nothing.
    static func graphNoMatches(ctaAction: @escaping () -> Void) -> EmptyStateView {
        EmptyStateView(
            title: L10n.Empty.graphNoMatchesTitle,
            subtitle: L10n.Empty.graphNoMatchesSubtitle,
            ctaLabel: L10n.Empty.graphClearFilters,
            ctaAction: ctaAction,
            showOrbAccent: true
        )
    }

    /// Mic permission denied — recording unavailable.
    static func micPermissionDenied(ctaAction: @escaping () -> Void) -> EmptyStateView {
        EmptyStateView(
            title: L10n.Empty.micDeniedTitle,
            subtitle: L10n.Empty.micDeniedSubtitle,
            ctaLabel: L10n.Empty.micDeniedCta,
            ctaAction: ctaAction,
            showOrbAccent: true
        )
    }

    /// Graph tab — no compiled entities exist yet.
    static func graphEmpty(ctaAction: @escaping () -> Void, subtitleOverride: String? = nil) -> EmptyStateView {
        EmptyStateView(
            title: L10n.Empty.graphEmptyTitle,
            subtitle: subtitleOverride ?? L10n.Empty.graphEmptySubtitle,
            ctaLabel: L10n.Empty.graphEmptyCta,
            ctaAction: ctaAction,
            showOrbAccent: true
        )
    }
}

// MARK: - Preview

#Preview("Today Blank") {
    ZStack {
        AmbientBackground()
        EmptyStateView.todayBlank { }
    }
}

#Preview("No Signals") {
    ZStack {
        AmbientBackground()
        EmptyStateView.todayNoSignals()
    }
}

// Compile Locked preview removed — the screen no longer renders this card.
// The live state is now a single-line mono Text above the input bar (see
// `compile.dock.locked` in Localizable.strings, used by TodayView).

#Preview("Archive Day Empty") {
    ZStack {
        AmbientBackground()
        EmptyStateView.archiveDayEmpty { }
    }
}

#Preview("Archive Month Empty") {
    ZStack {
        AmbientBackground()
        EmptyStateView.archiveMonthEmpty { }
    }
}

#Preview("Mic Denied") {
    ZStack {
        AmbientBackground()
        EmptyStateView.micPermissionDenied { }
    }
}

#Preview("Graph Empty") {
    ZStack {
        AmbientBackground()
        EmptyStateView.graphEmpty { }
    }
}

#Preview("Graph No Matches") {
    ZStack {
        AmbientBackground()
        EmptyStateView.graphNoMatches { }
    }
}
