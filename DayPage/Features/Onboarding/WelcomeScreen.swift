import SwiftUI

// MARK: - PressableButtonStyle

private struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Motion.spring, value: configuration.isPressed)
    }
}

// MARK: - WelcomeScreen

/// First-run welcome shown once after onboarding — a fading Day Orb, bilingual serif line, Begin pill.
/// Dismissed permanently via "hasSeenWelcome" UserDefaults key.
struct WelcomeScreen: View {

    @Binding var hasSeenWelcome: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var orbOpacity: Double = 0
    @State private var taglineAppeared: Bool = false
    @State private var buttonAppeared: Bool = false

    var body: some View {
        ZStack {
            DSColor.bgWarm.ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                // Day Orb — fades in over 800ms
                DayOrbView(signalCount: 0, size: 156)
                    .opacity(orbOpacity)
                    .onAppear {
                        withAnimation(.easeOut(duration: 0.8)) {
                            orbOpacity = 1
                        }
                        Task { @MainActor in
                            if reduceMotion {
                                taglineAppeared = true
                                buttonAppeared = true
                            } else {
                                try? await Task.sleep(nanoseconds: 400_000_000)
                                withAnimation(Motion.rise) { taglineAppeared = true }
                                try? await Task.sleep(nanoseconds: 200_000_000)
                                withAnimation(Motion.rise) { buttonAppeared = true }
                            }
                        }
                    }

                // Bilingual serif tagline
                VStack(spacing: 8) {
                    Text("每一天，都值得留下来")
                        .font(DSType.serifDisplay32)
                        .foregroundColor(DSColor.inkPrimary)
                        .multilineTextAlignment(.center)

                    Text("Every day deserves a record.")
                        .font(DSType.serifBody18)
                        .foregroundColor(DSColor.inkMuted)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 32)
                .opacity(taglineAppeared ? 1 : 0)
                .offset(y: taglineAppeared ? 0 : 12)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Welcome to DayPage. Every day deserves a record.")

                Spacer()

                // Begin pill button
                Button {
                    Haptics.commit()
                    UserDefaults.standard.set(true, forKey: "hasSeenWelcome")
                    withAnimation(Motion.rise) {
                        hasSeenWelcome = true
                    }
                } label: {
                    Text("开始 · Begin")
                        .font(DSFonts.inter(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 40)
                        .padding(.vertical, 14)
                        .background(DSColor.amberDeep)
                        .clipShape(Capsule())
                }
                .buttonStyle(PressableButtonStyle())
                .opacity(buttonAppeared ? 1 : 0)
                .offset(y: buttonAppeared ? 0 : 12)
                .accessibilityLabel("Begin")
                .accessibilityHint("Starts using DayPage")

                Spacer().frame(height: 40)
            }
        }
    }
}
