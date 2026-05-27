import SwiftUI

// MARK: - EmptyStateView

struct EmptyStateView: View {
    let title: LocalizedStringKey
    var subtitle: String?
    var ctaLabel: String?
    var ctaHint: String?
    var ctaAction: (() -> Void)?
    var showOrbAccent: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var appeared = false
    @State private var breathing = false

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 20) {
                titleSection
                if let subtitle {
                    Text(subtitle)
                        .font(DSType.bodyMD)
                        .foregroundColor(DSColor.inkMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 6)
                        .animation(Motion.rise.delay(0.06), value: appeared)
                }
            }
            .accessibilityElement(children: .combine)
            if let label = ctaLabel, let action = ctaAction {
                ctaButton(label: label, action: action)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 8)
                    .animation(Motion.rise.delay(0.12), value: appeared)
            }
        }
        .padding(.horizontal, 32)
        .onAppear {
            appeared = true
            if !reduceMotion {
                breathing = true
            }
        }
    }

    // MARK: - Private

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
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 6)
                .animation(Motion.rise, value: appeared)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var orbAccent: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        Color(hex: "E8974D").opacity(0.55),
                        Color(hex: "A8541B").opacity(0.28),
                        Color.clear
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: 30
                )
            )
            .frame(width: 60, height: 60)
            .blur(radius: 10)
            .scaleEffect(reduceMotion ? 1.0 : (breathing ? 1.12 : 0.92))
            .opacity(reduceMotion ? 0.85 : (breathing ? 1.0 : 0.7))
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
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(DSColor.amberDeep)
                .clipShape(Capsule())
        }
        .buttonStyle(PressableScaleStyle(reduceMotion: reduceMotion))
        .modifier(OptionalAccessibilityHint(hint: ctaHint))
    }
}

// MARK: - OptionalAccessibilityHint

private struct OptionalAccessibilityHint: ViewModifier {
    let hint: String?

    func body(content: Content) -> some View {
        if let hint {
            content.accessibilityHint(hint)
        } else {
            content
        }
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
    static func todayBlank(ctaAction: @escaping () -> Void) -> EmptyStateView {
        EmptyStateView(
            title: L10n.Empty.todayBlankTitle,
            subtitle: L10n.Empty.todayBlankSubtitle,
            ctaLabel: L10n.Empty.todayBlankCta,
            ctaHint: "Records your first note for today",
            ctaAction: ctaAction,
            showOrbAccent: true
        )
    }

    /// Today tab — memos exist but no signal cards generated.
    static func todayNoSignals() -> EmptyStateView {
        EmptyStateView(
            title: L10n.Empty.todayNoSignalsTitle,
            subtitle: L10n.Empty.todayNoSignalsSubtitle,
            showOrbAccent: false
        )
    }

    /// Compilation locked — not enough memos.
    ///
    /// **Orphaned.** Today screen no longer renders this as a card. The
    /// compile-locked hint now lives as a single-line mono `Text` directly
    /// above the input bar (see `TodayView` Compile Area). Kept temporarily
    /// for the SwiftUI preview at the bottom of this file. Remove (along
    /// with the preview and the `compileLockedTitle`/`compileLockedSubtitle`
    /// L10n accessors) one release cycle after 2026-05-12 if no new caller
    /// appears.
    @available(*, deprecated, message: "Replaced by inline `compile.dock.locked` Text in TodayView. Pending removal — see doc comment.")
    static func compileLocked(currentCount: Int) -> EmptyStateView {
        EmptyStateView(
            title: L10n.Empty.compileLockedTitle,
            subtitle: L10n.Empty.compileLockedSubtitle(count: currentCount),
            showOrbAccent: false
        )
    }

    /// Archive — selected day has no compiled page.
    static func archiveDayEmpty(ctaAction: @escaping () -> Void) -> EmptyStateView {
        EmptyStateView(
            title: L10n.Empty.archiveDayTitle,
            subtitle: L10n.Empty.archiveDaySubtitle,
            ctaLabel: L10n.Empty.archiveDayCta,
            ctaHint: "Opens today's view to add notes",
            ctaAction: ctaAction,
            showOrbAccent: false
        )
    }

    /// Archive — selected month has no entries.
    static func archiveMonthEmpty(ctaAction: @escaping () -> Void) -> EmptyStateView {
        EmptyStateView(
            title: L10n.Empty.archiveMonthEmptyTitle,
            subtitle: L10n.Empty.archiveMonthEmptySubtitle,
            ctaLabel: L10n.Empty.archiveMonthEmptyCta,
            ctaHint: "Opens today's view to start logging",
            ctaAction: ctaAction,
            showOrbAccent: true
        )
    }

    /// Graph — nodes exist but current search/filter matches nothing.
    static func graphNoMatches(ctaAction: @escaping () -> Void) -> EmptyStateView {
        EmptyStateView(
            title: L10n.Empty.graphNoMatchesTitle,
            subtitle: L10n.Empty.graphNoMatchesSubtitle,
            ctaLabel: "清除筛选",
            ctaHint: "Removes all active search and date filters",
            ctaAction: ctaAction,
            showOrbAccent: false
        )
    }

    /// Mic permission denied — recording unavailable.
    static func micPermissionDenied(ctaAction: @escaping () -> Void) -> EmptyStateView {
        EmptyStateView(
            title: L10n.Empty.micDeniedTitle,
            subtitle: L10n.Empty.micDeniedSubtitle,
            ctaLabel: L10n.Empty.micDeniedCta,
            ctaHint: "Opens Settings to grant microphone access",
            ctaAction: ctaAction,
            showOrbAccent: false
        )
    }

    /// Graph tab — no compiled entities exist yet.
    static func graphEmpty(ctaAction: @escaping () -> Void) -> EmptyStateView {
        EmptyStateView(
            title: L10n.Empty.graphEmptyTitle,
            subtitle: L10n.Empty.graphEmptySubtitle,
            ctaLabel: L10n.Empty.graphEmptyCta,
            ctaHint: "Opens today's view to record your first entry",
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
