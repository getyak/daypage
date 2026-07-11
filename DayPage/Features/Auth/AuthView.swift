import SwiftUI
import DayPageServices

// MARK: - AuthButtonStyle

/// Press-scale style for auth sign-in buttons.
/// Replaces DragGesture so VoiceOver and Switch Control work correctly.
private struct AuthButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Entrance Choreography

/// Staggered fade-up used by the auth screen's brand block / CTA stack /
/// skip link. Falls back to a pure cross-fade (no translation) when the
/// user has Reduce Motion enabled.
private struct EntranceModifier: ViewModifier {
    let isVisible: Bool
    let reduceMotion: Bool
    let delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible || reduceMotion ? 0 : 14)
            .animation(.easeOut(duration: 0.55).delay(delay), value: isVisible)
    }
}

private extension View {
    func entrance(_ isVisible: Bool, reduceMotion: Bool, delay: Double) -> some View {
        modifier(EntranceModifier(isVisible: isVisible, reduceMotion: reduceMotion, delay: delay))
    }
}

// MARK: - AuthView

struct AuthView: View {

    var onSkip: (() -> Void)? = nil

    @EnvironmentObject private var authService: AuthService
    @StateObject private var viewModel = AuthViewModel()
    @State private var showEmailAuth = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Drives the staggered entrance choreography: brand block rises first,
    /// then the CTA stack, then the skip link. Pure opacity under Reduce Motion.
    @State private var hasAppeared = false

    var body: some View {
        ZStack {
            DSColor.bgWarm
                .ignoresSafeArea()

            GrainOverlay()

            // Museum-aesthetic brand block: mono kicker → serif wordmark →
            // tagline, matching the sidebar / Today header type ladder
            // instead of the old grotesque-only lockup. Centered on the full
            // canvas (deterministic), with the CTA stack pinned to the bottom
            // edge — the two-Spacer sandwich this replaces distributed the
            // slack unevenly and left the lockup stranded above the buttons.
            VStack(spacing: 10) {
                Text("DAYPAGE · 2026")
                    .font(DSType.mono10)
                    .tracking(2.4)
                    .foregroundColor(DSColor.inkSubtle)
                    .accessibilityHidden(true)

                Text("DayPage")
                    .font(DSFonts.serif(size: 40, weight: .semibold))
                    .foregroundColor(DSColor.inkPrimary)

                Text(NSLocalizedString("auth.tagline", comment: "AuthView brand tagline under DayPage logo"))
                    .font(DSType.bodySM)
                    .foregroundColor(DSColor.inkSecondary)
                    .multilineTextAlignment(.center)
            }
            .entrance(hasAppeared, reduceMotion: reduceMotion, delay: 0.05)
            .padding(.horizontal, 24)
            // Optically centered: nudged up so the bottom CTA stack doesn't
            // make the lockup read low on tall screens.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .offset(y: -40)

            VStack(spacing: 0) {
                if let errorText = viewModel.errorMessage {
                    Text(errorText)
                        .font(DSType.bodySM)
                        .foregroundColor(DSColor.statusError)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 12)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.2), value: viewModel.errorMessage)
                }

                buttonStack
                    .entrance(hasAppeared, reduceMotion: reduceMotion, delay: 0.18)

                Button {
                    onSkip?()
                } label: {
                    Text(NSLocalizedString("auth.skip", comment: "AuthView Skip-login button"))
                        .font(.custom("Inter-Regular", size: 13))
                        .foregroundColor(DSColor.inkMuted)
                }
                .padding(.top, 16)
                .padding(.bottom, 32)
                .accessibilityLabel(NSLocalizedString("auth.skip.a11y", comment: "VoiceOver label for Skip login"))
                .entrance(hasAppeared, reduceMotion: reduceMotion, delay: 0.30)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

            if viewModel.isLoading {
                ProgressView()
                    .tint(DSColor.inkPrimary)
            }
        }
        .task {
            viewModel.bind(authService: authService)
        }
        .onAppear { hasAppeared = true }
        .transition(.opacity.animation(.easeOut(duration: 0.4)))
        .sheet(isPresented: $showEmailAuth) {
            EmailAuthView()
        }
    }

    // MARK: - Button Stack

    private var buttonStack: some View {
        VStack(spacing: 12) {
            Button {
                Task { await viewModel.signInWithApple() }
            } label: {
                authButtonLoadingLabel(
                    icon: "apple.logo",
                    label: "Continue with Apple",
                    iconColor: DSColor.onAmber,
                    labelColor: DSColor.onAmber,
                    background: DSColor.amberDeep,
                    border: DSColor.amberRim,
                    isLoading: viewModel.isLoading
                )
            }
            .buttonStyle(AuthButtonStyle())
            .disabled(viewModel.isLoading)
            .accessibilityLabel(viewModel.isLoading ? "Signing in with Apple" : "Continue with Apple")
            .accessibilityHint("Sign in using your Apple ID")

            Button {
                showEmailAuth = true
            } label: {
                authButtonLabel(
                    icon: "envelope",
                    label: "Continue with Email",
                    iconColor: DSColor.inkSecondary,
                    labelColor: DSColor.inkSecondary,
                    background: DSColor.surfaceWhite,
                    border: DSColor.inkFaint
                )
            }
            .buttonStyle(AuthButtonStyle())
            .disabled(viewModel.isLoading)
            .accessibilityLabel(NSLocalizedString("a11y.continue_email", comment: "Continue with email"))
            .accessibilityHint(NSLocalizedString("a11y.continue_email.hint", comment: "Email OTP sign-in hint"))
        }
    }

    // MARK: - Auth Button Labels

    /// Standard auth button with no loading indicator.
    private func authButtonLabel(
        icon: String,
        label: String,
        iconColor: Color,
        labelColor: Color,
        background: Color,
        border: Color
    ) -> some View {
        authButtonLoadingLabel(
            icon: icon, label: label,
            iconColor: iconColor, labelColor: labelColor,
            background: background, border: border,
            isLoading: false
        )
    }

    /// Auth button that shows an inline ProgressView when `isLoading` is true.
    private func authButtonLoadingLabel(
        icon: String,
        label: String,
        iconColor: Color,
        labelColor: Color,
        background: Color,
        border: Color,
        isLoading: Bool
    ) -> some View {
        ZStack {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundColor(iconColor)
                    .font(.system(size: 17))
                Text(label)
                    .font(.custom("SpaceGrotesk-Medium", size: 16))
                    .foregroundColor(labelColor)
            }
            .opacity(isLoading ? 0 : 1)

            if isLoading {
                // Loading spinner sits on the amber-filled CTA — use onAmber
                // (near-white in both schemes) so it stays legible on the fill.
                ProgressView()
                    .tint(DSColor.onAmber)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 54)
        .background(background)
        .cornerRadius(DSRadius.md)
        .overlay(
            RoundedRectangle(cornerRadius: DSRadius.md)
                .stroke(border, lineWidth: 1)
        )
    }
}
